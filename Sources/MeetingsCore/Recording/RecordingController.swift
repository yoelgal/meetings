import Foundation

/// The recording surface the app and the menu bar item both drive. One instance per process — two
/// concurrent recordings are not a thing, and the type enforces that by holding a single session.
@MainActor @Observable
public final class RecordingController {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting
        case recording(startedAt: Date)
        case stopping
        /// The batch re-pass after stop. 0…1.
        case transcribing(progress: Double)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var meetingID: String?
    /// Live segments in arrival order, mirrored into the store as `pass = .live`.
    public private(set) var liveSegments: [TranscriptSegment] = []
    /// 0…1 input level per channel, for the meters. Absent until the first buffer arrives.
    public private(set) var levels: [Channel: Float] = [:]

    /// Why the system channel is missing, when it is. A meeting recorded with only the mic is a
    /// legitimate outcome — see `start(meetingID:)` — but the UI has to be able to say so, because
    /// a transcript with nobody else in it looks like a bug otherwise.
    public private(set) var systemAudioUnavailable: String?

    /// Why a track stopped growing while the meeting was still running — a full disk, in practice.
    ///
    /// The recording continues: the buffers keep coming, every one of them is another attempt to
    /// write, and freeing space resumes the track mid-meeting. What must not happen is the silent
    /// version, where the meter keeps bouncing and the clock keeps climbing over a WAV that stopped
    /// growing ten minutes ago. Set from the meter tick, and recorded as a capture issue on the
    /// meeting in the same breath so the sidebar, `meetings show` and the CLI all say it too.
    public private(set) var captureWriteFailure: String?

    /// Why the live transcript is empty, when it is — most often that the streaming model has not
    /// been downloaded yet. Recording is the thing that cannot be redone; a transcript can, because
    /// the batch pass on stop reads the same WAVs. So a live transcriber that will not start is a
    /// sentence the UI shows, never a recording that refuses to begin.
    public private(set) var liveTranscriptionUnavailable: String?

