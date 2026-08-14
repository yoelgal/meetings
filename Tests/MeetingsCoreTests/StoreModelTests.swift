import Foundation
import GRDB
import Testing

@testable import MeetingsCore

/// Column names are snake_case in SQL and camelCase in Swift. A mapping mistake there does not
/// crash — it reads a default or a null and quietly loses a field — so every model gets a full
/// round-trip, once with everything set and once with everything nullable left nil.
@Suite final class StoreModelTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = MeetingStore(dbPool: try MeetingsDatabase.open(at: directory.appendingPathComponent("store.db")))
    }

    deinit { TestStore.remove(directory) }

    @Test func meetingRoundTripsWithEveryFieldSet() throws {
        let folder = try store.createFolder(Folder(name: "Torch0", sortOrder: 3, createdAt: TestStore.referenceDate))
        let original = Meeting(
            folderID: folder.id,
            title: "Mater-AI intro",
            state: .complete,
            calendarEventID: "cal-event-1",
            scheduledStart: TestStore.referenceDate,
            scheduledEnd: TestStore.referenceDate.addingTimeInterval(2700),
            startedAt: TestStore.referenceDate.addingTimeInterval(120),
            endedAt: TestStore.referenceDate.addingTimeInterval(2600),
            attendees: [
                Attendee(name: "Sofia Nunes", email: "sofia@example.com"),
                Attendee(name: nil, email: "will@example.com"),
            ],
            preNotes: "Ask about ptychography throughput",
            summary: "# Summary\nWe agreed to ship.",
            actions: [
                Action(text: "Send the deck", owner: "Yoel", due: "end of week", done: false),
                Action(text: "Book a follow-up", owner: nil, due: nil, done: true),
            ],
            audioPath: "/tmp/audio/mic.wav",
            audioPurgedAt: TestStore.referenceDate.addingTimeInterval(86400),
            source: .imported,
            importedFrom: "granola-export.zip"
        )

        try store.createMeeting(original)
        let fetched = try #require(try store.meeting(id: original.id))

        #expect(fetched == original)
        #expect(fetched.attendees.count == 2)
        #expect(fetched.attendees[1].name == nil)
        #expect(fetched.actions?[0].due == "end of week")
        #expect(fetched.actions?[1].done == true)
    }

    @Test func meetingRoundTripsWithEveryNullableNil() throws {
        let original = Meeting(title: "Ad-hoc call", state: .recording)
        try store.createMeeting(original)
        let fetched = try #require(try store.meeting(id: original.id))

        #expect(fetched == original)
        #expect(fetched.folderID == nil)
        #expect(fetched.calendarEventID == nil)
        #expect(fetched.scheduledStart == nil)
        #expect(fetched.startedAt == nil)
        #expect(fetched.summary == nil)
        #expect(fetched.actions == nil)
        #expect(fetched.audioPurgedAt == nil)
        #expect(fetched.attendees.isEmpty)
        #expect(fetched.preNotes.isEmpty)
    }

    /// An empty action list and no action list are different states: "the agent looked and found
    /// nothing" versus "nobody has written this up".
    @Test func emptyActionsIsNotTheSameAsNoActions() throws {
        let none = TestStore.meeting(title: "Unwritten")
        let empty = Meeting(title: "Written, nothing to do", actions: [])
        try store.createMeeting(none)
        try store.createMeeting(empty)

        #expect(try store.meeting(id: none.id)?.actions == nil)
        #expect(try store.meeting(id: empty.id)?.actions == [])
    }

    @Test func folderRoundTrips() throws {
        let original = Folder(name: "Airbus", sortOrder: 7, createdAt: TestStore.referenceDate)
        try store.createFolder(original)
        let fetched = try #require(try store.folder(id: original.id))
        #expect(fetched == original)
        #expect(fetched.parentID == nil)
        #expect(try store.folder(named: "airbus")?.id == original.id)
    }

    @Test func segmentRoundTrips() throws {
        let meeting = try store.createMeeting(TestStore.meeting())
        let inserted = try store.insertSegment(
            TestStore.segment(
                meetingID: meeting.id,
                channel: .system,
                from: 1_200,
                to: 4_800,
                text: "So the ptychography run finished overnight.",
                pass: .final,
                edited: true
            )
        )
        let fetched = try #require(try store.segments(meetingID: meeting.id).first)
        #expect(fetched == inserted)
        #expect(fetched.id != nil)
        #expect(fetched.channel == .system)
        #expect(fetched.pass == .final)
        #expect(fetched.edited)
        #expect(fetched.tStartMs == 1_200)
        #expect(fetched.tEndMs == 4_800)
    }

    @Test func noteRoundTripsWithAndWithoutAnAnchor() throws {
        let meeting = try store.createMeeting(TestStore.meeting())
        let segment = try store.insertSegment(
            TestStore.segment(meetingID: meeting.id, from: 0, to: 1_000, text: "Opening remarks")
        )

        let anchored = try store.insertNote(
            Note(meetingID: meeting.id, tOffsetMs: 500, anchorSegmentID: segment.id, text: "check this")
        )
        let floating = try store.insertNote(
            Note(meetingID: meeting.id, tOffsetMs: 900, anchorSegmentID: nil, text: "no anchor")
        )

        let fetched = try store.notes(meetingID: meeting.id)
        #expect(fetched == [anchored, floating])
        #expect(fetched[0].anchorSegmentID == segment.id)
        #expect(fetched[1].anchorSegmentID == nil)
    }

    @Test func vocabularyTermRoundTrips() throws {
        let folder = try store.createFolder(Folder(name: "Torch0"))
        let scoped = try store.addVocabularyTerm(
            VocabularyTerm(term: "ptychography", folderID: folder.id, threshold: 0.42, source: .correction, enabled: false)
        )
        let global = try store.addVocabularyTerm(VocabularyTerm(term: "Ma'agan Michael", source: .attendee))

        let fetchedScoped = try #require(try store.vocabularyTerm("PTYCHOGRAPHY", folderID: folder.id))
        #expect(fetchedScoped == scoped)
        #expect(fetchedScoped.threshold == 0.42)
        #expect(fetchedScoped.source == .correction)
        #expect(fetchedScoped.enabled == false)

        let fetchedGlobal = try #require(try store.vocabularyTerm("Ma'agan Michael", folderID: nil))
        #expect(fetchedGlobal == global)
        #expect(fetchedGlobal.folderID == nil)
        #expect(fetchedGlobal.threshold == nil)
    }

    /// The JSON columns must never surface as strings above the store. This asserts the shape in
    /// SQLite is genuinely JSON text while the Swift side only ever sees `[Attendee]` / `[Action]`.
    @Test func jsonColumnsAreTextInSqliteAndTypedInSwift() throws {
        let meeting = Meeting(
            title: "JSON check",
            attendees: [Attendee(name: "Will Smith", email: "will@example.com")],
            actions: [Action(text: "Ship it", done: false)]
        )
        try store.createMeeting(meeting)

        let raw = try store.dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT attendees, actions FROM meetings WHERE id = ?", arguments: [meeting.id])
        }
        let attendeesJSON: String = try #require(raw?["attendees"])
        let actionsJSON: String = try #require(raw?["actions"])
        #expect(attendeesJSON.contains("\"Will Smith\""))
        #expect(actionsJSON.contains("\"Ship it\""))

        let fetched = try #require(try store.meeting(id: meeting.id))
        #expect(fetched.attendees == [Attendee(name: "Will Smith", email: "will@example.com")])
        #expect(fetched.actions == [Action(text: "Ship it", done: false)])
    }

    @Test func migrationCreatesEveryTableAndTheFtsIndex() throws {
        let tables = try store.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        for expected in ["folders", "meetings", "meetings_fts", "notes", "settings", "transcript_segments", "vocabulary"] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }
        let foreignKeys = try store.dbPool.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        #expect(foreignKeys == true)
        let journalMode = try store.dbPool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(journalMode == "wal")
    }
}
