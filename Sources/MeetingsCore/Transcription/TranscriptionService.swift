import Foundation

/// Owns the models and the batch queue. One instance per process.
///
/// The batch pass is deliberately independent of recording: it reads two WAVs off disk and writes
/// segments to the store, which is exactly what an imported meeting needs too.
public actor TranscriptionService {
    let store: MeetingStore

    /// Injected engine, else one built from settings on first use. Held so the models are loaded
    /// once per process rather than once per meeting.
    private var engine: TranscriptionEngine?
    private let audioRoot: URL?

    /// The one in-flight model download, if any, with an id so a joiner can tell whether the slot it
    /// is clearing is still the one it waited on. See ``prepareModels(progress:)``.
    private var preparation: (id: UUID, task: Task<Void, Error>)?
    /// Every caller currently watching that download. A dictionary rather than an array so a caller
    /// that goes away removes exactly its own closure.
    private var progressObservers: [UUID: @Sendable (Double) -> Void] = [:]
    private var lastProgress: Double = 0

    private var pending: [String] = []
    private var running: String?
    private var worker: Task<Void, Never>?
    /// A meeting whose pass just threw stays at `transcribing` — the store is the queue, so it is
    /// picked up again next launch — but retrying it in a loop now would spin on a corrupt file.
    private var failedThisSession: Set<String> = []

    /// What the most recent batch pass did with the custom vocabulary in effect, so the
    /// feature is inspectable rather than a black box.
    ///
    /// In memory only, and that is a gap rather than a design: the natural home is a row per pass
    /// beside `transcript_issues`, which needs a migration and a store accessor this unit does not
    /// own. Until then it survives as long as the process does.
    public private(set) var lastVocabularyReport: VocabularyBiasingReport?

    public init(store: MeetingStore) {
        self.init(store: store, engine: nil, audioRoot: nil)
    }

    /// Injection seam. Tests supply a stub engine (600 MB of models is not a unit test) and a
    /// throwaway audio root, because `Paths` reads process environment that tests must not mutate.
    init(store: MeetingStore, engine: TranscriptionEngine?, audioRoot: URL?) {
        self.store = store
        self.engine = engine
        self.audioRoot = audioRoot
    }

    // MARK: - Models

    /// Downloads **both** Parakeet models if they are absent and loads them. `progress` is 0…1 and
    /// may be called from any executor.
    ///
    /// Both, because there are two engines and only one of them can be fetched on demand. The batch
    /// pass runs after a meeting, so a download there costs you a wait. The live pass runs *during*
    /// one, and `FluidAudioStreamingTranscriber.start` therefore refuses to download rather than put
    /// a network fetch between pressing record and capturing the room — which means a live model
    /// that was never fetched in advance is a live transcript that silently never appears. Onboarding
    /// is the only honest place to pay for it.
    ///
    /// Calling this while a download is already running **joins** that download. It does not start a
    /// second one.
    ///
    /// It used to start a second one, and the third and fourth presses started those too. Measured on
    /// a real install: three write file descriptors open on the same
    /// `Encoder.mlmodelc/weights/weight.bin.partial`, four connections to the CDN, and whichever
    /// writer finished last renaming a file the other two were still writing into. The visible
    /// symptom was a progress bar going backwards — 39% then 6% — because the bar was being driven by
    /// a different download each time, not because one had regressed. The invisible symptom is the
    /// one that matters: a model file interleaved from three streams can be the right size and still
    /// be garbage, and it fails later as a transcriber that loads and emits nonsense.
    ///
    /// The guard is here rather than in the button that was pressed twice, because the button is not
    /// the only caller: Settings has one, and the batch pass prepares models on demand too.
    public func prepareModels(progress: @Sendable @escaping (Double) -> Void) async throws {
        let observer = UUID()
        progressObservers[observer] = progress
        // A joiner is told where the download actually is before it waits, so arriving at 40% does
        // not draw an empty bar until the next tick.
        progress(lastProgress)
        defer { progressObservers[observer] = nil }

        if preparation == nil {
            lastProgress = 0
            let id = UUID()
            preparation = (id, Task { try await self.runPreparation() })
        }
        guard let current = preparation else { return }

        do {
            try await current.task.value
        } catch {
            // Compared by id, not by clearing blindly: joiners resume one at a time, and a later one
            // clearing the slot after a *new* download had claimed it would untrack that download and
            // let the next press start yet another.
            if preparation?.id == current.id { preparation = nil }
            throw error
        }
        if preparation?.id == current.id { preparation = nil }
    }

    private func runPreparation() async throws {
        let option: LocalTranscriptionOption
        switch plan() {
        case .cloud:
            // Cloud downloads nothing at all — not the batch model, and not the live one either.
            // That is the point of the option: somebody who chose an endpoint to avoid a 600 MB
            // fetch has not agreed to a 250 MB one for a live pane. It costs them the live
            // transcript, which the wizard and Settings both say in as many words.
            return publish(1)
        case .injected:
            // A handed-in engine is still prepared — that is what a caller injecting one is asking
            // for — but there is no live model behind it to go and fetch.
            try await resolvedEngine().prepare(progress: { [weak self] value in
                Task { await self?.publish(value * 0.6) }
            })
            return publish(1)
        case .local(let chosen):
            option = chosen
        }

        // The batch model is the larger of the two, and the one a meeting cannot be written up
        // without, so it goes first and takes the bigger share of the bar. An option with no
        // separate batch pass has one model, which then owns the whole bar.
        let liveShare = option.runsSeparateBatchPass ? 0.4 : 1.0
        if liveShare < 1 {
            try await resolvedEngine().prepare(progress: { [weak self] value in
                Task { await self?.publish(value * (1 - liveShare)) }
            })
        }
        guard !FluidAudioStreamingTranscriber.modelsAreCached(option.liveVariant) else {
            return publish(1)
        }
        try await FluidAudioStreamingTranscriber.prepareModels(
            variant: option.liveVariant,
            progress: { [weak self] value in
                Task { await self?.publish((1 - liveShare) + value * liveShare) }
            }
        )
        publish(1)
    }

    /// `max`, not assignment. The engines report progress from arbitrary executors and each hop onto
    /// this actor is its own task, so two ticks can land out of order — and a bar that jitters
    /// backwards is exactly the symptom that made this look like a restart in the first place.
    private func publish(_ value: Double) {
        lastProgress = max(lastProgress, value)
        for observer in progressObservers.values { observer(lastProgress) }
    }

    /// Whether a download is running, so a view that was destroyed and rebuilt can rejoin it rather
    /// than offering a button that starts one.
    public var isPreparingModels: Bool { preparation != nil }

    /// Drops the engine resolved on first use, so the next pass reads the settings again.
    ///
    /// The cache exists to load 600 MB of Core ML once per process rather than once per meeting,
    /// and it is right for that — but it also outlives a user changing the engine in Settings or in
    /// the wizard, which is how "I switched to my own endpoint and it still transcribed locally"
    /// happens. An injected engine is never dropped: a test's stub is not a cached resolution.
    public func forgetResolvedEngine() async {
        guard let current = engine, current is FluidAudioBatchEngine || current is OpenAICompatibleRemoteEngine
        else { return }
        await current.release()
        engine = nil
    }

    /// What this store is actually set up to do, resolved once. Every gate below reads it, so no two
    /// of them can disagree about whether this install needs a download at all.
    ///
    /// The injected-engine case comes first and stays first: tests hand in a stub engine precisely
    /// so they never touch settings, the network or 600 MB of Core ML.
    enum Plan {
        /// Models on this Mac, and which ones.
        case local(LocalTranscriptionOption)
        /// A remote endpoint was chosen. Nothing is downloaded, whether or not it is fully filled
        /// in — an unconfigured endpoint is a setup problem to report, never a reason to quietly
        /// fetch 600 MB of models the user explicitly declined.
        case cloud(configured: Bool)
        /// An engine was handed in. Nothing to download and nothing to check.
        case injected
    }

    func plan() -> Plan {
        if engine != nil, !(engine is FluidAudioBatchEngine) { return .injected }
        guard store.transcriptionEngine() == .cloud else { return .local(localOption()) }
        return .cloud(configured: remoteConfiguration() != nil)
    }

    func localOption() -> LocalTranscriptionOption {
        store.localTranscriptionOption()
    }

    /// Cheap, synchronous-ish check used by onboarding, the recording prerequisites and
    /// `meetings status`. No download, and no network.
    ///
    /// "Ready" means *this engine* can transcribe, which is why it is not a file-existence check any
    /// more. On the cloud path there are no models by design and a hard "the models are missing"
    /// would have told a correctly configured user that recording was broken, on every launch,
    /// forever. On the local path it is still every model the chosen option needs: reporting ready
    /// on the batch model alone is what let a fresh install finish setup, start its first meeting,
    /// and find the live transcript empty with nothing having warned it would be.
    public func modelsReady() async -> Bool {
        switch plan() {
        case .injected:
            return true
        case .cloud(let configured):
            return configured
        case .local(let option):
            guard FluidAudioStreamingTranscriber.modelsAreCached(option.liveVariant) else {
                return false
            }
            guard option.runsSeparateBatchPass else { return true }
            return FluidAudioBatchEngine.modelsAreCached()
        }
    }

    /// One sentence naming what transcription is wired up to do, for `meetings status` and Settings.
    /// Says what is configured *and* whether it can run, because a cloud endpoint with a missing key
    /// and a local model that was never downloaded look identical from outside.
    public func engineSummary() async -> String {
        switch plan() {
        case .injected:
            return "a test engine is installed"
        case .cloud(let configured):
            let model = setting(.transcribeRemoteModel) ?? "?"
            let host = (setting(.transcribeRemoteBaseURL)).flatMap { URL(string: $0)?.host() } ?? "?"
            guard configured else {
                return "a remote endpoint is selected but not fully configured, so no meeting can "
                    + "be transcribed. Set transcribe.remote.baseURL, .model and .keyRef, and put "
                    + "the key in the Keychain"
            }
            return "remote endpoint \(host) (model \(model)); audio for each meeting is uploaded there"
        case .local(let option):
            let ready = await modelsReady()
            return ready
                ? "on this Mac: \(option.title) — \(option.liveModel) live, \(option.finalModel)"
                : "on this Mac: \(option.title) — not downloaded yet (\(option.downloadSizeText)). "
                    + "The app downloads it on first run"
        }
    }

    // MARK: - The batch pass

    /// Transcribe both channel files and apply the replace-and-remap transaction. Callable
    /// with no live session — this is also how an imported meeting gets its transcript.
    ///
    /// The two channels are transcribed **separately and never merged into one file**: which file a
    /// segment came out of is the whole of the app's speaker attribution. A failure on one
    /// channel is recorded and the other channel's transcript is still written — losing your side of
    /// the call because the system-audio file was truncated would be a bad trade.
    ///
    /// A failed channel costs the user nothing it does not have to. Its rows are left where they are
    /// — the rough live text is the only record of that side of the meeting once the file will not
    /// open — and the reason is written to `transcript_issues`, which is what makes the half
    /// transcript legible as a half transcript rather than as a finished one. Reaching `ready` with
    /// one channel missing and a recorded reason is the honest outcome; reaching it silently is the
    /// bug this replaced.
    public func runBatchPass(
        meetingID: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard try store.meeting(id: meetingID) != nil else {
            throw StoreError.meetingNotFound(meetingID)
        }
        let files = channelFiles(meetingID: meetingID)
        guard !files.isEmpty else { throw TranscriptionError.noAudio(meetingID) }

        // Mark it before any work: if the process dies mid-pass the row still says `transcribing`,
        // which is what `resumePendingOnLaunch` looks for. The audio directory is recorded in the
        // same breath: an imported meeting arrives with two WAVs on disk and no `audio_path`, which
        // makes the app report no audio and — worse — makes the retention sweep, which keys off
        // `audio_path`, unable to ever find the files it is supposed to delete.
        let directory = audioDirectory(meetingID: meetingID)
        try store.updateMeeting(id: meetingID) { meeting in
            meeting.state = .transcribing
            // Never resurrect a purged path: `audio_purged_at` means the files are gone on
            // purpose, and a leftover WAV is not a reason to say the audio is back.
            if meeting.audioPath == nil, meeting.audioPurgedAt == nil {
                meeting.audioPath = directory.path
            }
        }

        // An option whose live model *is* its final model has no second pass to run. The live rows
        // are already the transcript, so they are handed back through the same replace-and-remap
        // transaction every other path ends in — which is what promotes them from `live` to `final`,
        // remaps the notes and moves the meeting to `ready`. Skipping the call instead would leave
        // the meeting at `transcribing` forever.
        if case .local(let option) = plan(), !option.runsSeparateBatchPass {
            let live = try store.segments(meetingID: meetingID)
            try store.replaceLiveSegments(
                meetingID: meetingID,
                with: live.filter { !$0.edited }.map {
                    TranscriptSegment(
                        meetingID: meetingID, channel: $0.channel, tStartMs: $0.tStartMs,
                        tEndMs: $0.tEndMs, text: $0.text, pass: .final)
                },
                channels: Set(files.map(\.channel))
            )
            progress(1)
            return
        }

        let engine = try resolvedEngine()
        // Preparing is part of the pass — on a fresh install the first batch pass is what downloads
        // the models. Give it the first tenth of the bar and split the rest across the channels.
        try await engine.prepare(progress: { progress($0 * 0.1) })

        let vocabulary = (try? store.vocabularyInEffect(meetingID: meetingID)) ?? []
        var segments: [TranscriptSegment] = []
        var transcribed: Set<Channel> = []
        var failures: [(channel: Channel, error: Error)] = []
        var reports: [(channel: Channel, report: VocabularyBiasingReport)] = []

        for (index, file) in files.enumerated() {
            // Each channel gets its own slice of the bar. The engine reports inside it, which is
            // what makes the first pass with vocabulary terms — the one that fetches a second
            // ~97.5 MB model — look like work rather than like a hang.
            let base = 0.1 + 0.9 * Double(index) / Double(files.count)
            let span = 0.9 / Double(files.count)
            do {
                // The launch sweep is the general guarantee; this is the specific one. A WAV whose
                // header was never finalised reads as zero frames, and a batch pass that read it
                // that way would "succeed" with an empty transcript and delete the live rows that
                // were the only record. Repairing the file we are about to open means that cannot
                // happen even in the session that crashed, with no restart in between. Costs one
                // header read on a healthy file and writes nothing.
                try? WAVRepair.repair(at: file.url)
                let recognised = try await engine.transcribe(
                    file.url,
                    vocabulary: vocabulary,
                    progress: { progress(base + span * min(1, max(0, $0))) }
                )
                if let report = await engine.vocabularyReport() {
                    reports.append((file.channel, report))
                }
                transcribed.insert(file.channel)
                segments += recognised.map {
                    TranscriptSegment(
                        meetingID: meetingID,
                        channel: file.channel,
                        tStartMs: $0.startMs,
                        tEndMs: $0.endMs,
                        text: $0.text,
                        pass: .final
                    )
                }
            } catch {
                failures.append((file.channel, error))
            }
            progress(base + span)
        }
        lastVocabularyReport = VocabularyBiasingReport.union(reports.map(\.report))

        // Every channel dead means the transcript is missing, not empty — and the judgement is made
        // on whether the engine *ran*, not on whether it found words: a genuinely silent recording
        // returns no segments and is a successful pass. Throwing here leaves the meeting at
        // `transcribing`, which is where the queue looks for it next launch, with every live row
        // still in place.
        guard !transcribed.isEmpty else {
            throw failures.first?.error ?? TranscriptionError.noAudio(meetingID)
        }

        // Merge by offset so the transcript reads as one conversation. Channel breaks the tie so two
        // people talking over each other still come out in a stable order.
        segments.sort { ($0.tStartMs, $0.channel.rawValue) < ($1.tStartMs, $1.channel.rawValue) }
        try store.replaceLiveSegments(meetingID: meetingID, with: segments, channels: transcribed)

        // After the replace, so a store that fails to write the transcript never leaves a stale
        // all-clear behind. A channel that succeeded this time has its previous failure cleared —
        // re-running the pass on a repaired file has to take the warning down. Both of the
        // transcriber's own verdicts come down: a re-run that finally reaches the CTC model has to
        // take last week's vocabulary warning with it.
        for channel in transcribed {
            try store.clearTranscriptIssue(meetingID: meetingID, channel: channel)
            try store.clearTranscriptIssue(meetingID: meetingID, channel: channel, kind: .vocabulary)
        }
        for failure in failures {
            try store.recordTranscriptIssue(TranscriptIssue(
                meetingID: meetingID,
                channel: failure.channel,
                reason: String(describing: failure.error)
            ))
        }
        // A vocabulary pass that could not run leaves a perfectly readable transcript with the
        // user's jargon still mangled in it — the one failure nobody can see by reading the result.
        // It rides the same table as the rest of the invisible degradation, so `show`, `list`,
        // `transcript`, the bundle and the app all inherit it without knowing it exists.
        for (channel, report) in reports {
            guard let why = report.unavailable else { continue }
            try store.recordTranscriptIssue(TranscriptIssue(
                meetingID: meetingID, channel: channel, kind: .vocabulary, reason: why
            ))
        }
        progress(1)
    }

    // MARK: - The queue

    /// The store *is* the queue: a meeting at `transcribing` is pending work, so a quit loses
    /// nothing and there is no second queue file to fall out of step with the database.
    public func enqueue(meetingID: String) async {
        guard running != meetingID, !pending.contains(meetingID) else { return }
        try? markTranscribing(meetingID)
        pending.append(meetingID)
        startWorker()
    }

    /// Oldest first — an imported backlog comes out in the order it went in, and the meeting that
    /// has been waiting longest is the one the user is waiting on.
    public func resumePendingOnLaunch() async {
        for id in pendingMeetingIDs() where !failedThisSession.contains(id) {
            await enqueue(meetingID: id)
        }
    }

    public var queueDepth: Int { pending.count + (running == nil ? 0 : 1) }

    func pendingMeetingIDs() -> [String] {
        let rows = (try? store.meetings(state: .transcribing)) ?? []
        return rows
            .sorted { ($0.sortDate ?? .distantPast, $0.id) < ($1.sortDate ?? .distantPast, $1.id) }
            .map(\.id)
    }

    /// Test seam: wait for the queue to drain. Nothing in the app waits on the queue — the UI
    /// watches meeting state instead.
    func waitForQueue() async {
        await worker?.value
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { await self.drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let id = pending.removeFirst()
            running = id
            do {
                try await runBatchPass(meetingID: id, progress: { _ in })
            } catch {
                failedThisSession.insert(id)
            }
            running = nil
        }
        worker = nil
    }

    // MARK: -

    private func markTranscribing(_ meetingID: String) throws {
        _ = try store.updateMeeting(id: meetingID) { meeting in
            if meeting.state != .transcribing { meeting.state = .transcribing }
        }
    }

    private func audioDirectory(meetingID: String) -> URL {
        audioRoot.map { $0.appendingPathComponent(meetingID, isDirectory: true) }
            ?? Paths.audioDirectory(meetingID: meetingID)
    }

    private func channelFiles(meetingID: String) -> [(channel: Channel, url: URL)] {
        let directory = audioDirectory(meetingID: meetingID)
        return [(Channel.mic, "mic.wav"), (Channel.system, "system.wav")]
            .map { (channel: $0.0, url: directory.appendingPathComponent($0.1)) }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func resolvedEngine() throws -> TranscriptionEngine {
        if let engine { return engine }
        let resolved: TranscriptionEngine
        switch plan() {
        case .injected:
            // Unreachable by construction: `plan()` returns `.injected` only when `engine` is
            // non-nil, and a non-nil `engine` returned on the first line of this function. It traps
            // rather than falling back, because the fallback was `FluidAudioBatchEngine()` — 600 MB
            // fetched on its first `prepare` from a branch documented as impossible, which is the
            // same silent download the `.cloud` arm below was rewritten to stop.
            preconditionFailure("resolvedEngine reached .injected with no injected engine")
        case .cloud(let configured):
            guard configured, let configuration = remoteConfiguration() else {
                // The important half of this branch. Before, an incomplete remote configuration fell
                // through to `FluidAudioBatchEngine()`, which downloads 600 MB on its first
                // `prepare` — silently fetching the models the user chose the cloud to avoid, and
                // producing a local transcript from a setting that says remote.
                throw TranscriptionError.remoteFailed(
                    "the remote endpoint is selected but incomplete: base URL, model and a Keychain "
                        + "key reference are all required")
            }
            resolved = OpenAICompatibleRemoteEngine(configuration: configuration)
        case .local:
            resolved = FluidAudioBatchEngine()
        }
        engine = resolved
        return resolved
    }

    /// Nil in every configuration but the one where the user has explicitly asked for a remote batch
    /// engine *and* filled in all of it. Nil means no network call is possible.
    func remoteConfiguration() -> OpenAICompatibleRemoteEngine.Configuration? {
        guard store.transcriptionEngine() == .cloud else { return nil }
        return OpenAICompatibleRemoteEngine.Configuration.resolve(
            baseURL: setting(.transcribeRemoteBaseURL),
            model: setting(.transcribeRemoteModel),
            keyRef: setting(.transcribeRemoteKeyRef)
        )
    }

    private func setting(_ key: SettingKey) -> String? {
        (try? store.setting(key)) ?? nil
    }
}

public enum TranscriptionError: Error, CustomStringConvertible {
    case notImplemented
    case modelsUnavailable(String)
    case unreadableAudio(URL, String)
    case noAudio(String)
    case remoteFailed(String)

    public var description: String {
        switch self {
        case .notImplemented: "transcription is not wired up yet"
        case .modelsUnavailable(let why): "transcription models unavailable: \(why)"
        case .unreadableAudio(let url, let why): "unreadable audio \(url.lastPathComponent): \(why)"
        case .noAudio(let id): "meeting \(id) has no audio to transcribe"
        case .remoteFailed(let why): "remote transcription failed: \(why)"
        }
    }
}
