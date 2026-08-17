import Foundation
import Testing

@testable import MeetingsCore

/// A stand-in for Parakeet. The real engine needs 600 MB of models and a few seconds of ANE time;
/// what these tests are about is what the service does with whatever the engine returns.
private struct StubEngine: TranscriptionEngine, Sendable {
    struct Failure: Error {}

    let name = "stub"
    let model = "stub"
    /// Keyed by file name, so a test can give mic.wav and system.wav different transcripts.
    var results: [String: [EngineSegment]] = [:]
    var failing: Set<String> = []
    /// What a biasing engine would hand back after a pass, so the service's plumbing can be tested
    /// without 700 MB of models.
    var report: VocabularyBiasingReport?

    func prepare(progress: @Sendable (Double) -> Void) async throws { progress(1) }

    func transcribe(
        _ audio: URL,
        vocabulary: [VocabularyTerm],
        progress: @Sendable (Double) -> Void
    ) async throws -> [EngineSegment] {
        if failing.contains(audio.lastPathComponent) { throw Failure() }
        progress(1)
        return results[audio.lastPathComponent] ?? []
    }

    func vocabularyReport() async -> VocabularyBiasingReport? { report }

    func release() async {}
}

@Suite struct TranscriptionSegmentGroupingTests {
    private func words(_ specs: [(Int, Int, String)]) -> [EngineSegment] {
        specs.map { EngineSegment(startMs: $0.0, endMs: $0.1, text: $0.2) }
    }

    @Test func breaksOnSentenceEndingPunctuation() {
        let grouped = EngineSegment.grouped(words: words([
            (0, 300, "We"), (300, 700, "shipped"), (700, 1_100, "it."),
            (1_200, 1_500, "Next"), (1_500, 1_900, "week?"),
        ]))
        #expect(grouped.map(\.text) == ["We shipped it.", "Next week?"])
        #expect(grouped[0].startMs == 0)
        #expect(grouped[0].endMs == 1_100)
        #expect(grouped[1].startMs == 1_200)
    }

    @Test func breaksOnASilenceGap() {
        let grouped = EngineSegment.grouped(words: words([
            (0, 300, "Morning"), (300, 700, "everyone"),
            (2_000, 2_400, "right"), (2_400, 2_800, "agenda"),
        ]))
        #expect(grouped.map(\.text) == ["Morning everyone", "right agenda"])
    }

    @Test func wrapsAMonologueAtTheWordCap() {
        let monologue = (0..<130).map { (index: Int) -> (Int, Int, String) in
            (index * 400, index * 400 + 350, "word\(index)")
        }
        let grouped = EngineSegment.grouped(words: words(monologue))
        #expect(grouped.count == 3)
        #expect(grouped[0].text.split(separator: " ").count == 60)
        #expect(grouped[2].text.split(separator: " ").count == 10)
    }
}