    /// Milliseconds since capture began, 0 when not recording. This is the offset a live note
    /// anchors at, so it has to keep running even while the transcriber is behind.
    public var elapsedMs: Int {
        guard case .recording(let startedAt) = phase else { return 0 }
        return max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    let store: MeetingStore
    let transcription: TranscriptionService

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var meterTask: Task<Void, Never>?
    /// Channels already reported as broken, so the tick does not say it ten times a second for the
    /// rest of the meeting.
    private var reportedCaptureFailures: Set<Channel> = []
    /// The last mic frame count the tick saw, and when it last changed. The mic stalling is how a
    /// device being unplugged looks from here.
    private var micProgress: (frames: Int64, at: Date)?
    private var live: [Channel: LiveChannel] = [:]
    /// Where this session's WAVs are going, so `stop()` can read back what actually landed in them.
    private var audioDirectory: URL?

    /// Test seam. A real one loads Core ML and needs an ANE; the controller's own rules — what
    /// reaches the store, what happens when the model is missing — are worth testing without either.
    ///
    /// The variant is ``LocalTranscriber/current`` and not the default, which is the whole of what
    /// makes one download serve both halves of the app: this is the instance that writes the live
    /// pane, ``TranscriptionService/prepareModels(progress:)`` is what fetched it, and
    /// ``StreamingFileEngine`` is what drives the same checkpoint over a file. Left at the parameter
    /// default this constructed the 320 ms EOU model whatever had been downloaded — so on a Mac
    /// resolving to the English model, onboarding fetched one checkpoint, `modelsReady()` said yes
    /// about it, and recording then asked for a different one and got
    /// `modelsNotDownloaded`: a meeting with no live transcript and nothing saying why.
    var makeLiveTranscriber: @Sendable () -> StreamingTranscriber = {
        FluidAudioStreamingTranscriber(variant: LocalTranscriber.current.variant)
    }

    public init(store: MeetingStore, transcription: TranscriptionService) {
        self.store = store
        self.transcription = transcription
    }

    /// Starts both tracks and moves the meeting to `recording`.
    ///
    /// The two channels are not equally load-bearing, so they do not fail the same way. **A mic
    /// failure aborts the whole start** — it is your own voice, there is no fallback for it, and a
    /// meeting silently missing the half you are in is worse than one that refused to begin. **A
    /// system-audio failure degrades instead**: an in-person meeting genuinely has nothing on that
    /// channel, and the common causes (screen-recording not granted yet, no display attached) leave
    /// a mic track that is still worth having. The reason lands in `systemAudioUnavailable` so the
    /// UI shows it rather than the user discovering it in the transcript a week later.
    public func start(meetingID: String) async throws {
        switch phase {
        case .idle, .failed: break
        case .starting, .recording, .stopping, .transcribing: throw RecordingError.alreadyRecording
        }
        phase = .starting
        liveSegments = []
        levels = [:]
        systemAudioUnavailable = nil
        liveTranscriptionUnavailable = nil
        captureWriteFailure = nil
        reportedCaptureFailures = []
        micProgress = nil
        self.meetingID = meetingID

        let directory = Paths.audioDirectory(meetingID: meetingID)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            phase = .failed("cannot create the audio directory: \(error)")
            throw error
        }
        audioDirectory = directory

        // One origin for both tracks. Each writer pads its own head with silence back to it, so the
        // two WAVs share a clock despite ScreenCaptureKit taking noticeably longer to deliver its
        // first buffer than the Core Audio tap does.
        let origin = Date()

        // Mic first, and deliberately so. `SCShareableContent` plus `startCapture` measured ~3.7 s on
        // this machine, and starting the mic behind that threw away the first four seconds of the
        // user's own voice — the one thing they pressed record for. Mic is the gating channel here
        // anyway (a mic failure aborts, a system failure degrades), so nothing needs unwinding in
        // the order that matters: if the mic fails, the stream was never started.
        // Live transcription is attached *before* capture, not after: each writer picks the tap up
        // as it is created, so no closure is swapped in underneath a running audio thread and the
        // first buffer of the meeting is transcribed like every other one.
        attachLive(.mic, meetingID: meetingID) { [mic] hook in mic.onSamples16k = hook }
        attachLive(.system, meetingID: meetingID) { [system] hook in system.onSamples16k = hook }

        do {
            try mic.start(writingTo: directory.appendingPathComponent("mic.wav"), origin: origin)
        } catch {
            await stopLiveTranscription()
            self.meetingID = nil
            phase = .failed(String(describing: error))
            throw error
        }
        do {
            try await system.start(writingTo: directory.appendingPathComponent("system.wav"), origin: origin)
        } catch {
            systemAudioUnavailable = String(describing: error)
            // Nothing will ever arrive on that channel, and a second recogniser waiting for audio
            // that is not coming is an ANE slot the mic channel wants.
            await detachLive(.system)
        }

        do {
            try store.updateMeeting(id: meetingID) { meeting in
                meeting.state = .recording
                meeting.startedAt = origin
                meeting.audioPath = directory.path
            }
        } catch {
            mic.stop()
            await system.stop()
            await stopLiveTranscription()
            self.meetingID = nil
            phase = .failed(String(describing: error))
            throw error
        }

        phase = .recording(startedAt: origin)
        startMetering()
        installTerminationGuard()
    }

    // MARK: - Dying politely

    /// Installed for the length of a recording, and only then.
    private var terminationGuard: [any DispatchSourceProtocol] = []

