import Foundation
import GRDB
import Testing

@testable import MeetingsCore

@Suite final class StoreQueryTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = MeetingStore(dbPool: try MeetingsDatabase.open(at: directory.appendingPathComponent("store.db")))
    }

    deinit { TestStore.remove(directory) }

    /// `coalesce(started_at, scheduled_start)` desc, `id` desc. The null case is the one that goes
    /// wrong in practice: a scheduled meeting that never ran must not sort as if it happened at the
    /// epoch, and two rows with the same key must not swap places between two fetches.
    @Test func newestFirstOrderingIsCorrectAndStableWithNullStartedAt() throws {
        let base = TestStore.referenceDate

        // Ran an hour ago.
        let ran = Meeting(title: "Ran", startedAt: base)
        // Never ran, but was scheduled for two hours after that — so it is the newest.
        let scheduledOnly = Meeting(title: "Scheduled only", scheduledStart: base.addingTimeInterval(7200))
        // Ran, but earlier.
        let older = Meeting(title: "Older", startedAt: base.addingTimeInterval(-7200))
        // Neither date: an imported row with nothing to sort on.
        let undated = Meeting(id: "aaaa-undated", title: "Undated")
        let alsoUndated = Meeting(id: "zzzz-undated", title: "Also undated")

        for meeting in [ran, scheduledOnly, older, undated, alsoUndated] {
            try store.createMeeting(meeting)
        }

        let titles = try store.allMeetings().map(\.title)
        #expect(titles == ["Scheduled only", "Ran", "Older", "Also undated", "Undated"])

        // Stable: the same query twice gives the same order, and the id tie-break decides the
        // two undated rows rather than insertion order.
        #expect(try store.allMeetings().map(\.id) == (try store.allMeetings().map(\.id)))
        #expect(try store.allMeetings().suffix(2).map(\.id) == ["zzzz-undated", "aaaa-undated"])
    }

    @Test func listsByFolderAndState() throws {
        let torch0 = try store.createFolder(Folder(name: "Torch0"))
        let airbus = try store.createFolder(Folder(name: "Airbus"))

        let a = try store.createMeeting(TestStore.meeting(title: "Torch0 weekly", state: .ready, folderID: torch0.id))
        let b = try store.createMeeting(TestStore.meeting(title: "Airbus sync", state: .complete, folderID: airbus.id))
        let c = try store.createMeeting(TestStore.meeting(title: "Unfiled chat", state: .ready, folderID: nil))

        #expect(try store.meetings(folderID: torch0.id).map(\.id) == [a.id])
        #expect(try store.meetings(folderID: nil).map(\.id) == [c.id])
        #expect(try store.meetings(state: .complete).map(\.id) == [b.id])
        #expect(try store.meetings(state: .ready).count == 2)
        #expect(try store.allMeetings().count == 3)
        #expect(try store.allMeetings(limit: 2).count == 2)
    }

    @Test func needsWriteUpIsOldestFirstAndCarriesAnAge() throws {
        let now = TestStore.referenceDate.addingTimeInterval(86_400)
        let old = try store.createMeeting(
            Meeting(title: "Three days stale", state: .ready, startedAt: now.addingTimeInterval(-259_200))
        )
        let recent = try store.createMeeting(
            Meeting(title: "This morning", state: .ready, startedAt: now.addingTimeInterval(-3_600))
        )
        try store.createMeeting(Meeting(title: "Already written", state: .complete, startedAt: now))
        let undated = try store.createMeeting(Meeting(id: "0000-undated", title: "Imported, undated", state: .ready))

        let pending = try store.needsWriteUp(now: now)
        #expect(pending.map(\.meeting.id) == [undated.id, old.id, recent.id])
        #expect(pending[0].age == nil)
        #expect(pending[1].age == 259_200)
        #expect(pending[2].age == 3_600)
    }

    @Test func deletingAMeetingCascadesAndLeavesNoOrphanFtsRows() throws {
        let keeper = try store.createMeeting(TestStore.meeting(title: "Keeper", preNotes: "keeper prenotes"))
        let doomed = try store.createMeeting(TestStore.meeting(title: "Doomed", preNotes: "doomed prenotes"))
        try store.updateMeeting(id: doomed.id) { $0.summary = "doomed summary" }

        let segment = try store.insertSegment(
            TestStore.segment(meetingID: doomed.id, from: 0, to: 1_000, text: "doomed transcript line")
        )
        try store.insertNote(Note(meetingID: doomed.id, tOffsetMs: 500, anchorSegmentID: segment.id, text: "doomed note"))
        try store.insertSegment(TestStore.segment(meetingID: keeper.id, from: 0, to: 1_000, text: "keeper transcript line"))

        #expect(try store.deleteMeeting(id: doomed.id))

        #expect(try store.meeting(id: doomed.id) == nil)
        #expect(try store.segments(meetingID: doomed.id).isEmpty)
        #expect(try store.notes(meetingID: doomed.id).isEmpty)

        let orphans = try store.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM meetings_fts WHERE meeting_id = ?", arguments: [doomed.id])
        }
        #expect(orphans == 0)

        // And the keeper is untouched — a cascade that overreaches is worse than one that misses.
        #expect(try store.segments(meetingID: keeper.id).count == 1)
        // Its own name matches, and a title hit stands in for that meeting's body hits, so the two
        // surviving index rows are proved by words the title does not contain.
        #expect(try store.search(query: "keeper").map(\.kind) == [.title])
        #expect(try store.search(query: "prenotes").map(\.kind) == [.prenotes])
        #expect(try store.search(query: "line").map(\.kind) == [.segment])
    }

    @Test func deletingAFolderUnfilesItsMeetingsAndTakesItsVocabulary() throws {
        let folder = try store.createFolder(Folder(name: "Torch0"))
        let meeting = try store.createMeeting(TestStore.meeting(folderID: folder.id))
        try store.addVocabularyTerm(VocabularyTerm(term: "ptychography", folderID: folder.id))
        try store.addVocabularyTerm(VocabularyTerm(term: "altinha"))

        #expect(try store.deleteFolder(id: folder.id))

        #expect(try store.meeting(id: meeting.id)?.folderID == nil)
        #expect(try store.allVocabularyTerms().map(\.term) == ["altinha"])
    }

    @Test func updateMeetingMutatesInOneTransaction() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        let updated = try store.updateMeeting(id: meeting.id) {
            $0.summary = "# Decisions\nShip on Friday."
            $0.actions = [Action(text: "Ship", owner: "Yoel", done: false)]
            $0.state = .complete
        }
        #expect(updated.state == .complete)
        #expect(try store.meeting(id: meeting.id)?.summary?.contains("Ship on Friday") == true)
        #expect(try store.meeting(id: meeting.id)?.actions?.count == 1)
    }

    @Test func updatingAMissingMeetingIsNotFound() throws {
        #expect(throws: StoreError.meetingNotFound("nope")) {
            try store.updateMeeting(id: "nope") { $0.title = "x" }
        }
        #expect(try store.deleteMeeting(id: "nope") == false)
    }

    // MARK: - Transcript edits

    @Test func editingASegmentMarksItEditedAndUpdatesTheIndex() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        let segment = try store.insertSegment(
            TestStore.segment(meetingID: meeting.id, from: 0, to: 2_000, text: "the tycography run", pass: .final)
        )

        let edited = try store.editSegment(id: try #require(segment.id), text: "the ptychography run")
        #expect(edited.edited)
        #expect(edited.text == "the ptychography run")
        #expect(try store.search(query: "ptychography").count == 1)
        #expect(try store.search(query: "tycography").isEmpty)
    }

    /// Editing while recording is disallowed, because the batch pass replaces live rows
    /// wholesale and the edit would vanish without a word.
    @Test func editingASegmentWhileRecordingIsRejected() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        let segment = try store.insertSegment(
            TestStore.segment(meetingID: meeting.id, from: 0, to: 2_000, text: "half heard")
        )
        #expect(throws: StoreError.self) {
            try store.editSegment(id: try #require(segment.id), text: "corrected")
        }
        #expect(try store.segments(meetingID: meeting.id)[0].edited == false)
    }

    @Test func segmentsFilterByChannelAndOrderByStart() throws {
        let meeting = try store.createMeeting(TestStore.meeting())
        try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, channel: .system, from: 4_000, to: 5_000, text: "them, later"),
            TestStore.segment(meetingID: meeting.id, channel: .mic, from: 0, to: 1_000, text: "me, first"),
            TestStore.segment(meetingID: meeting.id, channel: .system, from: 1_000, to: 2_000, text: "them, first"),
        ])

        #expect(try store.segments(meetingID: meeting.id).map(\.tStartMs) == [0, 1_000, 4_000])
        #expect(try store.segments(meetingID: meeting.id, channel: .mic).map(\.text) == ["me, first"])
        #expect(try store.segments(meetingID: meeting.id, channel: .system).map(\.tStartMs) == [1_000, 4_000])
    }

    // MARK: - Vocabulary

    @Test func vocabularyInEffectIsGlobalPlusOwnFolderEnabledOnly() throws {
        let torch0 = try store.createFolder(Folder(name: "Torch0"))
        let airbus = try store.createFolder(Folder(name: "Airbus"))
        let meeting = try store.createMeeting(TestStore.meeting(folderID: torch0.id))

        try store.addVocabularyTerm(VocabularyTerm(term: "Ma'agan Michael"))
        try store.addVocabularyTerm(VocabularyTerm(term: "ptychography", folderID: torch0.id))
        try store.addVocabularyTerm(VocabularyTerm(term: "A350", folderID: airbus.id))
        let disabled = try store.addVocabularyTerm(VocabularyTerm(term: "Torch0", folderID: torch0.id))
        try store.setVocabularyEnabled(id: try #require(disabled.id), false)
        let disabledGlobal = try store.addVocabularyTerm(VocabularyTerm(term: "altinha"))
        try store.setVocabularyEnabled(id: try #require(disabledGlobal.id), false)

        let inEffect = try store.vocabularyInEffect(meetingID: meeting.id).map(\.term)
        #expect(inEffect == ["Ma'agan Michael", "ptychography"])
    }

    @Test func unfiledMeetingsSeeGlobalTermsOnly() throws {
        let torch0 = try store.createFolder(Folder(name: "Torch0"))
        let meeting = try store.createMeeting(TestStore.meeting(folderID: nil))
        try store.addVocabularyTerm(VocabularyTerm(term: "Ma'agan Michael"))
        try store.addVocabularyTerm(VocabularyTerm(term: "ptychography", folderID: torch0.id))

        #expect(try store.vocabularyInEffect(meetingID: meeting.id).map(\.term) == ["Ma'agan Michael"])
    }

    /// The same term in two scopes is two rows; the same term twice in one scope is one row and no
    /// error, because attendee seeding runs again every time a meeting is touched.
    @Test func addingATermIsIdempotentPerScope() throws {
        let folder = try store.createFolder(Folder(name: "Torch0"))
        let first = try store.addVocabularyTerm(VocabularyTerm(term: "Nunes", source: .attendee))
        let again = try store.addVocabularyTerm(VocabularyTerm(term: "nunes", source: .manual))
        let scoped = try store.addVocabularyTerm(VocabularyTerm(term: "Nunes", folderID: folder.id))

        #expect(first.id == again.id)
        #expect(again.source == .attendee, "the existing row wins; a repeat seed must not rewrite it")
        #expect(scoped.id != first.id)
        #expect(try store.allVocabularyTerms().count == 2)
    }

    @Test func vocabularyDeleteAndScopeListing() throws {
        let folder = try store.createFolder(Folder(name: "Torch0"))
        let global = try store.addVocabularyTerm(VocabularyTerm(term: "altinha"))
        try store.addVocabularyTerm(VocabularyTerm(term: "ptychography", folderID: folder.id))

        #expect(try store.vocabularyTerms(folderID: nil).map(\.term) == ["altinha"])
        #expect(try store.vocabularyTerms(folderID: folder.id).map(\.term) == ["ptychography"])
        #expect(try store.deleteVocabularyTerm(id: try #require(global.id)))
        #expect(try store.vocabularyTerms(folderID: nil).isEmpty)
    }

    // MARK: - Settings

    @Test func settingsFallBackToTheDocumentedDefaults() throws {
        #expect(try store.setting(.audioRetentionDays) == "30")
        #expect(try store.settingInt(.audioRetentionDays) == 30)
        #expect(try store.setting(.aiMode) == "manual")
        #expect(try store.setting(.transcribeBatchEngine) == "fluidaudio")
        #expect(try store.settingBool(.exportMarkdownOnComplete) == false)
        #expect(try store.settingBool(.onboardingCompleted) == false)
        // Two commands, not one: the pasted line is a slash command for a session you already have
        // open, the run line is a binary Mode B execs. Each default is right for its own job.
        #expect(try store.setting(.aiManualPasteCommand) == "/meetings {meeting_id}")
        #expect(try store.setting(.aiLocalAgentRunCommand) == #"claude -p "/meetings {meeting_id}""#)
        // No default, and none invented.
        #expect(try store.setting(.aiCloudBaseURL) == nil)
        #expect(try store.storedSettings().isEmpty)
    }

    @Test func settingsWriteReadAndResetToDefault() throws {
        try store.setSetting(.audioRetentionDays, "0")
        #expect(try store.settingInt(.audioRetentionDays) == 0)

        try store.setSetting(.onboardingCompleted, "true")
        #expect(try store.settingBool(.onboardingCompleted) == true)
        #expect(try store.storedSettings().count == 2)

        try store.setSetting(.audioRetentionDays, nil)
        #expect(try store.setting(.audioRetentionDays) == "30", "clearing restores the default, it does not store empty")

        // An unrecognised key is storable — `meetings config set` takes any string.
        try store.setSetting(SettingKey("some.future.key"), "value")
        #expect(try store.setting(SettingKey("some.future.key")) == "value")
    }
}