@Suite final class TranscriptionBatchPassTests {
    let directory: URL
    let audioRoot: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    /// Only existence is checked before the engine runs, and the stub engine never opens the file.
    private func writeAudio(meetingID: String, names: [String]) throws {
        let meetingDirectory = audioRoot.appendingPathComponent(meetingID, isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        for name in names {
            try Data("RIFF".utf8).write(to: meetingDirectory.appendingPathComponent(name))
        }
    }

    private func service(_ engine: TranscriptionEngine) -> TranscriptionService {
        TranscriptionService(store: store, engine: engine, audioRoot: audioRoot)
    }

    /// The same service, but reached through the *local* plan rather than an injected engine.
    ///
    /// The distinction is the whole of the bug below: an injected engine makes `plan()` report
    /// `.injected`, which skips the local branch entirely, so every test above proves the file path
    /// works without proving the local path ever reaches it. `localEngine` stands in for the model
    /// the local branch would build, leaving the plan reading the store.
    private func localService(_ engine: TranscriptionEngine) -> TranscriptionService {
        TranscriptionService(
            store: store, engine: nil, audioRoot: audioRoot, localEngine: { _ in engine })
    }

    /// **Importing audio into a meeting with no live rows produces a transcript.** The regression for
    /// papercut 2662434591.
    ///
    /// One local model means the live text is the final text, so the pass promotes the live rows
    /// instead of re-transcribing — and it did that whether or not there were any live rows to
    /// promote. An import has none: two WAVs land in the meeting's directory and no live session ever
    /// ran. So the pass promoted nothing over nothing, cleared the way to `ready`, and left the user
    /// looking at a finished meeting with an empty transcript and no error anywhere to explain it.
    @Test func importedAudioWithNoLiveRowsIsTranscribedRatherThanPromotedFromNothing() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .transcribing))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])
        #expect(try store.segments(meetingID: meeting.id).isEmpty, "an import starts with no rows")

        let engine = StubEngine(results: [
            "mic.wav": [EngineSegment(startMs: 0, endMs: 1_500, text: "Is the ptychography rig free?")],
            "system.wav": [EngineSegment(startMs: 1_800, endMs: 3_000, text: "Thursday onwards, yes.")],
        ])
        try await localService(engine).runBatchPass(meetingID: meeting.id, progress: { _ in })

        let segments = try store.segments(meetingID: meeting.id)
        #expect(!segments.isEmpty, "an import that reaches ready with no transcript is the bug")
        #expect(segments.map(\.text) == ["Is the ptychography rig free?", "Thursday onwards, yes."])
        #expect(segments.map(\.channel) == [.mic, .system])
        #expect(segments.allSatisfy { $0.pass == .final })
        #expect(try store.meeting(id: meeting.id)?.state == .ready)
    }

    /// The other half of the same branch: a *recorded* meeting has live rows, and those rows are the
    /// transcript. The engine must not be reached at all — running it would be the second pass this
    /// design exists to remove, on a model that would have to be downloaded to run it.
    @Test func aRecordedMeetingPromotesItsLiveRowsWithoutTouchingTheEngine() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav"])
        _ = try store.insertSegment(TestStore.segment(
            meetingID: meeting.id, from: 0, to: 900, text: "rough live text", pass: .live))

        try await localService(StubEngine(failing: ["mic.wav"]))
            .runBatchPass(meetingID: meeting.id, progress: { _ in })

        let segments = try store.segments(meetingID: meeting.id)
        #expect(segments.map(\.text) == ["rough live text"])
        #expect(segments.allSatisfy { $0.pass == .final })
        #expect(try store.meeting(id: meeting.id)?.state == .ready)
        #expect(try store.transcriptIssues(meetingID: meeting.id).isEmpty,
                "the engine was never asked, so its failure cannot be recorded against a channel")
    }

    /// **A channel with audio and no live rows is transcribed, not deleted.**
    ///
    /// One transcriber is built per channel and each `start(channel:)` failure is handled on its
    /// own, so a meeting can stream the mic and not the system audio. The promote branch skipped the
    /// channel with no rows and still handed it to `replaceLiveSegments`, which deleted its unedited
    /// rows and inserted nothing in their place: the meeting reached `ready` holding your own voice
    /// and nobody else's, with nothing in the app, the CLI or an export saying a channel was gone.
    @Test func aChannelWithAudioAndNoLiveRowsIsTranscribedRatherThanDropped() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])
        _ = try store.insertSegment(TestStore.segment(
            meetingID: meeting.id, from: 0, to: 900, text: "rough live mic text", pass: .live))

        // Only the channel that never streamed is handed to the engine; the mic's rows are promoted.
        let engine = StubEngine(results: [
            "system.wav": [EngineSegment(startMs: 1_000, endMs: 2_400, text: "Thursday onwards, yes.")],
        ])
        try await localService(engine).runBatchPass(meetingID: meeting.id, progress: { _ in })

        let segments = try store.segments(meetingID: meeting.id)
        #expect(segments.map(\.channel) == [.mic, .system], "both sides of the call are present")
        #expect(segments.map(\.text) == ["rough live mic text", "Thursday onwards, yes."])
        #expect(segments.allSatisfy { $0.pass == .final })
        #expect(try store.transcriptIssues(meetingID: meeting.id).isEmpty)
        #expect(try store.meeting(id: meeting.id)?.state == .ready)
    }

    /// The other outcome for the same channel: nothing could be read off disk either, so the meeting
    /// still finishes on the strength of the channel that streamed — and says which half is missing.
    /// Reaching `ready` with a channel absent and a recorded reason is honest; reaching it silently
    /// is the bug.
    @Test func aChannelThatCouldNeitherStreamNorBeReadIsRecorded() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])
        _ = try store.insertSegment(TestStore.segment(
            meetingID: meeting.id, from: 0, to: 900, text: "rough live mic text", pass: .live))

        try await localService(StubEngine(failing: ["system.wav"]))
            .runBatchPass(meetingID: meeting.id, progress: { _ in })

        #expect(try store.segments(meetingID: meeting.id).map(\.text) == ["rough live mic text"])
        let issues = try store.transcriptIssues(meetingID: meeting.id)
        #expect(issues.map(\.channel) == [.system])
        #expect(issues[0].sentence.hasPrefix("The system channel could not be transcribed:"))
        #expect(try store.meeting(id: meeting.id)?.state == .ready)
    }

    /// **A channel with rows and no file is not promoted twice.**
    ///
    /// Purged or manually removed audio leaves a channel with transcript rows and no WAV, and its
    /// rows are promoted untouched — there is nothing to score their words against. But the channel
    /// set handed to `replaceLiveSegments` was `Set(files.map(\.channel))`, which is exactly the set
    /// that excludes it: the delete skipped the channel, the insert did not, and every line of it
    /// ended up in the store twice. Only the app window hid that, by filtering on `pass == .final`;
    /// `meetings show`, `meetings transcript`, the markdown export, the bundle and the text sent to a
    /// cloud summariser all read the rows unfiltered.
    @Test func aChannelWithRowsAndNoFileIsNotPromotedTwice() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        // system.wav is gone; its rows are all that is left of that side of the meeting.
        try writeAudio(meetingID: meeting.id, names: ["mic.wav"])
        _ = try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, from: 0, to: 900,
                              text: "mic live text", pass: .live),
            TestStore.segment(meetingID: meeting.id, channel: .system, from: 1_000, to: 2_000,
                              text: "system live text", pass: .live),
        ])

        try await localService(StubEngine()).runBatchPass(meetingID: meeting.id, progress: { _ in })

        let segments = try store.segments(meetingID: meeting.id)
        #expect(segments.count == 2, "the fileless channel's rows were duplicated")
        #expect(segments.map(\.text) == ["mic live text", "system live text"])
        #expect(segments.allSatisfy { $0.pass == .final })
    }

    @Test func tagsEachChannelAndMergesByOffset() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])

        let engine = StubEngine(results: [
            "mic.wav": [
                EngineSegment(startMs: 0, endMs: 1_500, text: "Sofia, can you take the ptychography rig?"),
                EngineSegment(startMs: 4_000, endMs: 5_200, text: "Agreed, Thursday then."),
            ],
            "system.wav": [
                EngineSegment(startMs: 1_800, endMs: 3_600, text: "Yes, Torch0 has it booked until Thursday."),
            ],
        ])
        try await service(engine).runBatchPass(meetingID: meeting.id, progress: { _ in })

        let segments = try store.segments(meetingID: meeting.id)
        #expect(segments.map(\.channel) == [.mic, .system, .mic])
        #expect(segments.map(\.tStartMs) == [0, 1_800, 4_000])
        #expect(segments.allSatisfy { $0.pass == .final })
        #expect(try store.meeting(id: meeting.id)?.state == .ready)
    }

    @Test func oneBadChannelDoesNotCostTheOther() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])

        let engine = StubEngine(
            results: ["mic.wav": [EngineSegment(startMs: 0, endMs: 900, text: "Recording, everyone.")]],
            failing: ["system.wav"]
        )
        try await service(engine).runBatchPass(meetingID: meeting.id, progress: { _ in })

        let segments = try store.segments(meetingID: meeting.id)
        #expect(segments.count == 1)
        #expect(segments[0].channel == .mic)
        #expect(segments[0].text == "Recording, everyone.")
    }

    /// The one that made a half transcript look like a whole one.
    ///
    /// A corrupt `mic.wav` beside a perfectly good `system.wav` used to reach `ready` reporting
    /// success, having *also* deleted the live mic rows — so the rough live text of the user's own
    /// half of the meeting, which they could still read a second earlier, was replaced with nothing
    /// and nothing said so. Now: the failed channel's rows stay, the reason is in the store, and the
    /// good channel's transcript is written as before.
    @Test func aFailedChannelKeepsItsLiveRowsAndSaysWhyItFailed() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])
        let live = try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, from: 0, to: 1_800,
                              text: "is the rig free on thursday", pass: .live),
            TestStore.segment(meetingID: meeting.id, channel: .system, from: 2_000, to: 3_000,
                              text: "rough system text", pass: .live),
        ])

        let engine = StubEngine(
            results: ["system.wav": [EngineSegment(startMs: 2_000, endMs: 3_400, text: "Yes, it is free.")]],
            failing: ["mic.wav"]
        )
        try await service(engine).runBatchPass(meetingID: meeting.id, progress: { _ in })

        let segments = try store.segments(meetingID: meeting.id)
        #expect(segments.map(\.text) == ["is the rig free on thursday", "Yes, it is free."])
        #expect(segments[0].id == live[0].id, "the mic channel's live row is the same row, untouched")
        #expect(segments[0].pass == .live)
        #expect(segments[1].pass == .final, "the readable channel was replaced as usual")

        let issues = try store.transcriptIssues(meetingID: meeting.id)
        #expect(issues.map(\.channel) == [.mic])
        #expect(issues[0].sentence.hasPrefix("The mic channel could not be transcribed:"))
    }

    /// Re-running the pass on a repaired file has to take the warning down again.
    @Test func aRepairedChannelClearsItsRecordedFailure() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])

        try await service(StubEngine(failing: ["mic.wav"]))
            .runBatchPass(meetingID: meeting.id, progress: { _ in })
        #expect(try store.transcriptIssues(meetingID: meeting.id).count == 1)
        #expect(try store.meetingIDsWithTranscriptIssues() == [meeting.id])

        let repaired = StubEngine(results: [
            "mic.wav": [EngineSegment(startMs: 0, endMs: 900, text: "Recovered.")],
        ])
        try await service(repaired).runBatchPass(meetingID: meeting.id, progress: { _ in })

        #expect(try store.transcriptIssues(meetingID: meeting.id).isEmpty)
        #expect(try store.segments(meetingID: meeting.id).map(\.text) == ["Recovered."])
    }

    /// A silent recording is a successful pass, not a failed one — the distinction is whether the
    /// engine ran, never whether it found words.
    @Test func aChannelThatRecognisedNothingIsStillASuccess() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav"])
        try store.insertSegment(TestStore.segment(
            meetingID: meeting.id, from: 0, to: 500, text: "spurious live text", pass: .live))

        try await service(StubEngine()).runBatchPass(meetingID: meeting.id, progress: { _ in })

        #expect(try store.segments(meetingID: meeting.id).isEmpty)
        #expect(try store.transcriptIssues(meetingID: meeting.id).isEmpty)
        #expect(try store.meeting(id: meeting.id)?.state == .ready)
    }

    /// The import path: two WAVs are dropped into the meeting's directory and the batch pass
    /// is called with no live session. Nothing recorded `audio_path`, so the app reported no audio
    /// and the retention sweep — which keys off `audio_path` — could never find the files.
    @Test func theBatchPassRecordsWhereTheAudioIs() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .transcribing))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])
        #expect(try store.meeting(id: meeting.id)?.audioPath == nil)

        try await service(StubEngine()).runBatchPass(meetingID: meeting.id, progress: { _ in })

        let expected = audioRoot.appendingPathComponent(meeting.id, isDirectory: true).path
        #expect(try store.meeting(id: meeting.id)?.audioPath == expected)
    }

    /// Purged audio stays purged. A stray WAV left in the directory is not a reason to tell the user
    /// their audio is back.
    @Test func aPurgedMeetingDoesNotGetItsAudioPathBack() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav"])
        try store.updateMeeting(id: meeting.id) { $0.audioPurgedAt = TestStore.referenceDate }

        try await service(StubEngine()).runBatchPass(meetingID: meeting.id, progress: { _ in })
        #expect(try store.meeting(id: meeting.id)?.audioPath == nil)
    }

    /// Both channels dead is a missing transcript, not an empty one: the live rows have to survive so
    /// there is still something to read.
    @Test func everyChannelFailingLeavesTheLiveTranscriptAlone() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])
        _ = try store.insertSegment(TestStore.segment(
            meetingID: meeting.id, from: 0, to: 800, text: "Rough live text", pass: .live
        ))

        let engine = StubEngine(failing: ["mic.wav", "system.wav"])
        await #expect(throws: StubEngine.Failure.self) {
            try await service(engine).runBatchPass(meetingID: meeting.id, progress: { _ in })
        }
        #expect(try store.segments(meetingID: meeting.id).count == 1)
        #expect(try store.meeting(id: meeting.id)?.state == .transcribing)
    }

    @Test func aMeetingWithNoAudioReportsIt() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        await #expect(throws: TranscriptionError.self) {
            try await service(StubEngine()).runBatchPass(meetingID: meeting.id, progress: { _ in })
        }
    }

    @Test func notesEndUpAnchoredToFinalSegments() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav"])
        let live = try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, from: 0, to: 2_000, text: "rough live text", pass: .live),
            TestStore.segment(meetingID: meeting.id, from: 2_000, to: 4_000, text: "more rough text", pass: .live),
        ])
        let note = try store.addNote(meetingID: meeting.id, tOffsetMs: 2_500, text: "Chase the rig booking")
        #expect(note.anchorSegmentID == live[1].id)

        let engine = StubEngine(results: ["mic.wav": [
            EngineSegment(startMs: 0, endMs: 2_100, text: "Rough live text."),
            EngineSegment(startMs: 2_200, endMs: 4_100, text: "More rough text."),
        ]])
        try await service(engine).runBatchPass(meetingID: meeting.id, progress: { _ in })

        let segments = try store.segments(meetingID: meeting.id)
        let anchor = try #require(try store.notes(meetingID: meeting.id).first?.anchorSegmentID)
        let anchored = try #require(segments.first { $0.id == anchor })
        #expect(anchored.pass == .final)
        #expect(anchored.text == "More rough text.")
        #expect(!live.compactMap(\.id).contains(anchor))
    }

    /// The vocabulary is invisible by construction — it rewrites words inside a transcript
    /// nobody has read yet. What the pass did has to come back out of it, or the only way to know
    /// whether the feature ran at all is to squint at the text.
    @Test func whatTheVocabularyPassDidComesBackOutOfIt() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])
        _ = try store.addVocabularyTerm(VocabularyTerm(term: "ptychography"))

        var engine = StubEngine()
        engine.report = VocabularyBiasingReport(
            terms: ["ptychography"], detected: ["ptychography"], applied: ["ptychography"]
        )
        let service = service(engine)
        try await service.runBatchPass(meetingID: meeting.id, progress: { _ in })

        let report = try #require(await service.lastVocabularyReport)
        #expect(report.applied == ["ptychography"])
        #expect(report.sentence == "Applied ptychography from 1 vocabulary term(s).")
    }

    /// …and a pass that could not bias has to reach further than a property on a live actor. The
    /// report was computed and dropped on the floor: nothing outside MeetingsCore read it, so a
    /// meeting whose jargon stayed mangled looked exactly like one whose jargon was fixed — and the
    /// load failure is memoised for the process, so every later meeting was silent too.
    ///
    /// It rides the table the rest of the invisible degradation rides, which is what gets it into
    /// `show`, `list`, `transcript`, the bundle and the app without any of them being told.
    @Test func aVocabularyPassThatCouldNotRunIsRecordedWhereTheUserWillSeeIt() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])
        _ = try store.addVocabularyTerm(VocabularyTerm(term: "ptychography"))

        var engine = StubEngine()
        engine.report = VocabularyBiasingReport(
            terms: ["ptychography"],
            unavailable: "the vocabulary model could not be loaded (offline)"
        )
        try await service(engine).runBatchPass(meetingID: meeting.id, progress: { _ in })

        let issues = try store.transcriptIssues(meetingID: meeting.id)
        #expect(issues.map(\.kind) == [.vocabulary, .vocabulary], "one per channel that ran")
        #expect(issues.allSatisfy { $0.reason == "the vocabulary model could not be loaded (offline)" })
        #expect(issues[0].sentence
            == "Custom vocabulary did not apply to the mic channel: "
            + "the vocabulary model could not be loaded (offline)")
        #expect(try store.meetingIDsWithTranscriptIssues().contains(meeting.id))
        #expect(try store.meeting(id: meeting.id)?.state == .ready, "the transcript is still fine")
    }

    /// The other half: a re-run that finally reaches the model has to take last week's warning down
    /// with it, exactly like the transcriber's own.
    @Test func aLaterPassThatBiasesCleanlyClearsTheVocabularyWarning() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])

        var offline = StubEngine()
        offline.report = VocabularyBiasingReport(terms: ["Torch0"], unavailable: "no network")
        try await service(offline).runBatchPass(meetingID: meeting.id, progress: { _ in })
        #expect(try store.transcriptIssues(meetingID: meeting.id).count == 2)

        var online = StubEngine()
        online.report = VocabularyBiasingReport(terms: ["Torch0"], applied: ["Torch0"])
        try await service(online).runBatchPass(meetingID: meeting.id, progress: { _ in })
        #expect(try store.transcriptIssues(meetingID: meeting.id).isEmpty)
    }

    /// A capture failure is not the vocabulary pass's to clear, and never was the transcriber's.
    @Test func clearingTheVocabularyWarningLeavesACaptureFailureStanding() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])
        try store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meeting.id, channel: .mic, kind: .capture, reason: "the microphone was muted"
        ))

        var engine = StubEngine()
        engine.report = VocabularyBiasingReport(terms: ["Torch0"], applied: ["Torch0"])
        try await service(engine).runBatchPass(meetingID: meeting.id, progress: { _ in })

        #expect(try store.transcriptIssues(meetingID: meeting.id).map(\.kind) == [.capture])
    }

    @Test func progressRunsFromZeroToOne() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try writeAudio(meetingID: meeting.id, names: ["mic.wav", "system.wav"])

        let reported = Reported()
        try await service(StubEngine()).runBatchPass(
            meetingID: meeting.id,
            progress: { reported.append($0) }
        )
        let values = reported.values
        #expect(values.last == 1)
        #expect(values == values.sorted())
    }

    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        var values: [Double] { lock.withLock { storage } }
        func append(_ value: Double) { lock.withLock { storage.append(value) } }
    }
}

