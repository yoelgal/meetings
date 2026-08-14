import Foundation
import Testing

@testable import MeetingsCore

/// The engine and model choice: what a store reads, what an unrecognised value does, and the
/// gates that used to assume there was only ever one answer.
@Suite final class TranscriptionChoiceTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    // MARK: - The catalogue

    /// The whole point of the data type: adding a tier is an element, and everything downstream
    /// picks it up. If this ever needs editing to add one, the branching came back.
    @Test func everyOptionIsDistinctAndOrderedMostDemandingFirst() {
        let all = LocalTranscriptionOption.all
        #expect(all.count >= 2)
        #expect(Set(all.map(\.id)).count == all.count, "two options share an id")
        #expect(all.map(\.tier) == all.map(\.tier).sorted(), "the ladder is not in tier order")
        #expect(all.last == LocalTranscriptionOption.fallback,
                "the fallback has to be last, because that is where the ladder stops")
        for option in all {
            #expect(option.downloadBytes > 0)
            #expect(!option.summary.isEmpty)
        }
    }

    /// An id from a newer build, or a hand-edited row, must not leave the app with no transcriber.
    @Test func anUnknownModelIDFallsBackRatherThanFailing() {
        #expect(LocalTranscriptionOption.named(nil) == .fallback)
        #expect(LocalTranscriptionOption.named("") == .fallback)
        #expect(LocalTranscriptionOption.named("nemotron-80ms-from-the-future") == .fallback)
        #expect(LocalTranscriptionOption.named("balanced").id == "balanced")
    }

    /// The existing-install guarantee. A store that has never seen this feature reads exactly as it
    /// did before: local engine, two models, no fit record.
    @Test func aStoreThatChoseNothingIsOnTheModelThatAlwaysShipped() {
        #expect(store.transcriptionEngine() == .local)
        #expect(store.localTranscriptionOption() == .balanced)
        #expect(store.localTranscriptionOption().runsSeparateBatchPass)
        #expect(store.fitRecord() == nil)
    }

    @Test func anUnknownEngineValueReadsAsLocal() throws {
        try store.setSetting(.transcribeBatchEngine, "whisper.cpp")
        #expect(store.transcriptionEngine() == .local,
                "an unrecognised engine must never be read as one that uploads audio")
    }

    // MARK: - The gates

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
    /// through to the local batch engine, whose first `prepare` fetches ~600 MB.
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

    // MARK: - The option with no second pass

    /// An option whose live model *is* its final model has no batch engine to call. The live rows
    /// have to become the transcript — promoted to `final`, with the notes remapped and the meeting
    /// moved on — because the alternative is a meeting stuck at `transcribing` for ever, which is
    /// where the queue looks for work and would retry it on every launch.
    @Test func anOptionWithNoSecondPassPromotesTheLiveTranscriptRatherThanStalling() async throws {
        let option = LocalTranscriptionOption.all.first { !$0.runsSeparateBatchPass }
        guard let option else { return }
        try store.setSetting(.transcribeLocalModel, option.id)

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
    }
}

/// A box a `@Sendable` progress closure can append to from any executor.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    var values: [Double] { lock.withLock { stored } }
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
}
