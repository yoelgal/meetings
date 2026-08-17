import FluidAudio
import Foundation
import Testing

@testable import MeetingsCore

/// The engine choice and the model that is *not* a choice: what a store reads, what an unrecognised
/// value does, and the gates that used to assume there was only ever one answer.
@Suite final class TranscriptionChoiceTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    // MARK: - The transcriber

    /// The whole point of collapsing the catalogue: the model is derived from the system's primary
    /// language, so there is nothing to pick, nothing to store, and nothing to get out of step.
    ///
    /// The *primary* language, not "English appears somewhere in the list": macOS puts English second
    /// on a great many non-English installs, and a French speaker whose second language is English
    /// wants their French meetings transcribed rather than heard as English-shaped nonsense.
    @Test func theTranscriberIsResolvedFromThePrimarySystemLanguage() {
        #expect(LocalTranscriber.resolved(preferredLanguages: ["en-GB"]) == .english)
        #expect(LocalTranscriber.resolved(preferredLanguages: ["fr-FR"]) == .multilingual)
        #expect(LocalTranscriber.resolved(preferredLanguages: ["fr-FR", "en-GB"]) == .multilingual,
                "English second is a French install, and it must not be read as an English one")
        #expect(LocalTranscriber.resolved(preferredLanguages: ["en"]) == .english)
        // Nothing to go on, and a malformed tag, both resolve to something that transcribes: the
        // multilingual model handles English too, so it is the safe end of the guess.
        #expect(LocalTranscriber.resolved(preferredLanguages: []) == .english)
        #expect(LocalTranscriber.resolved(preferredLanguages: ["zz"]) == .multilingual)
    }

    /// Two models, and they have to actually differ — an English-only pick that loaded the
    /// multilingual checkpoint would be a resolution that does nothing.
    @Test func theTwoTranscribersAreDistinctAndBothHaveASize() {
        #expect(LocalTranscriber.english.variant != LocalTranscriber.multilingual.variant)
        #expect(LocalTranscriber.english != LocalTranscriber.multilingual)
        for transcriber in [LocalTranscriber.english, .multilingual] {
            #expect(transcriber.downloadBytes > 0)
            #expect(!transcriber.languages.isEmpty)
        }
    }

    /// One string for the size, so the wizard, Settings and `meetings status` cannot disagree about
    /// the same download — and rounded, because the reader is deciding whether to start it, not
    /// auditing it.
    @Test func theDownloadSizeReadsAsOneRoundedSentence() {
        #expect(LocalTranscriber.english.downloadSizeText == "About 640 MB")
        #expect(LocalTranscriber.multilingual.downloadSizeText == "About 220 MB")
    }

    /// The existing-install guarantee. A store that has never seen this feature still reads as local,
    /// and there is no longer a model row for a stale value to sit in.
    @Test func aStoreThatChoseNothingRunsLocallyAndStoresNoModel() throws {
        #expect(store.transcriptionEngine() == .local)
        #expect(SettingKey.defaults[SettingKey("transcribe.localModel")] == nil)
        #expect(!SettingKey.known.contains(SettingKey("transcribe.localModel")))
        #expect(!SettingKey.known.contains(SettingKey("transcribe.fit.record")))
        // An orphan row left by an older build is inert rather than migrated: the key is unknown, so
        // nothing reads it and no schema change was needed to leave it there.
        try store.setSetting(SettingKey("transcribe.localModel"), "accurate-en")
        #expect(store.transcriptionEngine() == .local)
    }

    @Test func anUnknownEngineValueReadsAsLocal() throws {
        try store.setSetting(.transcribeBatchEngine, "whisper.cpp")
        #expect(store.transcriptionEngine() == .local,
                "an unrecognised engine must never be read as one that uploads audio")
    }

    // MARK: - The gates

    /// **A half-downloaded model is not a downloaded model.**
    ///
    /// Three of the four entries the readiness check requires are `.mlmodelc` *directories*, and
    /// FluidAudio's `ModelHub` writes their constituent files straight into the final path — so the
    /// first file to land made the directory exist and the check said yes. A cancelled download is
    /// exactly that shape, and what followed was onboarding completing over a model that was not
    /// there, and the first press of record either failing or re-fetching it right then.
    ///
    /// `coremldata.bin` is FluidAudio's own completeness marker — `ModelCache
    /// .validateCompiledModelLayout` refuses to load a compiled model without it.
    @Test func aModelDirectoryWithNoCoreMLDataInItIsNotDownloaded() throws {
        let directory = self.directory.appendingPathComponent("models", isDirectory: true)
        let entries = ["streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc"]
        for entry in entries {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(entry), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("vocab.json"))
        // Every required entry exists, which is all the old check asked. `weights/` is what an
        // interrupted download of one of them actually leaves behind.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("decoder.mlmodelc/weights", isDirectory: true),
            withIntermediateDirectories: true)

        #expect(!FluidAudioStreamingTranscriber.modelsAreCached(.parakeetEou320ms, in: directory),
                "a cancelled download leaves the directories behind and none of them loadable")

        for entry in entries {
            try Data(repeating: 0, count: 16)
                .write(to: directory.appendingPathComponent(entry).appendingPathComponent("coremldata.bin"))
        }
        #expect(FluidAudioStreamingTranscriber.modelsAreCached(.parakeetEou320ms, in: directory),
                "and a complete one still reads as ready — the check must not simply always fail")
    }

    /// One model serves the live pane and the file pass, so one answer serves both questions. Two
    /// answers is what let a store with the live model and not the batch one report ready and then
    /// produce an empty transcript.
    @Test func theFileEngineAndTheLivePaneAgreeAboutWhatIsDownloaded() {
        for variant in [LocalTranscriber.english.variant, LocalTranscriber.multilingual.variant] {
            #expect(StreamingFileEngine.modelsAreCached(variant)
                == FluidAudioStreamingTranscriber.modelsAreCached(variant))
        }
    }

    /// The gate that would have blocked the cloud user forever. `modelsReady` used to be a check
    /// for files on disk, and on the remote path there are none by design.
    @Test func aConfiguredCloudEngineIsReadyWithNoModelsOnDisk() async throws {
        try store.setSetting(.transcribeBatchEngine, "remote")
        try store.setSetting(.transcribeRemoteBaseURL, "https://api.openai.com/v1")
        try store.setSetting(.transcribeRemoteModel, "whisper-1")
        try store.setSetting(.transcribeRemoteKeyRef, "unit-test-transcribe")
        MeetingsKeychain.setSecret("sk-unit-test", account: "unit-test-transcribe")
        defer { MeetingsKeychain.setSecret(nil, account: "unit-test-transcribe") }

        let service = TranscriptionService(store: store, engine: nil, audioRoot: directory)
        #expect(await service.modelsReady(), "a fully configured endpoint is ready with nothing downloaded")
        let summary = await service.engineSummary()
        #expect(summary.contains("api.openai.com"))
        #expect(summary.contains("uploaded"), "status has to say the audio leaves the machine")
    }

    /// Selected but incomplete is a setup problem, and it must read as one rather than as missing
    /// models — and above all it must not silently become the local engine.
    @Test func anIncompleteCloudEngineIsNotReadyAndNamesWhatIsMissing() async throws {
        try store.setSetting(.transcribeBatchEngine, "remote")
        try store.setSetting(.transcribeRemoteBaseURL, "https://api.openai.com/v1")

        let service = TranscriptionService(store: store, engine: nil, audioRoot: directory)
        #expect(await service.modelsReady() == false)
        let summary = await service.engineSummary()
        #expect(summary.contains("not fully configured"))
        #expect(!summary.contains("this Mac"), "an unconfigured endpoint must not report as local")
    }

    /// The download the cloud path must never start. Before this, an incomplete remote setting fell
    /// through to the local engine, whose first `prepare` fetches the whole model.
    @Test func anIncompleteCloudEngineRefusesToRunRatherThanDownloadingLocally() async throws {
        try store.setSetting(.transcribeBatchEngine, "remote")
        let service = TranscriptionService(store: store, engine: nil, audioRoot: directory)

        // A meeting with no audio: the pass has to fail on the *engine*, not get as far as the files.
        let meeting = try store.createMeeting(Meeting(title: "cloud", state: .recording))
        await #expect(throws: (any Error).self) {
            try await service.runBatchPass(meetingID: meeting.id, progress: { _ in })
        }
        // Nothing was prepared, so nothing was fetched. Asserted through the public flag rather than
        // the filesystem, because the filesystem here is the developer's real model cache.
        #expect(await service.isPreparingModels == false)
    }

    /// Preparing on the cloud path completes without touching the network or the disk. This is the
    /// literal requirement "onboarding must complete with zero models on disk".
    @Test func preparingOnTheCloudPathDownloadsNothingAndFinishes() async throws {
        try store.setSetting(.transcribeBatchEngine, "remote")
        let service = TranscriptionService(store: store, engine: nil, audioRoot: directory)

        let seen = ProgressLog()
        try await service.prepareModels { seen.append($0) }
        #expect(seen.values.last == 1, "the bar has to reach the end, or the wizard waits forever")
    }

    // MARK: - One pass

    /// The live model *is* the final model, so a streamed meeting already has its transcript. The
    /// live rows have to become it — promoted to `final`, with the notes remapped and the meeting
    /// moved on — because the alternative is a meeting stuck at `transcribing` for ever, which is
    /// where the queue looks for work and would retry it on every launch.
    @Test func aStreamedMeetingPromotesItsLiveTranscriptRatherThanStalling() async throws {
        let meeting = try store.createMeeting(Meeting(title: "one model", state: .recording))
        // Two channels of audio on disk, because which file a segment came from is the whole of the
        // app's speaker attribution and the pass keys off the files that exist.
        let audio = directory.appendingPathComponent(meeting.id, isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        for name in ["mic.wav", "system.wav"] {
            try TranscriptionVerify.silentWAV(seconds: 1)
                .write(to: audio.appendingPathComponent(name))
        }
        _ = try store.insertSegments([
            TranscriptSegment(
                meetingID: meeting.id, channel: .mic, tStartMs: 0, tEndMs: 900,
                text: "the rig is free on Thursday", pass: .live),
            TranscriptSegment(
                meetingID: meeting.id, channel: .system, tStartMs: 1_000, tEndMs: 1_900,
                text: "Torch0 has it until then", pass: .live),
        ])

        let service = TranscriptionService(store: store, engine: nil, audioRoot: directory)
        let seen = ProgressLog()
        try await service.runBatchPass(meetingID: meeting.id) { seen.append($0) }

        let after = try store.segments(meetingID: meeting.id)
        #expect(after.count == 2, "no speech may be lost promoting the live rows")
        #expect(after.allSatisfy { $0.pass == .final },
                "a row left at `live` is dropped by every consumer that filters on pass")
        #expect(Set(after.map(\.text)) == [
            "the rig is free on Thursday", "Torch0 has it until then",
        ])
        #expect(try store.meeting(id: meeting.id)?.state == .ready,
                "a meeting left at transcribing is retried on every launch, for ever")
        #expect(seen.values.last == 1)
        // No vocabulary terms in this store, so the biasing pass never ran and never reported.
        #expect(await service.lastVocabularyReport == nil)
    }

    /// A meeting with no live rows at all is an *import*, and it must not be "promoted" from nothing.
    ///
    /// This is the shipped bug from the other side: with one pass, the promote branch ran whether or
    /// not there was anything to promote, so an import reached `ready` with an empty transcript and no
    /// error anywhere. The engine cannot be reached here — these are two bytes of text, not a WAV —
    /// so what is asserted is that it was *reached for*: the pass tries to transcribe rather than
    /// quietly succeeding. See `TranscriptionBatchPassTests` for the full-transcript version.
    @Test func anImportWithNoLiveRowsIsNotPromotedFromNothing() async throws {
        let meeting = try store.createMeeting(Meeting(title: "import", state: .transcribing))
        let audio = directory.appendingPathComponent(meeting.id, isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: audio.appendingPathComponent("mic.wav"))

        // A local engine that refuses, standing in for 600 MB of models. Reaching it at all is the
        // point: the old code never did.
        let service = TranscriptionService(
            store: store, engine: nil, audioRoot: directory,
            localEngine: { _ in RefusingEngine() })
        await #expect(throws: RefusingEngine.Refusal.self) {
            try await service.runBatchPass(meetingID: meeting.id, progress: { _ in })
        }
        #expect(try store.meeting(id: meeting.id)?.state == .transcribing,
                "an import that could not be transcribed stays in the queue rather than reading ready")
        #expect(try store.segments(meetingID: meeting.id).isEmpty)
    }
}

/// Fails on `prepare`, so a test can prove the local branch reached for an engine without any model
/// existing anywhere.
private struct RefusingEngine: TranscriptionEngine {
    struct Refusal: Error {}
    let name = "refusing"
    let model = "refusing"
    func prepare(progress: @Sendable (Double) -> Void) async throws { throw Refusal() }
    func transcribe(
        _ audio: URL, vocabulary: [VocabularyTerm], progress: @Sendable (Double) -> Void
    ) async throws -> [EngineSegment] { throw Refusal() }
    func vocabularyReport() async -> VocabularyBiasingReport? { nil }
    func release() async {}
}

/// A box a `@Sendable` progress closure can append to from any executor.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    var values: [Double] { lock.withLock { stored } }
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
}
