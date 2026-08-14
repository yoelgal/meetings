@preconcurrency import AVFoundation  // AVAudioPCMBuffer is not Sendable and the converter's input
                                     // block is; without this the block below will not compile.
import Foundation

/// Bringing an existing recording into the store: whatever AVFoundation can read in — an m4a voice
/// memo, an mp3, a 48 kHz stereo wav — 16 kHz mono WAV out, in the layout the batch pass expects.
///
/// The batch pass reads exactly `mic.wav` and `system.wav` from `Paths.audioDirectory(meetingID:)`
/// (see `TranscriptionService.channelFiles`), so an imported file has to *become* one of those two
/// names. It cannot be referenced where it lies.
///
/// **A single imported file lands on `mic`.** The two channels are the app's whole speaker
/// attribution: `mic` is what this machine's microphone heard, `system` is what came out
/// of its speakers. A voice memo of a meeting, a phone recording of a room, a legacy dump — none of
/// them are the far end of a call, they are a microphone that heard everybody. `mic` is also the
/// channel that always exists for a recorded meeting, so every consumer already handles a meeting
/// with only `mic.wav`; a system-only meeting is the unusual shape and the one more likely to trip
/// something up. The caller can override, and `meetings create` exposes that.
public enum AudioIngest {
    /// Convert `source` into `<audio dir>/<channel>.wav` and return the file written.
    @discardableResult
    public static func install(
        _ source: URL,
        forMeeting meetingID: String,
        channel: Channel = .mic,
        audioRoot: URL? = nil
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AudioIngestError.unreadable(source, "no such file")
        }
        let directory = audioRoot.map { $0.appendingPathComponent(meetingID, isDirectory: true) }
            ?? Paths.audioDirectory(meetingID: meetingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(channel.rawValue).wav")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try convert(source, to: destination)
        return destination
    }

    /// 16 kHz mono 16-bit WAV — Parakeet's expected input, so the batch pass's own resample is a
    /// no-op.
    ///
    /// Streamed in chunks rather than read whole: a two-hour meeting at 48 kHz stereo is about
    /// 1.4 GB of Float32 in memory if you read it in one buffer, and a migration run does this
    /// two hundred times in a row.
    static func convert(_ source: URL, to destination: URL) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw AudioIngestError.unreadable(source, error.localizedDescription)
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: input.processingFormat, to: target) else {
            throw AudioIngestError.unconvertible(source, "\(input.processingFormat)")
        }
        // Multi-channel sources (a screen recording can carry six) average down instead of having
        // the converter pick channel one and throw the rest of the room away.
        converter.downmix = true

        let output = try AVAudioFile(forWriting: destination, settings: wavSettings)
        let inputFrames: AVAudioFrameCount = 16_384
        let ratio = target.sampleRate / input.processingFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(inputFrames) * ratio) + 1_024
        var wroteAnything = false

        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputFrames) else {
                throw AudioIngestError.unconvertible(source, "cannot allocate an output buffer")
            }
            var failure: NSError?
            let status = converter.convert(to: out, error: &failure) { _, statusOut in
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: input.processingFormat, frameCapacity: inputFrames)
                else {
                    statusOut.pointee = .endOfStream
                    return nil
                }
                do { try input.read(into: buffer) } catch {
                    statusOut.pointee = .endOfStream
                    return nil
                }
                if buffer.frameLength == 0 {
                    statusOut.pointee = .endOfStream
                    return nil
                }
                statusOut.pointee = .haveData
                return buffer
            }
            if out.frameLength > 0 {
                try output.write(from: out)
                wroteAnything = true
            }
            switch status {
            case .haveData, .inputRanDry:
                continue
            case .endOfStream:
                // The last call flushes the resampler's tail; anything it produced is written above.
                if !wroteAnything { throw AudioIngestError.empty(source) }
                return
            case .error:
                throw AudioIngestError.unconvertible(source, failure?.localizedDescription ?? "conversion failed")
            @unknown default:
                throw AudioIngestError.unconvertible(source, "unexpected converter status")
            }
        }
    }

    /// The same settings `ChannelWriter` records with, so an imported file and a recorded one are
    /// indistinguishable to everything downstream.
    private static var wavSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}

public enum AudioIngestError: Error, LocalizedError {
    case unreadable(URL, String)
    case unconvertible(URL, String)
    case empty(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let why): "Cannot read \(url.lastPathComponent) as audio: \(why)"
        case .unconvertible(let url, let why): "Cannot convert \(url.lastPathComponent) to 16 kHz mono: \(why)"
        case .empty(let url): "\(url.lastPathComponent) contains no audio"
        }
    }
}
