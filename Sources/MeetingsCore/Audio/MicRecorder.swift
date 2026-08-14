// The AVAudioEngine graph below is derived from quill (https://github.com/digimata/quill), MIT
// licence, Copyright (c) 2026 Andrew Jones — specifically `attach(voiceProcessing:)`, the ducking
// configuration, and the first-second silence liveness check with its raw restart. Adapted to write
// 16 kHz mono WAV through ChannelWriter instead of AAC. Full attribution in NOTICE.

import AVFoundation
import Foundation

/// Records the default input device to `mic.wav`. Buffers go straight through the resampler to
/// disk, so a four-hour meeting costs no more memory than a four-minute one.
///
/// Voice processing is on by default: Apple's echo canceller subtracts speaker playback from the
/// mic, which is what keeps the other participants out of the mic track and preserves the channel
/// separation the whole attribution scheme rests on.
final class MicRecorder: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var writer: ChannelWriter?
    private var url: URL?
    private var origin = Date()
    private(set) var isRecording = false

    /// VoiceProcessingIO is a duplex unit, not an input effect. On some routes — mismatched default
    /// input and output devices hit a live macOS `AUVPAggregate` defect — it delivers callbacks full
    /// of digital zeros and reports no error at all. The only tell is that the first second is
    /// bit-exact silence, and the only recovery is restarting raw.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// Live transcription's tap on the resampled 16 kHz stream. Forwarded to the writer as it is
    /// created, so it survives the raw-capture fallback rebuilding the graph underneath it.
    var onSamples16k: (([Float], Int) -> Void)? {
        didSet { writer?.onSamples16k = onSamples16k }
    }

    var level: Float { writer?.level ?? 0 }
    var framesWritten: Int64 { writer?.framesWritten ?? 0 }
    /// Why this track stopped growing, when it has. See ``ChannelWriter/writeFailure``.
    var writeFailure: ChannelWriter.WriteFailure? { writer?.writeFailure }
    var firstBufferAt: Date? { writer?.firstBufferAt }
    /// Set when the graph fell back to raw capture, so a run can report that echo cancellation was
    /// not in play and the mic track may carry bleed from the speakers.
    private(set) var fellBackToRaw = false

    func start(writingTo url: URL, origin: Date) throws {
        guard !isRecording else { return }
        self.url = url
        self.origin = origin
        try attach(voiceProcessing: true)
        isRecording = true
    }

    /// Idempotent. Finalises the WAV header by releasing the file.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        writer?.finish()
    }

    // MARK: -

    /// Build the graph, create the writer, start capture. Called once at start and a second time
    /// with `voiceProcessing: false` if the liveness check trips.
    private func attach(voiceProcessing: Bool) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a call and duck every other
                // sound — the meeting itself would get quieter the moment you hit record.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                voice = false  // route does not support it; carry on raw
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // One explicit mono client format at the device's own rate. With voice processing this is
        // the Voice I/O boundary format on *both* sides of the duplex unit — inheriting the route's
        // multichannel format is what yields digital silence on a nine-channel device.
        guard
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                channels: 1, interleaved: false)
        else { throw RecordingError.microphoneUnavailable("cannot downmix \(inputFormat)") }

        guard let url else { throw RecordingError.microphoneUnavailable("no output path") }
        do {
            writer = try ChannelWriter(url: url, origin: origin)
            writer?.onSamples16k = onSamples16k
        } catch {
            throw RecordingError.microphoneUnavailable("cannot write \(url.lastPathComponent): \(error)")
        }

        if voice {
            // Complete the duplex graph. The mixer has no sources and nothing is monitored or
            // played; the connection exists only to give the unit a formatted, rendered output path,
            // without which the input side never produces audio.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            installVoiceTap(on: input, format: monoFormat)
        } else {
            fellBackToRaw = true
            // Tap at the native format; ChannelWriter downmixes and resamples in one converter.
            installTap(on: input, format: inputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            writer = nil
            throw RecordingError.microphoneUnavailable("engine start failed: \(error)")
        }
    }

    private func installVoiceTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let checkFrames = Int(format.sampleRate)  // one second
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames { self.livenessPeak = max(self.livenessPeak, abs(data[i])) }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { self.fallBackToRaw() }
                        return
                    }
                }
            }
            self.writer?.append(buffer)
        }
    }

    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.writer?.append(buffer)
        }
    }

    /// A full second of digital silence: tear the engine down, throw the silent prefix away, and
    /// restart raw. If the restart also fails the session continues without a mic track — a meeting
    /// that lost one channel still beats a meeting that stopped mid-sentence.
    private func fallBackToRaw() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        writer = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        try? attach(voiceProcessing: false)
    }
}
