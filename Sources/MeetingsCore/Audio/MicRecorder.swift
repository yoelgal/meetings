// The AVAudioEngine graph below is derived from quill (https://github.com/digimata/quill), MIT
// licence, Copyright (c) 2026 Andrew Jones — specifically `attach(voiceProcessing:)`, the ducking
// configuration, and the first-second silence liveness check with its raw restart. Adapted to write
// 16 kHz mono WAV through ChannelWriter instead of AAC. Full attribution in NOTICE.

import AVFoundation
import Foundation
import os

/// Records the default input device to `mic.wav`. Buffers go straight through the resampler to
/// disk, so a four-hour meeting costs no more memory than a four-minute one.
///
/// Voice processing is on by default: Apple's echo canceller subtracts speaker playback from the
/// mic, which is what keeps the other participants out of the mic track and preserves the channel
/// separation the whole attribution scheme rests on.
///
/// **A device change rebuilds the graph into the same file.** `AVAudioEngine` stops itself whenever
/// the input or output route changes — AirPods connecting, a call app moving a headset into its
/// hands-free profile, the same headset moving back when the call ends — and posts
/// `AVAudioEngineConfigurationChange`. Nothing restarts it. That is how a real meeting lost its last
/// four minutes of mic: the call ended, the route moved, and the tap never fired again. So the
/// engine is rebuilt against the new route, and the writer pads the gap so the file keeps the
/// recording's clock.
///
/// Lifecycle is main-thread only — `start` and `stop` come from the main-actor controller, and the
/// two recovery paths hop to main before touching the graph.
final class MicRecorder: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.yoelgal.Meetings", category: "mic")
    private var engine = AVAudioEngine()
    private var writer: ChannelWriter?
    private var url: URL?
    private var origin = Date()
    private(set) var isRecording = false
    private var configurationObserver: NSObjectProtocol?
    /// Rebuilds since start. Only the first graph may throw its file away in the raw fallback;
    /// after a rebuild the file already holds the meeting.
    private(set) var rebuilds = 0
    /// Bumped by every `start`, so a retry scheduled during one recording cannot attach an engine
    /// in the next.
    private var session = 0
    /// Bumped by every `attach`. The liveness check's fallback names the graph that tripped it, so a
    /// trip queued just before a route-change rebuild cannot tear down the rebuild's new graph.
    private var graph = 0

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
        rebuilds = 0
        session += 1
        fellBackToRaw = false
        try makeWriter()
        try attach(voiceProcessing: true)
        isRecording = true
    }

    /// Idempotent. Finalises the WAV header by releasing the file.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        detachEngine()
        writer?.finish()
    }

    private func makeWriter() throws {
        guard let url else { throw RecordingError.microphoneUnavailable("no output path") }
        do {
            writer = try ChannelWriter(url: url, origin: origin)
            writer?.onSamples16k = onSamples16k
        } catch {
            throw RecordingError.microphoneUnavailable("cannot write \(url.lastPathComponent): \(error)")
        }
    }

    private func detachEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// The route moved and the engine stopped itself. Rebuild against whatever the route is now,
    /// with voice processing if it was on — the new device may well support it — and into the same
    /// file. A device that is not ready yet is retried for as long as the meeting runs: a second
    /// apart at first, then every five. Giving up would leave nothing that could ever bring the
    /// mic back, because the observer that triggers a rebuild belongs to an engine that started.
    /// Meanwhile the controller's stall check is what tells the user.
    private func rebuild(attempt: Int = 0, session expected: Int? = nil) {
        guard isRecording, session == (expected ?? session) else { return }
        if attempt == 0 {
            Self.log.notice("mic route changed; rebuilding the capture graph")
            detachEngine()
            writer?.markDiscontinuity()
            rebuilds += 1
            // A fresh route gets a fresh chance at echo cancellation. One bad moment on the last
            // route must not cost voice processing — and with it channel separation — for the rest
            // of the meeting.
            fellBackToRaw = false
        }
        do {
            try attach(voiceProcessing: !fellBackToRaw)
        } catch {
            Self.log.error("mic rebuild failed: \(String(describing: error), privacy: .public)")
            let current = session
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt < 4 ? 1 : 5)) { [weak self] in
                self?.rebuild(attempt: attempt + 1, session: current)
            }
        }
    }

    // MARK: -

    /// Build the graph and start capture into the current writer. Called once at start, again with
    /// `voiceProcessing: false` if the liveness check trips, and again on every route change.
    private func attach(voiceProcessing: Bool) throws {
        graph += 1
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
            throw RecordingError.microphoneUnavailable("engine start failed: \(error)")
        }
        // Per engine: a stale observer on a discarded engine must not rebuild the live one.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.rebuild()
        }
    }

    private func installVoiceTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let tripped = graph
        let checkFrames = Int(format.sampleRate)  // one second
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
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
                        DispatchQueue.main.async { self.fallBackToRaw(graph: tripped) }
                        return
                    }
                }
            }
            self.writer?.append(buffer, capturedAt: Self.captureDate(of: when))
        }
    }

    /// When the buffer's first frame was captured, from its host-time stamp. See
    /// ``ChannelWriter/append(_:capturedAt:)``.
    private static func captureDate(of when: AVAudioTime) -> Date {
        guard when.isHostTimeValid else { return Date() }
        let age = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            - AVAudioTime.seconds(forHostTime: when.hostTime)
        guard age.isFinite, age >= 0, age < 5 else { return Date() }
        return Date().addingTimeInterval(-age)
    }

    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            self?.writer?.append(buffer, capturedAt: Self.captureDate(of: when))
        }
    }

    /// A full second of digital silence: tear the engine down, throw the silent prefix away, and
    /// restart raw. If the restart also fails the session continues without a mic track — a meeting
    /// that lost one channel still beats a meeting that stopped mid-sentence.
    ///
    /// After a rebuild the file already holds the meeting so far, so it is kept and the gap padded.
    private func fallBackToRaw(graph tripped: Int) {
        guard isRecording, tripped == graph else { return }
        detachEngine()
        if rebuilds == 0 {
            writer = nil
            if let url { try? FileManager.default.removeItem(at: url) }
            try? makeWriter()
        } else {
            writer?.markDiscontinuity()
        }
        fellBackToRaw = true
        do {
            try attach(voiceProcessing: false)
        } catch {
            // The device the rebuild just found may still be settling. Leaving it here would leave
            // no engine and no observer to ever trigger another try, so join the rebuild's retry.
            let current = session
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.rebuild(attempt: 1, session: current)
            }
        }
    }
}
