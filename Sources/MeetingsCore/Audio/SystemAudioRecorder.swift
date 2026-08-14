import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Records everything the machine plays to `system.wav` via a ScreenCaptureKit audio-only stream
///. "Audio-only" is a slight fiction: SCK has no filter that means "no video", so we
/// describe a display and simply never add a `.screen` output.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yoelgal.Meetings.system-audio")
    private var stream: SCStream?
    private var writer: ChannelWriter?
    /// Everything below is written only on `queue`.
    private var bufferCount = 0
    private var lastFormat: AVAudioFormat?
    private var stopError: Error?

    /// A silent check — unlike `SCShareableContent`, which *prompts* when the state is
    /// notDetermined and is therefore a request dressed up as a query.
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Live transcription's tap on the resampled 16 kHz stream, forwarded to the writer when the
    /// stream starts. Set before `start`; the writer only exists from then on.
    var onSamples16k: (([Float], Int) -> Void)?

    var level: Float { writer?.level ?? 0 }
    var framesWritten: Int64 { queue.sync { writer?.framesWritten ?? 0 } }
    /// Why this track stopped growing, when it has. See ``ChannelWriter/writeFailure``.
    var writeFailure: ChannelWriter.WriteFailure? { queue.sync { writer?.writeFailure } }
    var buffersReceived: Int { queue.sync { bufferCount } }
    /// The ASBD actually delivered, which is not necessarily the one we asked for.
    var deliveredFormat: AVAudioFormat? { queue.sync { lastFormat } }
    /// Set when the stream died on its own — the system stopped it, or the user did.
    var failure: Error? { queue.sync { stopError } }

    func start(writingTo url: URL, origin: Date) async throws {
        guard Self.isAuthorized else {
            throw RecordingError.systemAudioUnavailable(
                "Meetings needs Screen & System Audio Recording under Privacy & Security in "
                    + "System Settings")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
        } catch {
            throw RecordingError.systemAudioUnavailable("\(error)")
        }
        guard let display = content.displays.first else {
            throw RecordingError.systemAudioUnavailable("no display to attach the audio stream to")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000  // ask for the native rate and resample ourselves
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true  // our own chimes must not land in the transcript
        config.captureMicrophone = false  // the mic is AVAudioEngine's job, on its own track
        // Video is unavoidable, only unconsumed: SCK composites for the filter whether or not we
        // read it, and the 1920×1080 @ 60 fps default is real GPU for a two-hour meeting. 2×2 at
        // 1 fps is the floor — zero is an invalid parameter, not a smaller number.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false

        let writer: ChannelWriter
        do {
            writer = try ChannelWriter(url: url, origin: origin)
        } catch {
            throw RecordingError.systemAudioUnavailable(
                "cannot write \(url.lastPathComponent): \(error)")
        }
        writer.onSamples16k = onSamples16k
        queue.sync {
            self.writer = writer
            self.bufferCount = 0
            self.stopError = nil
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            queue.sync { self.writer = nil }
            try? FileManager.default.removeItem(at: url)
            throw RecordingError.systemAudioUnavailable("\(error)")
        }
        self.stream = stream
    }

    /// Idempotent. Flushes on the sample queue *after* `stopCapture` returns, so no callback can
    /// still be writing into a file we are closing.
    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        queue.sync {
            writer?.finish()
            writer = nil
        }
    }

    // MARK: - SCStreamOutput

    // `of type:` — not `ofType:`. The protocol's only method is optional, so the wrong selector
    // compiles cleanly and gives you a stream that starts, reports no error, and delivers nothing.
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0,
            let pcm = Self.pcmBuffer(from: sampleBuffer)
        else { return }
        bufferCount += 1
        lastFormat = pcm.format
        writer?.append(pcm)
    }

    // MARK: - SCStreamDelegate

    /// -3821 systemStoppedStream and -3817 userStopped arrive here. Close the track cleanly and let
    /// the meeting carry on with the mic — a system-side stop must not end the recording.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.stopError = error
            self.writer?.finish()
            self.writer = nil
        }
    }

    // MARK: -

    /// The copying form. The zero-copy `withAudioBufferList` variant hands back memory that SCK
    /// reuses the moment this callback returns, and the writer is not guaranteed to be done with it.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            let format = AVAudioFormat(streamDescription: asbd)
        else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return buffer
    }
}
