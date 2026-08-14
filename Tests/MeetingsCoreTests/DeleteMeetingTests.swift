import Foundation
import GRDB
import Testing

@testable import MeetingsCore

/// Deleting a meeting, which until now the product could not do at all.
///
/// Four things have to be true at once and only one of them is the store's own code: the child rows
/// go by cascade, the FTS index goes with them by trigger, the audio directory goes because nothing
/// in the schema can take it, and a meeting that is not there is answered rather than crashed on.
/// The audio root is a real directory under the test's own temp tree, injected the same way
/// ``RetentionTests`` injects it, so nothing here can reach the operator's actual recordings.
@Suite final class DeleteMeetingTests {
    let directory: URL
    let audioRoot: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    /// A meeting with every kind of child row a meeting can have, and two real WAVs on disk with
    /// `audio_path` set — the shape the recorder and the batch pass actually leave behind.
    @discardableResult
    private func recorded(title: String = "Torch0 weekly", state: MeetingState = .complete) throws -> Meeting {
        var meeting = try store.createMeeting(TestStore.meeting(
            title: title, state: state, preNotes: "\(title) prenotes ptychography"))
        let segment = try store.insertSegment(TestStore.segment(
            meetingID: meeting.id, from: 0, to: 2_000, text: "\(title) transcript ptychography", pass: .final))
        try store.insertNote(Note(
            meetingID: meeting.id, tOffsetMs: 500, anchorSegmentID: segment.id,
            text: "\(title) note ptychography"))
        try store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meeting.id, channel: .system, kind: .capture,
            reason: "the system channel captured digital silence", at: TestStore.referenceDate))
        try FileManager.default.createDirectory(at: audio(meeting), withIntermediateDirectories: true)
        for name in ["mic.wav", "system.wav"] {
            try Data(repeating: 0x41, count: 2_048).write(to: audio(meeting).appendingPathComponent(name))
        }
        let audioPath = audio(meeting).path
        meeting = try store.updateMeeting(id: meeting.id) {
            $0.summary = "\(title) summary ptychography"
            $0.audioPath = audioPath
        }
        return meeting
    }

    private func audio(_ meeting: Meeting) -> URL {
        audioRoot.appendingPathComponent(meeting.id, isDirectory: true)
    }

    private func audioExists(_ meeting: Meeting) -> Bool {
        FileManager.default.fileExists(atPath: audio(meeting).path)
    }

    private func childRowCounts(_ meetingID: String) throws -> (segments: Int, notes: Int, issues: Int) {
        try store.dbPool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT count(*) FROM transcript_segments WHERE meeting_id = ?",
                                 arguments: [meetingID]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM notes WHERE meeting_id = ?",
                                 arguments: [meetingID]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM transcript_issues WHERE meeting_id = ?",
                                 arguments: [meetingID]) ?? -1
            )
        }
    }

    @Test func everyChildRowGoesWithTheMeeting() throws {
        let doomed = try recorded(title: "Doomed")
        let keeper = try recorded(title: "Keeper")
        #expect(try childRowCounts(doomed.id) == (segments: 1, notes: 1, issues: 1))

        #expect(try store.deleteMeeting(id: doomed.id, audioRoot: audioRoot))

        #expect(try store.meeting(id: doomed.id) == nil)
        #expect(try childRowCounts(doomed.id) == (segments: 0, notes: 0, issues: 0))
        // A cascade that overreaches loses more than one that misses, so the neighbour is checked
        // every time the cascade is.
        #expect(try childRowCounts(keeper.id) == (segments: 1, notes: 1, issues: 1))
        #expect(try store.meeting(id: keeper.id) != nil)
    }

    /// The one the whole feature turns on. Nothing in the store's code touches `meetings_fts` here:
    /// the meeting's own trigger drops its pre-notes and summary rows, and the segment and note rows
    /// are dropped by *their* triggers firing on a foreign-key cascade — which SQLite does do, and
    /// which is asserted rather than assumed, because a stale index row is invisible until a deleted
    /// meeting turns up in `meetings search` quoting a transcript nothing can open.
    @Test func theSearchIndexForgetsADeletedMeetingEntirely() throws {
        let doomed = try recorded(title: "Doomed")
        let keeper = try recorded(title: "Keeper")
        // All four kinds indexed for each: segment, note, prenotes, summary.
        #expect(try store.search(query: "ptychography").count == 8)

        #expect(try store.deleteMeeting(id: doomed.id, audioRoot: audioRoot))

        let hits = try store.search(query: "ptychography")
        #expect(hits.count == 4)
        #expect(hits.allSatisfy { $0.meeting.id == keeper.id })
        // Straight at the index as well as through the query, because `search` joins to `meetings`
        // and would hide an orphaned row that is still matching.
        let orphans = try store.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM meetings_fts WHERE meeting_id = ?",
                             arguments: [doomed.id])
        }
        #expect(orphans == 0)
    }

    @Test func theAudioDirectoryGoesWithTheRow() throws {
        let doomed = try recorded(title: "Doomed")
        let keeper = try recorded(title: "Keeper")
        #expect(audioExists(doomed))

        #expect(try store.deleteMeeting(id: doomed.id, audioRoot: audioRoot))

        #expect(!audioExists(doomed), "the WAVs outlived the row that named them")
        #expect(audioExists(keeper))
    }

    /// A meeting the retention sweep already purged has `audio_path` NULL, and an import can have
    /// WAVs on disk before anything writes the path. Both are found by the id, so neither leaves a
    /// directory behind.
    @Test func audioIsFoundByTheMeetingIdEvenWhenTheRowHasNoPath() throws {
        let meeting = try recorded()
        try store.updateMeeting(id: meeting.id) { $0.audioPath = nil }

        #expect(try store.deleteMeeting(id: meeting.id, audioRoot: audioRoot))
        #expect(!audioExists(meeting))
    }

    /// `audio_path` is a string two processes and an importer can write, and this code calls
    /// `removeItem`. A row pointing outside the audio root deletes nothing at all.
    @Test func anAudioPathOutsideTheAudioRootIsNotFollowed() throws {
        let elsewhere = directory.appendingPathComponent("not-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let meeting = try store.createMeeting(TestStore.meeting())
        try store.updateMeeting(id: meeting.id) { $0.audioPath = elsewhere.path }

        #expect(try store.deleteMeeting(id: meeting.id, audioRoot: audioRoot))
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    /// A meeting with no audio at all is the common case — nothing was ever recorded, so there is no
    /// directory to remove and that is not a failure.
    @Test func aMeetingWithNoAudioDeletesCleanly() throws {
        let meeting = try store.createMeeting(TestStore.meeting())
        #expect(try store.deleteMeeting(id: meeting.id, audioRoot: audioRoot))
        #expect(try store.meeting(id: meeting.id) == nil)
    }

    @Test func deletingAMeetingThatIsNotThereIsAnAnswerRatherThanAFailure() throws {
        #expect(try store.deleteMeeting(id: "nope", audioRoot: audioRoot) == false)
        #expect(try store.deleteMeeting(id: "", audioRoot: audioRoot) == false)
    }

    /// The two states the retention sweep refuses, refused here for the same reason: one is having
    /// audio written into it right now and the other is having it read. Deleting the row under
    /// either leaves the recorder writing WAVs for a meeting that no longer exists.
    @Test func aMeetingBeingRecordedOrTranscribedIsRefusedWithItsAudioIntact() throws {
        for state in [MeetingState.recording, .transcribing] {
            let meeting = try recorded(title: "Live", state: state)
            #expect(throws: StoreError.self) {
                try store.deleteMeeting(id: meeting.id, audioRoot: audioRoot)
            }
            #expect(try store.meeting(id: meeting.id) != nil)
            #expect(audioExists(meeting), "a refused delete must not have taken the audio anyway")
        }
    }
}
