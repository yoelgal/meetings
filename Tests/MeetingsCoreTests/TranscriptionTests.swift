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
