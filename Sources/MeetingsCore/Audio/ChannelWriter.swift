@preconcurrency import AVFoundation  // AVAudioPCMBuffer is not Sendable and the converter's input
                                     // block is; without this the block below will not compile.
import Foundation
import os

/// Resample-and-write for one capture track: whatever the device hands us in, 16 kHz mono WAV out.
///
/// One instance per track, alive for the track's whole life, because the `AVAudioConverter` inside
/// carries filter state. Building a converter per buffer loses the filter tail and inflates energy —
/// meetily measured 173.5% RMS doing exactly that.
///
/// Not thread-safe. Each recorder owns one and touches it only from its own capture callback, which
/// is a single serial thread in both cases (the engine's render thread, and the stream's sample
/// queue). `@unchecked Sendable` is that ownership rule, not an absence of one.
final class ChannelWriter: @unchecked Sendable {
    /// What Parakeet wants, so the batch pass's own resample step becomes a no-op.
    static let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// A live transcriber would hang off this: 16 kHz mono samples plus their offset in ms from the
    /// recording origin, which is exactly a `StreamingTranscriber.feed` call. Wave 1 leaves it nil —
    /// the point is that wiring one up later needs no change to either recorder.
    var onSamples16k: (([Float], Int) -> Void)?

    let url: URL

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// Wall-clock instant the whole recording began. The two capture paths do not deliver their
    /// first buffer at the same moment — ScreenCaptureKit's start latency is both larger and more
    /// variable than a Core Audio tap's — so the first buffer is padded with silence back to this
    /// instant. Both WAVs then start at t=0 of the meeting and a transcript offset means the same
    /// thing whichever file it came from, with no per-track offset to carry in the schema.
    private let origin: Date
    private var padded = false

    /// Written from the capture thread, read from the main actor for the meter, hence the lock.
    private let meter = OSAllocatedUnfairLock(initialState: Float(0))

    private(set) var framesWritten: Int64 = 0
    /// How much of `framesWritten` is the leading silence written to reach the origin.
    private(set) var paddedFrames: Int64 = 0
    private(set) var firstBufferAt: Date?

    /// Why the track stopped growing, the first time a write failed, and how much audio has been
    /// dropped since. Locked for the same reason the meter is: written on the capture thread, read
    /// from the main actor by the controller's meter tick — which is what turns a silently
    /// truncating recording into one the user is told about.
    ///
    /// The recording is **not** stopped when this is set: a full disk is recoverable while the
    /// meeting is still going, and every later buffer is another attempt to write.
    private let failure = OSAllocatedUnfairLock<WriteFailure?>(initialState: nil)

    struct WriteFailure: Sendable {
        let reason: String
        var framesDropped: Int64
    }

    var writeFailure: WriteFailure? { failure.withLock { $0 } }

    init(url: URL, origin: Date) throws {
        self.url = url
        self.origin = origin
        // The extension picks the container: `.wav` gives RIFF/WAVE, anything else gives CAF.
        self.file = try AVAudioFile(forWriting: url, settings: Self.wavSettings)
    }

    /// 16-bit LE PCM. `AVAudioFile` quantises the Float32 buffers we hand it on the way in.
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

    /// 0…1 peak with decay — a bare per-buffer peak flickers too fast to read as a meter.
    var level: Float { meter.withLock { $0 } }