@Suite final class TranscriptionQueueTests {
    let directory: URL
    let audioRoot: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    private func service(_ engine: TranscriptionEngine = StubEngine()) -> TranscriptionService {
        TranscriptionService(store: store, engine: engine, audioRoot: audioRoot)
    }

    @Test func theStoreIsTheQueueAndItComesOutOldestFirst() async throws {
        let old = try store.createMeeting(TestStore.meeting(
            title: "Airbus review", state: .transcribing,
            startedAt: TestStore.referenceDate.addingTimeInterval(-7_200)
        ))
        let new = try store.createMeeting(TestStore.meeting(
            title: "Torch0 weekly", state: .transcribing, startedAt: TestStore.referenceDate
        ))
        _ = try store.createMeeting(TestStore.meeting(title: "Already done", state: .ready))

        #expect(await service().pendingMeetingIDs() == [old.id, new.id])
    }

    @Test func enqueueMarksTheMeetingSoAQuitDoesNotLoseIt() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        let service = service()
        await service.enqueue(meetingID: meeting.id)
        // Read the row, not the actor: surviving a quit is the whole point.
        #expect(try store.meeting(id: meeting.id)?.state == .transcribing)
        await service.waitForQueue()
    }

    /// A meeting whose audio is gone must not spin the queue, and must not be quietly marked ready.
    @Test func aFailedPassStaysPendingAndDrainsTheQueue() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .transcribing))
        let service = service()
        await service.resumePendingOnLaunch()
        await service.waitForQueue()

        #expect(await service.queueDepth == 0)
        #expect(try store.meeting(id: meeting.id)?.state == .transcribing)
        // Second launch would try again; this session does not.
        await service.resumePendingOnLaunch()
        #expect(await service.queueDepth == 0)
    }
}