    /// Finalise the WAVs when the process is asked to go away.
    ///
    /// `killall Meetings`, a logout, a `kill` from a script and Ctrl-C on a debug run all arrive as
    /// SIGTERM or SIGINT, and the default action for both is to stop the process where it stands.
    /// Nothing is lost that way — an unfinalised WAV is exactly what ``WAVRepair`` exists for, and
    /// the stranded row is what ``RecordingRecovery`` exists for — but the recovery costs a relaunch
    /// plus a fifteen-second grace window, and the resampler's filter tail is thrown away.
    /// Answering the signal instead makes a logout cost nothing at all: the header is written, the
    /// tail is flushed, and the meeting is already queued for the batch pass when the app comes
    /// back. SIGKILL still cannot be caught, and is still covered by the repair-and-sweep path.
    private func installTerminationGuard() {
        guard terminationGuard.isEmpty else { return }
        terminationGuard = Self.trap([SIGTERM, SIGINT]) { [weak self] in
            Task { @MainActor in
                await self?.finaliseForTermination()
                exit(0)
            }
        }
    }

    private func removeTerminationGuard() {
        for source in terminationGuard { source.cancel() }
        terminationGuard = []
        // Back to "a signal stops the process", which is what every other moment of this app's life
        // should do.
        signal(SIGTERM, SIG_DFL)
        signal(SIGINT, SIG_DFL)
    }

    /// Close both tracks and leave the meeting where the batch queue will find it. Deliberately not
    /// the whole of ``stop()``: transcribing an hour of audio is not something to start when the
    /// system has asked the process to go away, and `resumePendingOnLaunch` is already the queue for
    /// anything left at `transcribing`.
    func finaliseForTermination() async {
        guard case .recording = phase, let meetingID else { return }
        phase = .stopping
        meterTask?.cancel()
        meterTask = nil
        mic.stop()
        await system.stop()
        try? store.updateMeeting(id: meetingID) { meeting in
            meeting.state = .transcribing
            meeting.endedAt = Date()
        }
    }