    /// Resample `input` and append it. Silently drops a buffer it cannot convert rather than
    /// throwing: a single bad buffer mid-meeting is not a reason to lose the rest of the meeting.
    func append(_ input: AVAudioPCMBuffer) {
        guard let file, input.frameLength > 0 else { return }
        let now = Date()
        if firstBufferAt == nil { firstBufferAt = now }
        if !padded {
            padded = true
            padSilence(upTo: now, in: file)
        }

        // AVAudioConverter misbehaves above two channels (Safari on speaker mode and some hardware
        // routes report nine), so those get averaged down before it ever sees them.
        let source = input.format.channelCount > 2 ? Self.mixToMono(input) : input
        guard let source else { return }
        // The device changed underneath us — AirPods moving A2DP↔HFP is the everyday case. The old
        // converter is about to be thrown away, so flush its filter tail into the file first;
        // otherwise every switch costs the ~50 ms it was still holding.
        if let cached = sourceFormat, !source.format.isEqual(cached) { flushTail(into: file) }
        guard let out = convert(source) else { return }

        // Before the write and before the hook, because both are downstream of it: a NaN quantised
        // into the WAV is a click, and a NaN fed to the recogniser poisons its state for the rest
        // of the meeting. Costs nothing — the meter has to walk the same samples anyway.
        sanitiseAndMeter(out)

        let offsetMs = Int(Double(framesWritten) / 16.0)
        do {
            try file.write(from: out)
            framesWritten += Int64(out.frameLength)
        } catch {
            noteWriteFailure(error, frames: Int64(out.frameLength))
            return
        }
        if let onSamples16k, let data = out.floatChannelData?[0] {
            onSamples16k(Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength))), offsetMs)
        }
    }

    /// Flush the resampler's filter tail and finalise the file. `AVAudioFile` has no `close()` — the
    /// header is written in `deinit`, so releasing the last reference *is* the close. Idempotent.
    func finish() {
        if let file { flushTail(into: file) }
        file = nil
        meter.withLock { $0 = 0 }
    }

    /// Empty the resampler's filter into the file. Called at stop, and again whenever the device
    /// hands over a different format mid-recording — the converter is per-format, and the one being
    /// replaced is still holding real audio.
    ///
    /// Drains in a loop: one call empties one output buffer's worth, and the mastering resampler's
    /// filter can be holding more than that. Bounded so a converter that never says it is done
    /// cannot hang the stop.
    private func flushTail(into file: AVAudioFile) {
        for _ in 0..<32 {
            guard let tail = drain() else { break }
            sanitiseAndMeter(tail)
            let offsetMs = Int(Double(framesWritten) / 16.0)
            do {
                try file.write(from: tail)
                framesWritten += Int64(tail.frameLength)
            } catch {
                noteWriteFailure(error, frames: Int64(tail.frameLength))
                return
            }
            if let onSamples16k, let data = tail.floatChannelData?[0] {
                onSamples16k(
                    Array(UnsafeBufferPointer(start: data, count: Int(tail.frameLength))), offsetMs)
            }
        }
        // The drained converter has ended its stream and cannot be fed again, so the next buffer
        // builds a fresh one even if the format came back to what it was.
        converter = nil
        sourceFormat = nil
    }

    // MARK: -

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let fmt = input.format
        // Never cache the format the stream was configured with. A Bluetooth headset switching
        // A2DP↔HFP moves the device's nominal rate mid-meeting; a converter built for the old rate
        // pitch-shifts everything after the switch.
        if sourceFormat == nil || !fmt.isEqual(sourceFormat!) {
            guard let c = AVAudioConverter(from: fmt, to: Self.target) else { return nil }
            c.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = c
            sourceFormat = fmt
        }
        guard let converter else { return nil }

        let ratio = Self.target.sampleRate / fmt.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else {
            return nil
        }

        // The input block is @Sendable, so the "already handed it over" flag cannot be a captured
        // var. It answers .noDataNow, never .endOfStream: the latter ends the conversion and throws
        // the converter's state away, which is right once at drain and wrong on every buffer.
        let supplied = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            let already = supplied.withLock { s -> Bool in
                defer { s = true }
                return s
            }
            if already {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    private func drain() -> AVAudioPCMBuffer? {
        guard let converter,
            let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: 4096)
        else { return nil }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, s in
            s.pointee = .endOfStream
            return nil
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// Ten seconds is the ceiling: past that the gap is a bug, not latency, and writing minutes of
    /// silence would make it look like the meeting simply started quiet.
    private func padSilence(upTo now: Date, in file: AVAudioFile) {
        let seconds = min(max(now.timeIntervalSince(origin), 0), 10)
        let frames = AVAudioFrameCount(seconds * Self.target.sampleRate)
        guard frames > 0, let silence = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: frames)
        else { return }
        silence.frameLength = frames
        silence.floatChannelData?[0].update(repeating: 0, count: Int(frames))
        try? file.write(from: silence)
        framesWritten += Int64(frames)
        paddedFrames = Int64(frames)
    }

    /// One walk of the converted samples that does two jobs: replace anything not finite with
    /// silence, and take the peak for the meter.
    ///
    /// A working device never sends a NaN. A virtual one can — aggregate devices, loopback drivers
    /// and audio plug-ins all sit in the path a real user's route goes through, and one of them
    /// handing over garbage must cost that buffer, not the meeting: quantised into the WAV a NaN is
    /// a click, and fed to the recogniser it poisons the model's state for everything after it.
    private func sanitiseAndMeter(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        var scan: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            let sample = data[i]
            // `max` with a NaN answers with the other operand, so a NaN would slip past a peak
            // test unnoticed. Ask the sample itself.
            if !sample.isFinite {
                data[i] = 0
                continue
            }
            scan = max(scan, abs(sample))
        }
        let peak = scan
        meter.withLock { $0 = max(peak, $0 * 0.85) }
    }

    /// The first write failure is the one worth reporting; the rest are the same disk, still full.
    private func noteWriteFailure(_ error: Error, frames: Int64) {
        failure.withLock { state in
            if state == nil {
                state = WriteFailure(reason: reasonForWriteFailure(error), framesDropped: frames)
            } else {
                state?.framesDropped += frames
            }
        }
    }

    /// A full disk is the case that actually happens, and `AVAudioFile` reports it as an opaque
    /// CoreAudio status, so the volume is asked directly rather than the error decoded.
    private func reasonForWriteFailure(_ error: Error) -> String {
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity
        if let free, free < 16 << 20 {
            return "the disk filled up, so nothing more could be written to this channel. "
                + "Everything recorded up to that point is safe. Free some space and the rest of "
                + "this meeting will be recorded. Nothing needs restarting."
        }
        return "it could not be written (\(error.localizedDescription))"
    }

    /// Average the channels. `1/n` weighting rather than a sum, so a nine-channel route does not
    /// arrive nine times too loud.
    private static func mixToMono(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let channels = input.floatChannelData,
            let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: input.format.sampleRate,
                channels: 1, interleaved: false),
            let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: input.frameLength),
            let dst = out.floatChannelData?[0]
        else { return nil }
        let frames = Int(input.frameLength)
        let count = Int(input.format.channelCount)
        let weight = 1.0 / Float(count)
        dst.update(repeating: 0, count: frames)
        for c in 0..<count {
            let src = channels[c]
            for i in 0..<frames { dst[i] += src[i] * weight }
        }
        out.frameLength = input.frameLength
        return out
    }
}