/// One scripted HTTP answer, so the remote engine's own failure handling can be driven without a
/// network. `URLProtocol` rather than a transport closure because the engine takes a `URLSession` —
/// the request it builds, and everything it does with the response, is what is under test.
private final class StubHTTP: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTP.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url, let response = HTTPURLResponse(
            url: url, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil
        ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite final class RemoteTranscriptionEngineTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    @Test func theRemoteEngineIsUnreachableInTheDefaultConfiguration() async throws {
        let service = TranscriptionService(store: store)
        #expect(await service.remoteConfiguration() == nil)
    }

    /// Every field set but the Keychain entry missing still resolves to nothing — a half-configured
    /// remote engine must never fire a request with an empty Authorization header.
    @Test func remoteStaysOffWithoutAKeyInTheKeychain() async throws {
        try store.setSetting(.transcribeBatchEngine, "remote")
        try store.setSetting(.transcribeRemoteBaseURL, "https://api.example.com/v1")
        try store.setSetting(.transcribeRemoteModel, "whisper-1")
        try store.setSetting(.transcribeRemoteKeyRef, "meetings-remote-transcription-test-absent")

        let service = TranscriptionService(store: store)
        #expect(await service.remoteConfiguration() == nil)
        #expect(OpenAICompatibleRemoteEngine.Configuration.resolve(
            baseURL: "https://api.example.com/v1",
            model: "whisper-1",
            keyRef: "meetings-remote-transcription-test-absent"
        ) == nil)
    }

    @Test func verboseJSONBecomesTimedSegments() throws {
        let json = """
        {"text":"Full text","duration":6.2,"segments":[
          {"start":0.0,"end":2.5,"text":" Sofia is on the ptychography rig."},
          {"start":2.5,"end":6.2,"text":" Torch0 has it until Thursday."}]}
        """
        let decoded = try JSONDecoder().decode(
            OpenAICompatibleRemoteEngine.VerboseTranscription.self, from: Data(json.utf8)
        )
        let segments = decoded.engineSegments()
        #expect(segments.map(\.startMs) == [0, 2_500])
        #expect(segments.map(\.endMs) == [2_500, 6_200])
        #expect(segments[0].text == "Sofia is on the ptychography rig.")
    }

    @Test func aServerThatIgnoresVerboseJSONStillYieldsATranscript() throws {
        let decoded = try JSONDecoder().decode(
            OpenAICompatibleRemoteEngine.VerboseTranscription.self,
            from: Data(#"{"text":"Whole meeting in one blob."}"#.utf8)
        )
        #expect(decoded.engineSegments() == [
            EngineSegment(startMs: 0, endMs: 0, text: "Whole meeting in one blob.")
        ])
    }

    /// A rejected key must not survive the failure it caused.
    ///
    /// The path this closes is not a screenshot: `runBatchPass` writes `String(describing:)` of
    /// this error into `transcript_issues.reason`, which lands in the world-readable store and is
    /// carried into the `issues.json` of every exported bundle. OpenAI's 401 body quotes the key
    /// straight back, so a provider echo plus an export is a key handed to a colleague.
    @Test func aProviderThatQuotesTheKeyBackNeverGetsItIntoTheError() async throws {
        let key = "sk-meetings-0123456789abcdefghij"
        StubHTTP.status = 401
        StubHTTP.body = Data(#"{"error":{"message":"Incorrect API key provided: \#(key)"}}"#.utf8)
        let audio = directory.appendingPathComponent("mic.wav")
        try Data("RIFFDATA".utf8).write(to: audio)

        let engine = OpenAICompatibleRemoteEngine(
            configuration: OpenAICompatibleRemoteEngine.Configuration(
                baseURL: try #require(URL(string: "https://api.example.com/v1")),
                model: "whisper-1",
                apiKey: key
            ),
            session: StubHTTP.session()
        )

        do {
            _ = try await engine.transcribe(audio, vocabulary: [], progress: { _ in })
            Issue.record("a 401 has to fail the pass rather than return an empty transcript")
        } catch {
            let written = String(describing: error)
            #expect(!written.contains(key), """
                The provider's 401 body reached the error verbatim. This string is written to \
                `transcript_issues.reason` and exported in `issues.json`.
                """)
            #expect(written.contains("[redacted]"), "and the echo is visibly removed, not silently dropped")
            #expect(written.contains("401"), "the status the user has to act on still has to be readable")
        }
    }

    @Test func multipartBodyCarriesTheModelAndTheFile() throws {
        let body = OpenAICompatibleRemoteEngine.multipartBody(
            boundary: "BOUND",
            fields: ["model": "whisper-1", "response_format": "verbose_json"],
            fileField: "file",
            fileName: "mic.wav",
            fileData: Data("RIFFDATA".utf8)
        )
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        #expect(text.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        #expect(text.contains("filename=\"mic.wav\""))
        #expect(text.contains("RIFFDATA"))
        #expect(text.hasSuffix("--BOUND--\r\n"))
    }
}

/// A ``StreamingTranscriber`` with no model behind it, so the file engine's driving loop can be
/// exercised for real. It counts what it was fed and how often it was finished, because "was
/// `finish()` reached" is the observable that says the loaded checkpoint was released.
///
/// Same shape as `StreamingRecordingTests.Fake`, one actor with a nonisolated stream, so the two
/// halves of the streaming model — live and over-a-file — are stubbed the same way.
private actor ScriptedTranscriber: StreamingTranscriber {
    struct Failure: Error {}

    nonisolated let name = "scripted"
    nonisolated let segments: AsyncStream<EngineSegment>
    private nonisolated let continuation: AsyncStream<EngineSegment>.Continuation
    /// Which fed chunk throws, counting from one. Nil feeds the whole buffer cleanly.
    private let throwOnChunk: Int?
    private var fed = 0
    private var finished = 0

    init(throwOnChunk: Int? = nil) {
        self.throwOnChunk = throwOnChunk
        (segments, continuation) = AsyncStream.makeStream()
    }

    var chunksFed: Int { fed }
    var finishCount: Int { finished }

    func start(channel: Channel) async throws {}

    func feed(_ samples: [Float], atMs: Int) async throws {
        fed += 1
        if fed == throwOnChunk { throw Failure() }
        continuation.yield(EngineSegment(startMs: atMs, endMs: atMs + 80, text: "chunk\(fed)"))
    }

    /// Yields a tail before it closes the stream, exactly as the real one flushes its segmenter
    /// inside `finish()`. That is what makes the collector's ordering testable: a collector awaited
    /// before `finish()` would never see this row.
    func finish() async {
        finished += 1
        continuation.yield(EngineSegment(startMs: 9_000, endMs: 9_400, text: "tail"))
        continuation.finish()
    }
}

@Suite struct StreamingFileEngineRecogniseTests {
    /// Three 1280-sample chunks, which is 240 ms at 16 kHz — enough to have a middle chunk to throw
    /// on and a third the loop must not reach.
    private let samples = [Float](repeating: 0.01, count: 3_840)

    /// **A feed that throws releases the collector and the model.**
    ///
    /// `feed` throws — it propagates from the backend — and the failure path used to walk straight
    /// out of the function. Nothing but `finish()` finishes the segment stream, so the collector's
    /// `for await` never ended: the task stayed suspended holding the transcriber, the transcriber
    /// held the continuation, and `backend.cleanup()` — the call that unloads ~600 MB of Core ML —
    /// was never reached. `runBatchPass` catches the per-channel error and carries on, so a queue
    /// draining a backlog of unreadable files leaked one suspended task and one loaded model per
    /// channel with nothing logged.
    @Test func aFeedThatThrowsStillFinishesTheTranscriber() async throws {
        let transcriber = ScriptedTranscriber(throwOnChunk: 2)

        await #expect(throws: ScriptedTranscriber.Failure.self) {
            _ = try await StreamingFileEngine.recognise(
                samples, using: transcriber, progress: { _ in })
        }

        #expect(await transcriber.finishCount == 1,
                "the model stays loaded for the life of the process unless finish() runs")
        #expect(await transcriber.chunksFed == 2, "and the loop stopped at the chunk that threw")
    }

    /// The success ordering is unchanged, which is the part the fix must not have moved: the
    /// collector starts after `start()` and before the first feed, and is awaited after `finish()` —
    /// so segments yielded during feeding *and* the tail flushed inside `finish()` both arrive.
    @Test func aCleanRunCollectsEveryChunkAndFinishesOnce() async throws {
        let transcriber = ScriptedTranscriber()

        let collected = try await StreamingFileEngine.recognise(
            samples, using: transcriber, progress: { _ in })

        #expect(collected.map(\.text) == ["chunk1", "chunk2", "chunk3", "tail"])
        #expect(await transcriber.finishCount == 1)
    }
}
