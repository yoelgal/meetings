import FluidAudio
import Foundation

/// Owns the model and the batch queue. One instance per process.
///
/// The pass is deliberately independent of recording: it reads two WAVs off disk and writes segments
/// to the store, which is exactly what an imported meeting needs too.
public actor TranscriptionService {
    let store: MeetingStore

    /// Injected engine, else one built from settings on first use. Held so the model is loaded once
    /// per process rather than once per meeting.
    private var engine: TranscriptionEngine?
    /// Whether ``engine`` is this actor's own cache of what the settings said, as opposed to one a
    /// caller handed in.
    ///
    /// Both live in the same slot and they are not the same thing: an injected engine means "use this
    /// and read no settings", a resolved one is a cache with no authority of its own. ``plan()`` and
    /// ``forgetResolvedEngine()`` both have to tell them apart, and both used to do it by asking what
    /// *type* the engine was — which meant every engine type had to be named in two `is` checks, a
    /// test's stub was indistinguishable from a cached resolution, and the answer could flip halfway
    /// through a process the moment a resolution landed in the slot.
    private var engineWasResolved = false
    private let audioRoot: URL?
    /// How the local branch gets its engine.
    ///
    /// A seam, because the `engine` parameter cannot do this job: handing an engine in makes
    /// ``plan()`` report `.injected`, which is precisely the branch that skips the local decision —
    /// promote the live rows, or transcribe the files — that this service exists to make. Passing the
    /// factory instead leaves the plan reading the settings, so a test can drive the local path
    /// without 600 MB of Core ML.
    private let localEngine: @Sendable (StreamingModelVariant) -> TranscriptionEngine

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

    /// What the most recent pass did with the custom vocabulary in effect, so the feature is
    /// inspectable rather than a black box.
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
    init(
        store: MeetingStore,
        engine: TranscriptionEngine?,
        audioRoot: URL?,
        localEngine: @escaping @Sendable (StreamingModelVariant) -> TranscriptionEngine = {
            StreamingFileEngine(variant: $0)
        }
    ) {
        self.store = store
        self.engine = engine
        self.audioRoot = audioRoot
        self.localEngine = localEngine
    }

    // MARK: - Models

    /// Downloads the local model if it is absent and loads it. `progress` is 0…1 and may be called
    /// from any executor.
    ///
    /// One model, which is the point of ``LocalTranscriber``: the checkpoint that writes the live
    /// pane is the same one ``StreamingFileEngine`` drives over a file, so there is nothing to
    /// download twice and no second, larger model that only turns up after the first meeting ends.
    /// It has to be fetched *in advance* all the same: `FluidAudioStreamingTranscriber.start` refuses
    /// to download rather than put a network fetch between pressing record and capturing the room,
    /// which means a model that was never fetched is a live transcript that silently never appears.
    /// Onboarding is the only honest place to pay for it.
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
        let transcriber: LocalTranscriber
        switch plan() {
        case .cloud:
            // Cloud downloads nothing at all — not a file model, and not a live one either. That is
            // the point of the option: somebody who chose an endpoint to avoid a large fetch has not
            // agreed to a smaller one for a live pane. It costs them the live transcript, which the
            // wizard and Settings both say in as many words.
            return publish(1)
        case .injected:
            // A handed-in engine is still prepared — that is what a caller injecting one is asking
            // for — but there is no live model behind it to go and fetch.
            try await resolvedEngine().prepare(progress: { [weak self] value in
                Task { await self?.publish(value) }
            })
            return publish(1)
        case .local(let chosen):
            transcriber = chosen
        }

        // One model owns the whole bar. It used to own 60% of it, with a separate larger batch model
        // taking the rest, and a bar that stopped at 60% on an install that only ever needed the one
        // model read as a download that had stalled.
        guard !FluidAudioStreamingTranscriber.modelsAreCached(transcriber.variant) else {
            return publish(1)
        }
        try await FluidAudioStreamingTranscriber.prepareModels(
            variant: transcriber.variant,
            progress: { [weak self] value in
                Task { await self?.publish(value) }
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
    /// The cache exists to load the model once per process rather than once per meeting, and it is
    /// right for that — but it also outlives a user changing the engine in Settings or in the wizard,
    /// which is how "I switched to my own endpoint and it still transcribed locally" happens. An
    /// injected engine is never dropped: a test's stub is not a cached resolution.
    public func forgetResolvedEngine() async {
        guard engineWasResolved, let current = engine else { return }
        await current.release()
        engine = nil
        engineWasResolved = false
    }

    /// What this store is actually set up to do, resolved once. Every gate below reads it, so no two
    /// of them can disagree about whether this install needs a download at all.
    ///
    /// The injected-engine case comes first and stays first: tests hand in a stub engine precisely
    /// so they never touch settings, the network or 600 MB of Core ML.
    enum Plan {
        /// The model on this Mac. Which model is not a choice; see ``LocalTranscriber``.
        case local(LocalTranscriber)
        /// A remote endpoint was chosen. Nothing is downloaded, whether or not it is fully filled
        /// in — an unconfigured endpoint is a setup problem to report, never a reason to quietly
        /// fetch a model the user explicitly declined.
        case cloud(configured: Bool)
        /// An engine was handed in. Nothing to download and nothing to check.
        case injected
    }

    func plan() -> Plan {
        if engine != nil, !engineWasResolved { return .injected }
        guard store.transcriptionEngine() == .cloud else { return .local(.current) }
        return .cloud(configured: remoteConfiguration() != nil)
    }

    /// Cheap, synchronous-ish check used by onboarding, the recording prerequisites and
    /// `meetings status`. No download, and no network.
    ///
    /// "Ready" means *this engine* can transcribe, which is why it is not a file-existence check any
    /// more. On the cloud path there are no models by design and a hard "the models are missing"
    /// would have told a correctly configured user that recording was broken, on every launch,
    /// forever. On the local path it is one question now rather than two, because the live pane and
    /// the file pass load the same checkpoint: reporting ready on one model while another was missing
    /// is what let a fresh install finish setup, start its first meeting, and find the transcript
    /// empty with nothing having warned it would be.
    public func modelsReady() async -> Bool {
        switch plan() {
        case .injected:
            return true
        case .cloud(let configured):
            return configured
        case .local(let transcriber):
            return FluidAudioStreamingTranscriber.modelsAreCached(transcriber.variant)
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
            let base = setting(.transcribeRemoteBaseURL)
            let host = base.flatMap { URL(string: $0)?.host() } ?? "?"
            guard configured else {
                return "a remote endpoint is selected but not fully configured, so no meeting can "
                    + "be transcribed. Set transcribe.remote.baseURL, .model and .keyRef, and put "
                    + "the key in the Keychain"
            }
            return "remote endpoint \(host) (model \(model)); audio for each meeting is uploaded there"
                + (isCleartextEgress(base) ? ", in the clear over http — anything between this Mac "
                    + "and \(host) can read it. `meetings config set transcribe.remote.baseURL` no "
                    + "longer accepts http, but a URL stored before that is still used" : "")
        case .local(let transcriber):
            return await modelsReady()
                ? "on this Mac (\(transcriber.languages)); nothing is uploaded"
                : "on this Mac, but not downloaded yet (\(transcriber.downloadSizeText)). "
                    + "The app downloads it on first run"
        }
    }

    /// Whether the stored endpoint uploads over cleartext `http` to somewhere other than this Mac.
    ///
    /// The refusal in ``SettingKey/egressRefusal(_:for:)`` is a *write* gate, so a URL written
    /// before it existed keeps uploading every meeting's audio in the clear. Settings says so under
    /// the field; until now `meetings status` did not, and an upgrade is exactly when somebody is
    /// looking at that line. Same predicate as the gate, narrowed to `http` so a merely malformed
    /// URL — which the gate also refuses — is not described as cleartext.
    private func isCleartextEgress(_ value: String?) -> Bool {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "http" else {
            return false
        }
        return SettingKey.egressRefusal(value, for: .transcribeRemoteBaseURL) != nil
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

        // **The local model runs once, and the live text is the transcript.** So a meeting that was
        // streamed already has its transcript in the store: the live rows are handed back through the
        // same replace-and-remap transaction every other path ends in, which promotes them from
        // `live` to `final`, remaps the notes and moves the meeting to `ready`. Skipping the call
        // would leave the meeting at `transcribing` for ever, which is where the queue looks for work.
        //
        // **And a meeting that was never streamed has to be transcribed from its files.** That was
        // the shipped bug (papercut 2662434591): the promote branch ran whether or not there were any
        // live rows to promote, so an *import* — two WAVs and no live session — was "promoted" from
        // nothing, reached `ready`, and showed an empty transcript with no error anywhere. The
        // condition is the presence of live rows, not the engine's identity, because those are the
        // two genuinely different situations the file on disk cannot tell you apart.
        if case .local = plan() {
            let stored = try store.segments(meetingID: meetingID)
            if stored.contains(where: { $0.pass == .live }) {
                try await promoteLiveSegments(
                    meetingID: meetingID, stored: stored, files: files, progress: progress)
                return
            }
        }

        let engine = try resolvedEngine()
        // Preparing is part of the pass — on a fresh install the first batch pass is what downloads
        // the model. Give it the first tenth of the bar and split the rest across the channels.
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

    /// The live rows *are* the transcript, so promote them — and correct their jargon on the way.
    ///
    /// The vocabulary pass is the part that is easy to leave out and impossible to notice missing.
    /// Biasing needs the samples the words were recognised from, which the live path never kept, so
    /// it is redone here against the recording on disk: same rows, same timings, only the spelling of
    /// the terms the user added changes. Without this, every recorded meeting silently ignored the
    /// Vocabulary tab and only *imports* got their jargon fixed — the surface would still list the
    /// terms, and nothing would ever apply them.
    ///
    /// Per channel, because a term is scored against the audio it was said in: the microphone's
    /// samples cannot tell you where a word in the system audio was spoken.
    private func promoteLiveSegments(
        meetingID: String,
        stored: [TranscriptSegment],
        files: [(channel: Channel, url: URL)],
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        // An edited row is the user's own text. It is neither promoted nor re-spelled here, and
        // `replaceLiveSegments` leaves it in place — a correction somebody typed is the one thing in
        // the transcript that no recogniser gets to overrule.
        let unedited = Dictionary(grouping: stored.filter { !$0.edited }, by: \.channel)
        let entries = VocabularyBiasing.entries(for:
            (try? store.vocabularyInEffect(meetingID: meetingID)) ?? [])
        progress(0.1)

        var promoted: [TranscriptSegment] = []
        var reports: [(channel: Channel, report: VocabularyBiasingReport)] = []
        for (index, file) in files.enumerated() {
            // Ascending, because that is what putting the corrections back relies on: a correction
            // is placed by where its span starts, so rows out of order would land a fix in the
            // wrong phrase. The store returns them in order; this does not depend on that.
            let rows = (unedited[file.channel] ?? []).sorted { $0.tStartMs < $1.tStartMs }
            guard !rows.isEmpty else { continue }
            let base = 0.1 + 0.9 * Double(index) / Double(files.count)
            let span = 0.9 / Double(files.count)
            let outcome = await biased(
                rows.map { EngineSegment(startMs: $0.tStartMs, endMs: $0.tEndMs, text: $0.text) },
                against: file.url,
                entries: entries,
                progress: { progress(base + span * min(1, max(0, $0))) }
            )
            if let report = outcome.report { reports.append((file.channel, report)) }
            promoted += outcome.segments.map {
                TranscriptSegment(
                    meetingID: meetingID, channel: file.channel, tStartMs: $0.startMs,
                    tEndMs: $0.endMs, text: $0.text, pass: .final)
            }
            progress(base + span)
        }
        // A channel with rows and no file on disk — purged audio, or a capture that never wrote —
        // is promoted untouched. There is nothing to score its words against, and losing the text
        // would be a far worse trade than leaving its jargon alone.
        for (channel, rows) in unedited where !files.contains(where: { $0.channel == channel }) {
            promoted += rows.map {
                TranscriptSegment(
                    meetingID: meetingID, channel: channel, tStartMs: $0.tStartMs,
                    tEndMs: $0.tEndMs, text: $0.text, pass: .final)
            }
        }
        promoted.sort { ($0.tStartMs, $0.channel.rawValue) < ($1.tStartMs, $1.channel.rawValue) }
        lastVocabularyReport = VocabularyBiasingReport.union(reports.map(\.report))

        try store.replaceLiveSegments(
            meetingID: meetingID, with: promoted, channels: Set(files.map(\.channel)))

        // Only the vocabulary verdict is this path's to write. A capture failure recorded while the
        // meeting was being recorded is still true afterwards — nothing here re-read that channel's
        // audio to find out otherwise.
        for (channel, report) in reports {
            try store.clearTranscriptIssue(meetingID: meetingID, channel: channel, kind: .vocabulary)
            guard let why = report.unavailable else { continue }
            try store.recordTranscriptIssue(TranscriptIssue(
                meetingID: meetingID, channel: channel, kind: .vocabulary, reason: why
            ))
        }
        progress(1)
    }

    /// One channel's segments with the vocabulary applied, and what the pass did.
    ///
    /// Nil report means the pass never ran because there was nothing to apply, which is different
    /// from a pass that ran and could not: the first is silence, the second is a recorded reason.
    private func biased(
        _ segments: [EngineSegment],
        against audio: URL,
        entries: [VocabularyBiasing.Entry],
        progress: @Sendable @escaping (Double) -> Void
    ) async -> (segments: [EngineSegment], report: VocabularyBiasingReport?) {
        guard !entries.isEmpty else { return (segments, nil) }
        // Same specific guarantee as the file path: a WAV whose header was never finalised reads as
        // zero frames, and the spotter would then score the transcript against no audio at all.
        try? WAVRepair.repair(at: audio)
        do {
            let samples = try AudioConverter().resampleAudioFile(audio)
            let outcome = await VocabularyBiasing.shared.apply(
                to: segments, samples: samples, entries: entries, progress: progress)
            return (outcome.segments, outcome.report)
        } catch {
            // The transcript is already written and perfectly readable; what is lost is the jargon
            // correction, which is invisible in the result — so it degrades the way the rest of the
            // invisible degradation does, as a reason in `transcript_issues`.
            var report = VocabularyBiasingReport(terms: entries.map(\.text))
            report.unavailable = "the recording could not be read for the vocabulary pass (\(error))"
            return (segments, report)
        }
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
            // rather than falling back, because the fallback was a local engine — 600 MB fetched on
            // its first `prepare` from a branch documented as impossible, which is the same silent
            // download the `.cloud` arm below was rewritten to stop.
            preconditionFailure("resolvedEngine reached .injected with no injected engine")
        case .cloud(let configured):
            guard configured, let configuration = remoteConfiguration() else {
                // The important half of this branch. Before, an incomplete remote configuration fell
                // through to the local engine, which downloads the model on its first `prepare` —
                // silently fetching what the user chose the cloud to avoid, and producing a local
                // transcript from a setting that says remote.
                throw TranscriptionError.remoteFailed(
                    "the remote endpoint is selected but incomplete: base URL, model and a Keychain "
                        + "key reference are all required")
            }
            resolved = OpenAICompatibleRemoteEngine(configuration: configuration)
        case .local(let transcriber):
            resolved = localEngine(transcriber.variant)
        }
        engine = resolved
        engineWasResolved = true
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
