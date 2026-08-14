import Foundation
import Testing

@testable import MeetingsCore

/// The batch re-pass is the one place where getting it wrong is invisible: the transcript still
/// looks fine, and a note just quietly points at a sentence nobody said. Everything about it gets
/// asserted.
@Suite final class StoreBatchPassTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = MeetingStore(dbPool: try MeetingsDatabase.open(at: directory.appendingPathComponent("store.db")))
    }

    deinit { TestStore.remove(directory) }

    @Test func editedSegmentsSurviveAndUneditedLiveRowsAreGone() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .transcribing))
        let corrected = try store.insertSegment(
            TestStore.segment(meetingID: meeting.id, from: 0, to: 2_000, text: "the ptychography run", edited: true)
        )
        try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, from: 2_000, to: 4_000, text: "mangled live text"),
            TestStore.segment(meetingID: meeting.id, channel: .system, from: 4_000, to: 6_000, text: "more mangled live"),
        ])

        try store.replaceLiveSegments(meetingID: meeting.id, with: [
            TestStore.segment(meetingID: meeting.id, from: 2_000, to: 4_100, text: "clean final text"),
            TestStore.segment(meetingID: meeting.id, channel: .system, from: 4_100, to: 6_200, text: "clean final reply"),
        ])

        let segments = try store.segments(meetingID: meeting.id)
        #expect(segments.map(\.text) == ["the ptychography run", "clean final text", "clean final reply"])
        #expect(segments[0].id == corrected.id, "the edited row keeps its identity, so anything anchored to it still is")
        #expect(segments[0].edited)
        #expect(segments[0].pass == .final, "after a batch pass every surviving row is part of the final transcript")
        #expect(segments.dropFirst().allSatisfy { $0.pass == .final && !$0.edited })
        #expect(try store.meeting(id: meeting.id)?.state == .ready)
    }

    /// The correction owns its span. Re-transcribing the same audio produces the same wrong words
    /// again, and keeping both copies puts the mistake the user fixed straight back into the
    /// transcript the agent reads — it "poisons every summary downstream, silently and
    /// confidently", with the correction sitting right next to it.
    @Test func aCorrectionSuppressesTheMachinesRetakeOfTheSameSpan() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        let machine = try store.insertSegment(
            TestStore.segment(
                meetingID: meeting.id, from: 0, to: 2_000,
                text: "we should ship torch zero on friday", pass: .final
            )
        )
        try store.editSegment(id: try #require(machine.id), text: "we should ship Torch0 on Friday")

        // The re-transcription hands back exactly what it heard the first time.
        try store.replaceLiveSegments(meetingID: meeting.id, with: [
            TestStore.segment(
                meetingID: meeting.id, from: 0, to: 2_000,
                text: "we should ship torch zero on friday", pass: .final
            ),
            TestStore.segment(meetingID: meeting.id, from: 2_000, to: 4_000, text: "and cut a tag", pass: .final),
        ])

        let segments = try store.segments(meetingID: meeting.id)
        #expect(segments.map(\.text) == ["we should ship Torch0 on Friday", "and cut a tag"])
        #expect(try store.search(query: "torch zero").isEmpty, "the uncorrected words are not searchable either")
    }

    /// Overlap is judged per channel and half-open, so a correction only swallows the machine's
    /// retake of its own audio — not the other speaker, and not a segment that merely abuts it.
    @Test func suppressionIsPerChannelAndDoesNotEatAbuttingSegments() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        let machine = try store.insertSegment(
            TestStore.segment(meetingID: meeting.id, from: 1_000, to: 2_000, text: "mangled", pass: .final)
        )
        try store.editSegment(id: try #require(machine.id), text: "corrected")

        try store.replaceLiveSegments(meetingID: meeting.id, with: [
            TestStore.segment(meetingID: meeting.id, from: 0, to: 1_000, text: "abuts before", pass: .final),
            TestStore.segment(meetingID: meeting.id, from: 1_500, to: 1_800, text: "overlaps on mic", pass: .final),
            TestStore.segment(meetingID: meeting.id, channel: .system, from: 1_500, to: 1_800,
                              text: "the other person, talking over them", pass: .final),
            TestStore.segment(meetingID: meeting.id, from: 2_000, to: 3_000, text: "abuts after", pass: .final),
        ])

        #expect(try store.segments(meetingID: meeting.id).map(\.text) == [
            "abuts before", "corrected", "the other person, talking over them", "abuts after",
        ])
    }

    /// A one-second correction must not delete the thirty-second segment it sits inside.
    ///
    /// The suppression rule used to fire on any overlap, so re-transcribing a meeting where somebody
    /// had fixed a single word threw away the twenty-nine seconds around it that nobody had touched.
    /// The rule is containment now, and this asserts it from both directions: a new segment that
    /// starts before the correction, and one that ends after it, both survive.
    @Test func aShortCorrectionDoesNotSwallowTheLongSegmentAroundIt() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        let machine = try store.insertSegment(TestStore.segment(
            meetingID: meeting.id, from: 10_000, to: 11_000, text: "torch zero", pass: .final))
        try store.editSegment(id: try #require(machine.id), text: "Torch0")

        try store.replaceLiveSegments(meetingID: meeting.id, with: [
            // Thirty seconds of speech that happens to contain the corrected second.
            TestStore.segment(meetingID: meeting.id, from: 0, to: 30_000,
                              text: "a very long turn that runs straight through the correction", pass: .final),
            // Overlaps the correction's leading edge only.
            TestStore.segment(meetingID: meeting.id, from: 9_000, to: 10_500, text: "straddles the start", pass: .final),
            // Overlaps its trailing edge only.
            TestStore.segment(meetingID: meeting.id, from: 10_500, to: 12_000, text: "straddles the end", pass: .final),
            // Wholly inside it: this is the machine's retake of audio the user already fixed.
            TestStore.segment(meetingID: meeting.id, from: 10_200, to: 10_800, text: "torch zero again", pass: .final),
        ])

        #expect(try store.segments(meetingID: meeting.id).map(\.text) == [
            "a very long turn that runs straight through the correction",
            "straddles the start",
            "Torch0",
            "straddles the end",
        ])
    }

    /// Exact coincidence still counts as covered: the machine re-transcribing precisely the span the
    /// user corrected is the case the suppression exists for.
    @Test func aRetakeOfExactlyTheCorrectedSpanIsDropped() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        let machine = try store.insertSegment(TestStore.segment(
            meetingID: meeting.id, from: 4_000, to: 6_000, text: "ptychography", pass: .final))
        try store.editSegment(id: try #require(machine.id), text: "ptychography rig")

        try store.replaceLiveSegments(meetingID: meeting.id, with: [
            TestStore.segment(meetingID: meeting.id, from: 4_000, to: 6_000, text: "tikography", pass: .final),
        ])
        #expect(try store.segments(meetingID: meeting.id).map(\.text) == ["ptychography rig"])
    }

    /// The note stays on the words the user fixed. The machine's near-miss retake — 1 190–2 000
    /// against a correction at 1 200–2 000 — is not contained by the correction, so it legitimately
    /// survives beside it; the anchor rule prefers the user's own text when both cover the offset.
    @Test func aNoteAnchoredToACorrectionStaysThereAcrossAReTranscription() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, from: 0, to: 1_190, text: "first bit", pass: .final),
            TestStore.segment(meetingID: meeting.id, from: 1_200, to: 2_000, text: "mangled second bit", pass: .final),
        ])
        let second = try #require(try store.segments(meetingID: meeting.id).last?.id)
        let corrected = try store.editSegment(id: second, text: "corrected second bit")
        try store.addNote(meetingID: meeting.id, tOffsetMs: 1_500, text: "this is the bit that matters")
        #expect(try store.notes(meetingID: meeting.id).first?.anchorSegmentID == corrected.id)

        try store.replaceLiveSegments(meetingID: meeting.id, with: [
            TestStore.segment(meetingID: meeting.id, from: 0, to: 1_190, text: "first bit", pass: .final),
            TestStore.segment(meetingID: meeting.id, from: 1_190, to: 2_000, text: "mangled second bit", pass: .final),
        ])

        let note = try #require(try store.notes(meetingID: meeting.id).first)
        #expect(note.anchorSegmentID == corrected.id)
        let anchored = try store.segments(meetingID: meeting.id).first { $0.id == note.anchorSegmentID }
        #expect(anchored?.text == "corrected second bit")
    }

    /// The §11 crash-recovery path: a crash leaves live rows behind, the meeting is recovered to
    /// `ready`, the user fixes a line, and the batch pass is re-run from the WAVs. The correction
    /// must not stay labelled `live` in a finished transcript.
    @Test func aCorrectionMadeOnALiveRowIsFinalAfterTheBatchPass() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        let live = try store.insertSegment(
            TestStore.segment(meetingID: meeting.id, from: 0, to: 1_000, text: "torch zero", pass: .live)
        )
        try store.editSegment(id: try #require(live.id), text: "Torch0")

        try store.replaceLiveSegments(meetingID: meeting.id, with: [
            TestStore.segment(meetingID: meeting.id, from: 2_000, to: 3_000, text: "next line"),
        ])

        let segments = try store.segments(meetingID: meeting.id)
        #expect(segments.map(\.text) == ["Torch0", "next line"])
        #expect(segments.allSatisfy { $0.pass == .final }, "no live row survives a batch pass")
        #expect(segments[0].edited)
    }

    /// Containment beats proximity. A note typed at 9.8s while a long sentence was still running
    /// belongs to that sentence, not to the one that happens to start 200 ms later.
    @Test func containmentWinsOverNearestByDistance() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .transcribing))
        try store.insertNote(Note(meetingID: meeting.id, tOffsetMs: 9_800, text: "he's wrong about this"))

        try store.replaceLiveSegments(meetingID: meeting.id, with: [
            TestStore.segment(meetingID: meeting.id, from: 0, to: 10_000, text: "a long uninterrupted point"),
            TestStore.segment(meetingID: meeting.id, channel: .system, from: 10_000, to: 12_000, text: "the reply"),
        ])

        let segments = try store.segments(meetingID: meeting.id)
        let note = try #require(try store.notes(meetingID: meeting.id).first)

        // Nearest-by-start would pick the reply: |9800 - 10000| = 200 against |9800 - 0| = 9800.
        #expect(abs(9_800 - segments[1].tStartMs) < abs(9_800 - segments[0].tStartMs))
        #expect(note.anchorSegmentID == segments[0].id)
    }

    @Test func aNoteBeforeAnybodySpokeStillResolves() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .transcribing))
        try store.insertNote(Note(meetingID: meeting.id, tOffsetMs: 0, text: "agenda: three things"))

        try store.replaceLiveSegments(meetingID: meeting.id, with: [
            TestStore.segment(meetingID: meeting.id, from: 5_000, to: 7_000, text: "right, shall we start"),
        ])

        let segments = try store.segments(meetingID: meeting.id)
        let note = try #require(try store.notes(meetingID: meeting.id).first)
        #expect(note.anchorSegmentID == segments[0].id)
    }

    @Test func anchorIsNullOnlyWhenThereAreNoSegmentsAtAll() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .transcribing))
        let note = try store.addNote(meetingID: meeting.id, tOffsetMs: 1_000, text: "silent meeting")
        #expect(note.anchorSegmentID == nil)

        try store.replaceLiveSegments(meetingID: meeting.id, with: [])
        #expect(try store.notes(meetingID: meeting.id)[0].anchorSegmentID == nil)
        #expect(try store.segments(meetingID: meeting.id).isEmpty)
    }

    @Test func everyNoteIsRemappedOntoTheFinalTranscript() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        let live = try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, from: 0, to: 3_000, text: "live one"),
            TestStore.segment(meetingID: meeting.id, from: 3_000, to: 6_000, text: "live two"),
        ])
        let liveIDs = Set(live.compactMap(\.id))

        try store.addNote(meetingID: meeting.id, tOffsetMs: 1_500, text: "first point")
        try store.addNote(meetingID: meeting.id, tOffsetMs: 4_500, text: "second point")
        #expect(try store.notes(meetingID: meeting.id).allSatisfy { liveIDs.contains($0.anchorSegmentID ?? -1) })

        try store.replaceLiveSegments(meetingID: meeting.id, with: [
            TestStore.segment(meetingID: meeting.id, from: 0, to: 2_800, text: "final one"),
            TestStore.segment(meetingID: meeting.id, from: 2_800, to: 6_100, text: "final two"),
        ])

        let finals = try store.segments(meetingID: meeting.id)
        let notes = try store.notes(meetingID: meeting.id)
        #expect(notes.map(\.anchorSegmentID) == [finals[0].id, finals[1].id])
        #expect(notes.allSatisfy { !liveIDs.contains($0.anchorSegmentID ?? -1) })
    }

    /// Re-transcribing must not double the transcript. Deleting only `pass = 'live'` rows would
    /// leave the previous final pass in place and stack a second copy on top of it.
    @Test func runningTheBatchPassTwiceIsIdempotent() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .transcribing))
        try store.insertSegment(
            TestStore.segment(meetingID: meeting.id, from: 0, to: 1_000, text: "kept correction", edited: true)
        )
        try store.addNote(meetingID: meeting.id, tOffsetMs: 4_000, text: "the point")

        let batch = [
            TestStore.segment(meetingID: meeting.id, from: 1_000, to: 3_000, text: "final one"),
            TestStore.segment(meetingID: meeting.id, channel: .system, from: 3_000, to: 5_000, text: "final two"),
        ]

        try store.replaceLiveSegments(meetingID: meeting.id, with: batch)
        let firstTexts = try store.segments(meetingID: meeting.id).map(\.text)
        let firstAnchorStart = try anchorStartMs(store, meetingID: meeting.id)

        try store.replaceLiveSegments(meetingID: meeting.id, with: batch)
        let secondTexts = try store.segments(meetingID: meeting.id).map(\.text)

        #expect(firstTexts == ["kept correction", "final one", "final two"])
        #expect(secondTexts == firstTexts)
        #expect(try anchorStartMs(store, meetingID: meeting.id) == firstAnchorStart)
        #expect(try store.notes(meetingID: meeting.id).count == 1)
        #expect(try store.segments(meetingID: meeting.id).filter(\.edited).count == 1)
    }

    /// `complete` means "a summary exists". A re-transcription of a written-up meeting
    /// must not shove it back into the Needs write-up list.
    @Test func aWrittenUpMeetingStaysCompleteAfterAReTranscription() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .complete))
        try store.updateMeeting(id: meeting.id) { $0.summary = "# Decisions\nWe shipped." }

        try store.replaceLiveSegments(meetingID: meeting.id, with: [
            TestStore.segment(meetingID: meeting.id, from: 0, to: 1_000, text: "hello"),
        ])
        #expect(try store.meeting(id: meeting.id)?.state == .complete)
        #expect(try store.needsWriteUp().isEmpty)
    }

    @Test func batchPassOnAMissingMeetingIsNotFound() throws {
        #expect(throws: StoreError.meetingNotFound("ghost")) {
            try store.replaceLiveSegments(meetingID: "ghost", with: [])
        }
    }

    /// The anchor rule in isolation, including the tie-breaks that keep it deterministic.
    @Test func anchorRuleEdgeCases() {
        func segment(_ id: Int64, _ channel: Channel, _ startMs: Int, _ endMs: Int) -> TranscriptSegment {
            var segment = TestStore.segment(meetingID: "m", channel: channel, from: startMs, to: endMs, text: "…")
            segment.id = id
            return segment
        }
        // Mic and system overlap — both channels are talking over each other, which is normal.
        let mic = segment(1, .mic, 0, 5_000)
        let system = segment(2, .system, 0, 5_000)
        let later = segment(3, .mic, 9_000, 10_000)
        let all = [mic, system, later]

        #expect(MeetingStore.anchorSegmentID(forOffsetMs: 100, in: []) == nil)
        // Both contain the offset; the first in (t_start_ms, id) order wins, every time.
        #expect(MeetingStore.anchorSegmentID(forOffsetMs: 2_000, in: all) == 1)
        // Boundaries are inclusive at both ends.
        #expect(MeetingStore.anchorSegmentID(forOffsetMs: 5_000, in: all) == 1)
        #expect(MeetingStore.anchorSegmentID(forOffsetMs: 9_000, in: all) == 3)
        // In a gap, distance to `t_start_ms` decides — forwards…
        #expect(MeetingStore.anchorSegmentID(forOffsetMs: 8_000, in: all) == 3)
        // …and backwards.
        #expect(MeetingStore.anchorSegmentID(forOffsetMs: 6_000, in: [segment(10, .mic, 4_000, 5_000), segment(11, .mic, 9_000, 10_000)]) == 10)
        // Past the end of the transcript, the last segment is still the right answer.
        #expect(MeetingStore.anchorSegmentID(forOffsetMs: 99_000, in: all) == 3)
    }

    /// The most common note there is: you type a reaction the instant somebody finishes a point.
    /// Ranking by distance to `t_start_ms` anchors it to whoever speaks next, and the bias grows
    /// with how long the previous person talked — so the longer they talk, the more certainly your
    /// note about them lands on the wrong person.
    @Test func aNoteTypedJustAfterALongTurnAnchorsToThatTurn() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .transcribing))
        try store.insertNote(Note(meetingID: meeting.id, tOffsetMs: 60_100, text: "he's overselling this"))

        try store.replaceLiveSegments(meetingID: meeting.id, with: [
            TestStore.segment(meetingID: meeting.id, from: 0, to: 60_000,
                              text: "one solid minute about the ptychography roadmap"),
            TestStore.segment(meetingID: meeting.id, channel: .system, from: 61_000, to: 62_000,
                              text: "anyway, unrelated, what about lunch"),
        ])

        let segments = try store.segments(meetingID: meeting.id)
        let note = try #require(try store.notes(meetingID: meeting.id).first)
        // 100 ms after the monologue ends, 900 ms before the next sentence starts.
        #expect(note.anchorSegmentID == segments[0].id)
    }

    /// Nothing validates `t_start_ms` on the way in, and a corrupt import or a bad clock conversion
    /// used to overflow the comparator's subtraction — an arithmetic trap, so the whole process dies
    /// rather than producing a merely wrong anchor.
    @Test func anExtremeSegmentOffsetDoesNotTrapTheComparator() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, from: 0, to: 1_000, text: "an ordinary line"),
            TestStore.segment(meetingID: meeting.id, from: Int.max, to: Int.max, text: "a nonsense offset"),
        ])
        // Two segments, so `min(by:)` actually invokes the comparator.
        let note = try store.addNote(meetingID: meeting.id, tOffsetMs: -1, text: "typed before the start")
        #expect(note.anchorSegmentID == (try store.segments(meetingID: meeting.id).first?.id))
    }

    private func anchorStartMs(_ store: MeetingStore, meetingID: String) throws -> Int? {
        let segments = try store.segments(meetingID: meetingID)
        guard let anchor = try store.notes(meetingID: meetingID).first?.anchorSegmentID else { return nil }
        return segments.first { $0.id == anchor }?.tStartMs
    }
}
