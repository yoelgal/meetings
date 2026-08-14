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
    public func prepareModels(progress: @Sendable @escaping (Double) -> Void) async throws {
        // The batch model is the larger of the two, and the one a meeting cannot be written up
        // without, so it goes first and takes the bigger share of the bar.
        try await resolvedEngine().prepare(progress: { progress($0 * 0.6) })
        guard !FluidAudioStreamingTranscriber.modelsAreCached() else { return progress(1) }
        try await FluidAudioStreamingTranscriber.prepareModels(progress: { progress(0.6 + $0 * 0.4) })
    }

    /// Cheap, synchronous-ish check used by onboarding and `meetings status`. No download.
    ///
    /// True only when everything a recording needs is present. Reporting ready on the batch model
    /// alone is what let a fresh install finish setup, start its first meeting, and find the live
    /// transcript empty with nothing having warned it would be.
    public func modelsReady() async -> Bool {
        guard FluidAudioStreamingTranscriber.modelsAreCached() else { return false }
        if let engine, !(engine is FluidAudioBatchEngine) { return true }
        if engine == nil, remoteConfiguration() != nil { return true }
        return FluidAudioBatchEngine.modelsAreCached()
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
        if let configuration = remoteConfiguration() {
            resolved = OpenAICompatibleRemoteEngine(configuration: configuration)
        } else {
            resolved = FluidAudioBatchEngine()
        }
        engine = resolved
        return resolved
    }

    /// Nil in every configuration but the one where the user has explicitly asked for a remote batch
    /// engine *and* filled in all of it. Nil means no network call is possible.
    func remoteConfiguration() -> OpenAICompatibleRemoteEngine.Configuration? {
        guard setting(.transcribeBatchEngine) == "remote" else { return nil }
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
