import Foundation
import Testing

@testable import MeetingsCore

/// What the live pass owes the store, proved without a microphone or an 80 MB model: the channel it
/// came from, `pass = .live`, the real offsets, and — the one that matters most — that a transcriber
/// which cannot start leaves the recording alone.
@MainActor
struct StreamingRecordingTests {
    /// Emits one segment per fed buffer, so the test controls exactly what arrives and when.
    actor Fake: StreamingTranscriber {
        nonisolated let name = "fake-streaming"
        nonisolated let segments: AsyncStream<EngineSegment>
        private nonisolated let continuation: AsyncStream<EngineSegment>.Continuation
        private let failure: Error?
        private var fedOffsets: [Int] = []
        private var started = false

        init(failure: Error? = nil) {
            self.failure = failure
            (segments, continuation) = AsyncStream.makeStream()
        }

        var offsets: [Int] { fedOffsets }

        func start(channel: Channel) async throws {
            if let failure { throw failure }
            started = true
        }

        func feed(_ samples: [Float], atMs: Int) async throws {
            fedOffsets.append(atMs)
            continuation.yield(
                EngineSegment(startMs: atMs, endMs: atMs + 400, text: "buffer at \(atMs) ms"))
        }

        /// The tail only exists if the session ever started — same as the real one, where a model
        /// that never loaded has no accumulated audio to flush.
        func finish() async {
            if started {
                continuation.yield(EngineSegment(startMs: 9_000, endMs: 9_400, text: "tail"))
            }
            continuation.finish()
        }
    }

    private func fixture() throws -> (URL, MeetingStore, RecordingController, String) {
        let directory = try TestStore.makeDirectory()
        let store = try TestStore.open(directory)
        let meeting = try store.createMeeting(TestStore.meeting(title: "Torch0 weekly", state: .recording))
        let controller = RecordingController(
            store: store, transcription: TranscriptionService(store: store))
        return (directory, store, controller, meeting.id)
    }

    @Test func liveSegmentsLandInTheStoreWithTheirChannelAndOffsets() async throws {
        let (directory, store, controller, meetingID) = try fixture()
        defer { TestStore.remove(directory) }

        let fake = Fake()
        controller.makeLiveTranscriber = { fake }
        var tap: (([Float], Int) -> Void)?
        controller.attachLive(.system, meetingID: meetingID) { tap = $0 }

        tap?([0.1, 0.2], 320)
        tap?([0.3, 0.4], 640)
        await controller.stopLiveTranscription()

        #expect(await fake.offsets == [320, 640])
        let rows = try store.segments(meetingID: meetingID)
        // The two buffers are back to back, so they are one phrase; the tail is 8 seconds later and
        // is its own row. See `liveTextArrivesInPhrasesNotWordFragments` for why.
        #expect(rows.map(\.text) == ["buffer at 320 ms buffer at 640 ms", "tail"])
        #expect(rows.allSatisfy { $0.pass == .live })
        #expect(rows.allSatisfy { $0.channel == .system })
        #expect(rows.first?.tStartMs == 320)
        #expect(controller.liveSegments.compactMap(\.id) == rows.compactMap(\.id))
        #expect(controller.liveTranscriptionUnavailable == nil)
    }

    /// The whole point of the degrade: no model, no live transcript, and nothing else disturbed.
    @Test func aMissingModelLeavesAReasonAndNoSegments() async throws {
        let (directory, store, controller, meetingID) = try fixture()
        defer { TestStore.remove(directory) }

        let fake = Fake(failure: StreamingTranscriptionError.modelsNotDownloaded("/no/such/model"))
        controller.makeLiveTranscriber = { fake }
        var tap: (([Float], Int) -> Void)?
        controller.attachLive(.mic, meetingID: meetingID) { tap = $0 }

        tap?([0.1, 0.2], 320)
        await controller.stopLiveTranscription()

        #expect(try store.segments(meetingID: meetingID).isEmpty)
        #expect(controller.liveSegments.isEmpty)
        let reason = try #require(controller.liveTranscriptionUnavailable)
        #expect(reason.contains("/no/such/model"))
    }