    /// Take over a set of signals, delivered to `onSignal` on the main queue.
    ///
    /// `DispatchSource` rather than `signal(2)`'s handler because the work is finalising audio
    /// files: almost nothing in Foundation is safe to call from inside a real signal handler, and a
    /// dispatch source is delivered like any other event, on a thread that is allowed to do things.
    /// Ignoring the signal first is what stops the default action — terminating — from happening
    /// before the source ever runs.
    ///
    /// Internal, and returning its sources, so a test can prove a real signal reaches a real
    /// handler without the process exiting under it.
    static func trap(
        _ signals: [Int32], onSignal: @escaping @Sendable () -> Void
    ) -> [any DispatchSourceProtocol] {
        signals.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler(handler: onSignal)
            source.resume()
            return source
        }
    }

    /// Stops both tracks, moves the meeting to `transcribing`, and runs the batch pass. A batch pass
    /// that fails leaves the phase `.failed` but does **not** throw: the audio is on disk and the
    /// meeting is recoverable, so the stop itself succeeded.
    public func stop() async throws {
        guard case .recording = phase, let meetingID else { throw RecordingError.notRecording }
        phase = .stopping
        meterTask?.cancel()
        meterTask = nil
        // Last look before the recorders are torn down: a disk that filled in the final tick would
        // otherwise take its explanation with it — the system recorder drops its writer on stop.
        noteCaptureFailures()
        removeTerminationGuard()

        mic.stop()
        await system.stop()
        levels = [:]
        if systemAudioUnavailable == nil, let failure = system.failure {
            systemAudioUnavailable = String(describing: failure)
        }
        // Before the batch pass, not after: it deletes the live rows, so anything still in flight
        // would be written back seconds later and outlive the transcript that replaced it.
        await stopLiveTranscription()
        if let audioDirectory { auditCapturedAudio(meetingID: meetingID, in: audioDirectory) }

        try store.updateMeeting(id: meetingID) { meeting in
            meeting.state = .transcribing
            meeting.endedAt = Date()
        }

        phase = .transcribing(progress: 0)
        do {
            try await transcription.runBatchPass(meetingID: meetingID) { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .transcribing = self.phase else { return }
                    self.phase = .transcribing(progress: progress)
                }
            }
            phase = .idle
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Did the microphone actually record anything, or did the device hand us zeros?
    ///
    /// A mic returning pure digital silence — what macOS delivers when microphone access is denied,
    /// and what a broken duplex route delivers on some hardware — produces a full-length WAV, a
    /// clean batch pass, no mic segments and a meeting at `ready`. Nothing about that says half the
    /// meeting is missing, and the half that is missing is the user's own voice.
    ///
    /// So the file is read back the moment the writers close it and the verdict is stored as a
    /// **capture** issue, which the transcriber's all-clear cannot take down: the batch pass reads a
    /// silent WAV perfectly well and would otherwise clear the warning on its way past.
    ///
    /// Mic only. On the system track digital silence is the ordinary outcome of an in-person meeting
    /// with nothing playing, and a warning that fires on every one of those is a warning nobody
    /// reads by the time it is true. The system channel's real failure — the stream refusing to
    /// start — is caught at `start()` and reported through ``systemAudioUnavailable``.
    ///
    /// Internal, and taking its directory rather than reading the one `start()` stored, so a test
    /// can drive the exact code the stop path runs against a hand-written silent WAV — the failure
    /// itself is a denied permission on real hardware and cannot be reproduced any other way.
    func auditCapturedAudio(meetingID: String, in directory: URL) {
        let url = directory.appendingPathComponent("\(Channel.mic.rawValue).wav")
        guard let audit = ChannelAudit.read(url), audit.deliveredNoSignal else { return }
        try? store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meetingID,
            channel: .mic,
            kind: .capture,
            reason: ChannelAudit.noSignalReason(.mic)
        ))
    }

    // MARK: - Live transcription

    /// One transcriber per channel, fed from the capture writer's own 16 kHz output. Capture is not
    /// re-plumbed for it: the writer already resamples to exactly what Parakeet wants, so the live
    /// pass reads the same samples that reach the WAV and cannot drift from it.
    ///
    /// Internal rather than private so a test can drive the live path without opening a microphone:
    /// what the controller owes the store is worth testing on a machine with no model downloaded.
    func attachLive(
        _ channel: Channel,
        meetingID: String,
        install: (@escaping @Sendable ([Float], Int) -> Void) -> Void
    ) {
        let transcriber = makeLiveTranscriber()
        // The tap fires on the capture thread and must not block or reorder. A stream is the queue:
        // yielding is non-blocking, and a single consumer keeps the samples in the order they were
        // captured, which a `Task` per buffer would not. Unbounded because the only thing that fills
        // it is the model load at the head of the meeting — after that the recogniser runs about
        // twenty times faster than the audio arrives.
        let (samples, feed) = AsyncStream<([Float], Int)>.makeStream(bufferingPolicy: .unbounded)
        install { chunk, atMs in feed.yield((chunk, atMs)) }

        let sink = Task { @MainActor [weak self] in
            for await segment in transcriber.segments {
                self?.commit(segment, channel: channel, meetingID: meetingID)
            }
        }
        let report: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor in self?.noteLiveUnavailable(error) }
        }
        let pump = Task.detached {
            do {
                try await transcriber.start(channel: channel)
            } catch {
                report(error)
                feed.finish()
                await transcriber.finish()
                return
            }
            for await (chunk, atMs) in samples {
                try? await transcriber.feed(chunk, atMs: atMs)
            }
        }
        live[channel] = LiveChannel(transcriber: transcriber, feed: feed, pump: pump, sink: sink)
    }

    /// Drains in order — no more samples, feeding finished, tail flushed, segments written — because
    /// each stage's output is the next stage's input and cutting one short loses the last sentence.
    func stopLiveTranscription() async {
        guard !live.isEmpty else { return }
        mic.onSamples16k = nil
        system.onSamples16k = nil
        let channels = Array(live.values)
        live = [:]
        await drain(channels)
    }

    private func detachLive(_ channel: Channel) async {
        guard let attached = live.removeValue(forKey: channel) else { return }
        await drain([attached])
    }

    /// Stage by stage across every channel rather than channel by channel: each stage's output is
    /// the next stage's input, and the tail flush costs a second of model time that both channels
    /// may as well spend at once.
    private func drain(_ channels: [LiveChannel]) async {
        for channel in channels { channel.feed.finish() }
        for channel in channels { await channel.pump.value }
        for channel in channels { await channel.transcriber.finish() }
        for channel in channels { await channel.sink.value }
    }

    /// Writes a live segment, growing the phrase already on screen when this is more of it.
    ///
    /// The recogniser cannot hand over whole phrases inside the one-second bar: it is 310–630
    /// ms behind the audio by construction, so waiting for enough silence to be *sure* a phrase has
    /// ended puts the words on screen at 1.4 s or later. Measured on this machine, every extra
    /// millisecond of silence the segmenter waits for is a millisecond of latency, one for one —
    /// there is no threshold that buys phrases for free.
    ///
    /// So the words are still emitted the moment they are known, and the phrase is assembled in the
    /// row instead of before it. A burst that continues the previous one — same channel, less than
    /// a second of audio between them, no sentence-ending punctuation, not yet at the word cap —
    /// extends that row. Anything else starts a new one. The reader sees a line grow rather than
    /// six lines of two words each, and the first word still arrives when it always did.
    private func commit(_ segment: EngineSegment, channel: Channel, meetingID: String) {
        if let index = liveSegments.lastIndex(where: { $0.channel == channel }),
           let id = liveSegments[index].id,
           Self.continuesPhrase(liveSegments[index], next: segment),
           let grown = try? store.extendSegment(id: id, appending: segment.text, tEndMs: segment.endMs) {
            liveSegments[index] = grown
            return
        }
        guard let row = try? store.insertSegment(TranscriptSegment(
            meetingID: meetingID,
            channel: channel,
            tStartMs: segment.startMs,
            tEndMs: segment.endMs,
            text: segment.text,
            pass: .live
        )) else { return }
        liveSegments.append(row)
    }

    /// The same three rules `EngineSegment.grouped` breaks on, asked in the other direction — a
    /// silence, a full stop, or a phrase long enough to be its own paragraph — so a phrase reads the
    /// same whether its words happened to arrive in one burst or in five.
    static func continuesPhrase(_ current: TranscriptSegment, next: EngineSegment) -> Bool {
        guard next.startMs - current.tEndMs <= livePhraseGapMs else { return false }
        guard !current.text.hasSuffix(".") && !current.text.hasSuffix("?")
            && !current.text.hasSuffix("!") else { return false }
        return current.text.split(separator: " ").count < livePhraseMaxWords
    }

    /// Deliberately shorter than `EngineSegment.grouped`'s second, because it is not measuring the
    /// same thing. In `grouped` a word's end is back-filled from the next word's start, so the gap
    /// it sees mid-phrase is zero and a full second only elapses in real silence. Here the previous
    /// row ends at its last word's *onset* plus one nominal frame, so the measured gap carries that
    /// word's own duration on top of the silence.
    ///
    /// Calibrated against a real run of the shipping transcriber (12.75 s of speech, three
    /// sentences): mid-phrase gaps came in at 160–560 ms and the two sentence boundaries at 720 and
    /// 880 ms. 700 ms sits in that valley. It is a knob, and a much faster or slower speaker will
    /// want it moved — the failure mode either side is cosmetic, which is why it is a constant here
    /// and not a setting.
    static let livePhraseGapMs = 700
    static let livePhraseMaxWords = 60

    /// First reason wins: the mic channel is the one that matters, and it is attached first.
    private func noteLiveUnavailable(_ error: Error) {
        guard liveTranscriptionUnavailable == nil else { return }
        liveTranscriptionUnavailable = String(describing: error)
    }

    private struct LiveChannel {
        let transcriber: StreamingTranscriber
        let feed: AsyncStream<([Float], Int)>.Continuation
        let pump: Task<Void, Never>
        let sink: Task<Void, Never>
    }

    // MARK: -

    /// The meters are polled rather than pushed. A tap callback fires every few milliseconds on the
    /// render thread and hopping to the main actor that often to move a Float would cost more than
    /// the capture does.
    private func startMetering() {
        meterTask = Task { @MainActor [mic, system] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                self.levels = [.mic: mic.level, .system: system.level]
                self.noteCaptureFailures()
            }
        }
    }

    /// A track that has stopped growing while the meeting is still running, told while there is
    /// still time to do something about it. Driven from the meter tick, which is already running,
    /// so nothing new is polled.
    func noteCaptureFailures() {
        for (channel, failure) in [(Channel.mic, mic.writeFailure), (.system, system.writeFailure)] {
            if let failure { report(channel, failure.reason) }
        }
        noteStalledMic()
    }

    /// **The microphone going away mid-meeting.** Unplugging a USB interface, or an audio device
    /// change stopping `AVAudioEngine` underneath the tap, both end with the same silence: the tap
    /// stops firing and the WAV stops growing, while the clock keeps climbing and the meeting looks
    /// like it is being recorded. A running engine delivers buffers continuously — silence included
    /// — so a mic that has delivered nothing for ten seconds has stopped, and saying so is the
    /// difference between losing the rest of the meeting and losing ten seconds of it.
    ///
    /// Mic only. The system track legitimately has nothing to deliver when nothing is playing, and
    /// a warning that fires on every in-person meeting is one nobody reads by the time it is true.
    private func noteStalledMic() {
        guard case .recording = phase, !reportedCaptureFailures.contains(.mic) else { return }
        guard Self.hasStalled(frames: mic.framesWritten, progress: &micProgress, now: Date())
        else { return }
        report(.mic, "the microphone stopped delivering audio, so nothing more was recorded on "
            + "this channel. The usual cause is the input device changing or being unplugged "
            + "mid-meeting. Everything recorded up to that point is safe.")
    }

    /// The rule itself, kept pure and separate from the recorder: a microphone cannot be opened in
    /// `swift test` without asking the operator for a permission, and the one thing here that can
    /// be got wrong quietly — firing during start latency, or never firing at all — is decidable
    /// from a frame count and a clock.
    static func hasStalled(
        frames: Int64, progress: inout (frames: Int64, at: Date)?, now: Date
    ) -> Bool {
        // Nothing yet is start latency, not a stall.
        guard frames > 0 else { return false }
        guard let seen = progress, seen.frames == frames else {
            progress = (frames, now)
            return false
        }
        return now.timeIntervalSince(seen.at) > captureStallSeconds
    }

    static let captureStallSeconds: TimeInterval = 10

    /// Once per channel per session, on every surface there is.
    ///
    /// All three are used deliberately: the property is what a live recording screen can show now,
    /// the stored issue is what survives into `meetings show`, the list mark and the banner after
    /// the stop, and the log line is what an agent tailing the app sees. A warning that only
    /// existed in memory would die with the process that could not write to disk.
    private func report(_ channel: Channel, _ reason: String) {
        guard !reportedCaptureFailures.contains(channel) else { return }
        reportedCaptureFailures.insert(channel)
        if captureWriteFailure == nil { captureWriteFailure = reason }
        FileHandle.standardError.write(Data(
            "Meetings: \(channel.rawValue) capture: \(reason)\n".utf8))
        guard let meetingID else { return }
        try? store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meetingID, channel: channel, kind: .capture, reason: reason))
    }
}

public enum RecordingError: Error, CustomStringConvertible {
    case notImplemented
    case alreadyRecording
    case notRecording
    case microphoneUnavailable(String)
    case systemAudioUnavailable(String)

    public var description: String {
        switch self {
        case .notImplemented: "recording is not wired up yet"
        case .alreadyRecording: "a recording is already running"
        case .notRecording: "nothing is recording"
        case .microphoneUnavailable(let why): "microphone unavailable: \(why)"
        case .systemAudioUnavailable(let why): "system audio unavailable: \(why)"
        }
    }
}