    /// Live text used to reach the window as "sophia can you" / "confirm" / "the" / "thai" —
    /// timestamps are 80 ms token onsets, so the segmenter's silence rule fired mid-phrase over and
    /// over. It cannot simply wait longer: the recogniser is 310–630 ms behind the audio by
    /// construction, so every extra millisecond of silence waited for is a millisecond of latency,
    /// and under a second in total is the bar. So the words still arrive the instant they are
    /// known and the phrase is assembled in the row: a burst that continues the last one extends it.
    @Test func liveTextArrivesInPhrasesNotWordFragments() async throws {
        let (directory, store, controller, meetingID) = try fixture()
        defer { TestStore.remove(directory) }

        let fake = Fake()
        controller.makeLiveTranscriber = { fake }
        var tap: (([Float], Int) -> Void)?
        controller.attachLive(.mic, meetingID: meetingID) { tap = $0 }

        // Six bursts 400 ms apart — the shape the real recogniser produces mid-sentence — then a
        // three-second pause, then more speech.
        for offset in stride(from: 0, to: 2_400, by: 400) { tap?([0.1], offset) }
        tap?([0.1], 5_400)
        await controller.stopLiveTranscription()

        let rows = try store.segments(meetingID: meetingID)
        #expect(rows.count == 3, "one phrase, one phrase after the pause, and the tail")
        #expect(rows[0].text.split(separator: " ").filter { $0 == "buffer" }.count == 6)
        #expect(rows[0].tStartMs == 0)
        #expect(rows[0].tEndMs == 2_400, "the row's span grows with the phrase")
        #expect(rows[1].text == "buffer at 5400 ms")
        #expect(controller.liveSegments.map(\.text) == rows.map(\.text))
    }

    /// The merge rule, without the plumbing. A full stop ends a phrase however close the next words
    /// are, and a row never grows past the word cap `EngineSegment.grouped` uses.
    @Test func aPhraseEndsOnPunctuationASilenceOrTheWordCap() throws {
        func row(_ text: String, to endMs: Int) -> TranscriptSegment {
            TranscriptSegment(meetingID: "m", channel: .mic, tStartMs: 0, tEndMs: endMs,
                              text: text, pass: .live)
        }
        let next = EngineSegment(startMs: 1_000, endMs: 1_400, text: "more")

        #expect(RecordingController.continuesPhrase(row("and then we", to: 900), next: next))
        #expect(!RecordingController.continuesPhrase(row("that is settled.", to: 900), next: next),
                "a full stop is a boundary the recogniser is telling us about")
        #expect(!RecordingController.continuesPhrase(row("is it?", to: 900), next: next))
        #expect(!RecordingController.continuesPhrase(row("and then we", to: -200), next: next),
                "over a second of silence is a new turn")
        let monologue = (0..<60).map { "word\($0)" }.joined(separator: " ")
        #expect(!RecordingController.continuesPhrase(row(monologue, to: 900), next: next),
                "a row must not become a twenty-minute paragraph no note can anchor into")
    }

    /// Both channels at once, each writing its own rows — mic and system are separate recognisers
    /// over separate audio and the store has to be able to tell them apart afterwards.
    @Test func bothChannelsRunAtOnce() async throws {
        let (directory, store, controller, meetingID) = try fixture()
        defer { TestStore.remove(directory) }

        controller.makeLiveTranscriber = { Fake() }
        var micTap: (([Float], Int) -> Void)?
        var systemTap: (([Float], Int) -> Void)?
        controller.attachLive(.mic, meetingID: meetingID) { micTap = $0 }
        controller.attachLive(.system, meetingID: meetingID) { systemTap = $0 }

        micTap?([0.1], 100)
        systemTap?([0.2], 200)
        await controller.stopLiveTranscription()

        let rows = try store.segments(meetingID: meetingID)
        #expect(rows.filter { $0.channel == .mic }.count == 2)  // one buffer plus the tail
        #expect(rows.filter { $0.channel == .system }.count == 2)
    }

    /// The batch pass replaces live rows and remaps note anchors. Live rows have to be in the store —
    /// and finished — before it runs, or a note anchors to a row that is about to be deleted.
    @Test func liveRowsAreCommittedBeforeAnythingCanReplaceThem() async throws {
        let (directory, store, controller, meetingID) = try fixture()
        defer { TestStore.remove(directory) }

        let fake = Fake()
        controller.makeLiveTranscriber = { fake }
        var tap: (([Float], Int) -> Void)?
        controller.attachLive(.mic, meetingID: meetingID) { tap = $0 }
        tap?([0.1], 1_000)
        await controller.stopLiveTranscription()

        let note = try store.addNote(meetingID: meetingID, tOffsetMs: 1_200, text: "check the rig booking")
        let anchor = try #require(note.anchorSegmentID)
        let anchored = try #require(try store.segments(meetingID: meetingID).first { $0.id == anchor })
        #expect(anchored.pass == .live)

        try store.replaceLiveSegments(meetingID: meetingID, with: [
            TranscriptSegment(
                meetingID: meetingID, channel: .mic, tStartMs: 950, tEndMs: 1_500,
                text: "check the rig booking for Thursday", pass: .final)
        ])
        let remapped = try #require(try store.notes(meetingID: meetingID).first?.anchorSegmentID)
        let final = try #require(try store.segments(meetingID: meetingID).first { $0.id == remapped })
        #expect(final.pass == .final)
        #expect(remapped != anchor)
    }
}
