import Foundation
import Testing

@testable import MeetingsCore

@Suite final class SearchTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = MeetingStore(dbPool: try MeetingsDatabase.open(at: directory.appendingPathComponent("store.db")))
    }

    deinit { TestStore.remove(directory) }

    /// Every document in the index, straight from the virtual table. Search cannot see an empty
    /// document or a stale one, so the only way to assert either is gone is to look at the rows.
    private func indexedTexts() throws -> [String] {
        try store.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM meetings_fts ORDER BY rowid")
        }
    }

    /// All four indexed kinds, each through the full insert / update / delete cycle. The index is
    /// maintained by triggers, so this is really a test that the triggers exist and fire — and a
    /// meeting missing from search looks exactly like a meeting that was never recorded.
    @Test func ftsSeesInsertsUpdatesAndDeletesForSegments() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        let segment = try store.insertSegment(
            TestStore.segment(meetingID: meeting.id, from: 0, to: 2_000, text: "ptychography throughput doubled", pass: .final)
        )

        #expect(try store.search(query: "ptychography").map(\.kind) == [.segment])
        #expect(try store.search(query: "ptychography").first?.meeting.id == meeting.id)

        try store.editSegment(id: try #require(segment.id), text: "diffraction throughput doubled")
        #expect(try store.search(query: "ptychography").isEmpty)
        #expect(try store.search(query: "diffraction").count == 1)

        try store.dbPool.write { db in
            try db.execute(sql: "DELETE FROM transcript_segments WHERE id = ?", arguments: [segment.id])
        }
        #expect(try store.search(query: "diffraction").isEmpty)
    }

    @Test func ftsSeesInsertsUpdatesAndDeletesForNotes() throws {
        let meeting = try store.createMeeting(TestStore.meeting())
        let note = try store.addNote(meetingID: meeting.id, tOffsetMs: 0, text: "chase the altinha invoice")

        #expect(try store.search(query: "altinha").map(\.kind) == [.note])

        try store.dbPool.write { db in
            try db.execute(sql: "UPDATE notes SET text = ? WHERE id = ?", arguments: ["chase the Airbus invoice", note.id])
        }
        #expect(try store.search(query: "altinha").isEmpty)
        #expect(try store.search(query: "Airbus").count == 1)

        try store.dbPool.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [note.id])
        }
        #expect(try store.search(query: "Airbus").isEmpty)
    }

    @Test func ftsSeesInsertsUpdatesAndDeletesForPrenotes() throws {
        let meeting = try store.createMeeting(TestStore.meeting(preNotes: "ask about ptychography funding"))
        #expect(try store.search(query: "funding").map(\.kind) == [.prenotes])

        try store.updateMeeting(id: meeting.id) { $0.preNotes = "ask about headcount instead" }
        #expect(try store.search(query: "funding").isEmpty)
        #expect(try store.search(query: "headcount").count == 1)

        try store.updateMeeting(id: meeting.id) { $0.preNotes = "" }
        #expect(try store.search(query: "headcount").isEmpty)

        try store.updateMeeting(id: meeting.id) { $0.preNotes = "back again" }
        #expect(try store.search(query: "back").count == 1)

        #expect(try store.deleteMeeting(id: meeting.id))
        #expect(try store.search(query: "back").isEmpty)
    }

    @Test func ftsSeesInsertsUpdatesAndDeletesForSummaries() throws {
        let meeting = try store.createMeeting(TestStore.meeting())
        #expect(try store.search(query: "shipped").isEmpty, "no summary is not an empty document")

        try store.updateMeeting(id: meeting.id) { $0.summary = "We shipped the recorder." }
        #expect(try store.search(query: "shipped").map(\.kind) == [.summary])

        try store.updateMeeting(id: meeting.id) { $0.summary = "We postponed the recorder." }
        #expect(try store.search(query: "shipped").isEmpty)
        #expect(try store.search(query: "postponed").count == 1)

        try store.updateMeeting(id: meeting.id) { $0.summary = nil }
        #expect(try store.search(query: "postponed").isEmpty)
    }

    @Test func searchReportsWhichKindMatchedAndAUsableSnippet() throws {
        let meeting = try store.createMeeting(TestStore.meeting(preNotes: "agenda: ptychography roadmap"))
        try store.updateMeeting(id: meeting.id) { $0.summary = "Agreed the ptychography roadmap slips a quarter." }
        try store.insertSegment(
            TestStore.segment(meetingID: meeting.id, from: 0, to: 2_000, text: "the ptychography work is behind", pass: .final)
        )
        try store.addNote(meetingID: meeting.id, tOffsetMs: 100, text: "ptychography: push back")

        let hits = try store.search(query: "ptychography")
        // Every indexed kind. `.title` cannot join them: a title match stands in for that meeting's
        // body hits rather than being listed beside them, so the five kinds never co-occur.
        #expect(Set(hits.map(\.kind)) == Set(SearchKind.allCases.filter { $0 != .title }))
        #expect(hits.allSatisfy { $0.meeting.id == meeting.id })
        #expect(hits.allSatisfy { $0.snippet.contains("«ptychography»") })
        #expect(Set(hits.map(\.id)).count == hits.count, "each hit is distinct")
    }

    // MARK: - Titles

    /// Searching a meeting by its name found nothing unless the name happened to be said out loud
    /// in the meeting, which is the one thing a search box is most obviously for.
    @Test func aMeetingIsFoundByItsOwnNameWithNothingElseMatching() throws {
        let meeting = try store.createMeeting(TestStore.meeting(title: "Ptychography roadmap"))
        try store.insertSegment(
            TestStore.segment(meetingID: meeting.id, from: 0, to: 1_000, text: "nothing relevant here", pass: .final)
        )

        let hits = try store.search(query: "ptychography")
        #expect(hits.count == 1)
        #expect(hits.first?.kind == .title)
        #expect(hits.first?.meeting.id == meeting.id)
        #expect(hits.first?.sourceID == meeting.id)
    }

    /// The rank. A title names the meeting; a transcript line is somewhere inside one.
    @Test func aTitleMatchOutranksABodyMatch() throws {
        try store.createMeeting(TestStore.meeting(title: "Unrelated", preNotes: "the altinha invoice again"))
        let named = try store.createMeeting(TestStore.meeting(title: "Altinha kickoff"))

        let hits = try store.search(query: "altinha")
        #expect(hits.count == 2)
        #expect(hits.first?.meeting.id == named.id)
        #expect(hits.map(\.kind) == [.title, .prenotes])
    }

    /// Two rows for one meeting is the same answer twice, and in the palette it costs the user a
    /// row that another meeting could have used.
    @Test func aMeetingMatchingOnBothItsTitleAndItsBodyAppearsOnce() throws {
        let meeting = try store.createMeeting(TestStore.meeting(title: "Cryo stage scheduling"))
        try store.updateMeeting(id: meeting.id) { $0.preNotes = "book the cryo stage" }
        try store.insertSegments((0..<5).map {
            TestStore.segment(meetingID: meeting.id, from: $0 * 100, to: $0 * 100 + 90,
                              text: "the cryo stage is booked", pass: .final)
        })

        let hits = try store.search(query: "cryo")
        #expect(hits.count == 1)
        #expect(hits.map(\.kind) == [.title])
        #expect(Set(hits.map(\.id)).count == hits.count)
    }

    /// The palette renders the snippet as the second line of every row, so a title hit with no
    /// snippet would be the strongest match and the one row that looked broken.
    @Test func aTitleHitCarriesTheTitleAsItsSnippetWithTheMatchMarked() throws {
        try store.createMeeting(TestStore.meeting(title: "Torch0 pipeline review"))

        #expect(try store.search(query: "pipeline").first?.snippet == "Torch0 «pipeline» review")
        #expect(try store.search(query: "PIPELINE").first?.snippet == "Torch0 «pipeline» review",
                "the marking follows the title's own casing, not the query's")
        #expect(try store.search(query: "torch0 review").first?.snippet == "«Torch0» pipeline «review»")
        // Overlapping tokens must not open a marker inside a marker: the palette parses «» by
        // alternating on each boundary, and a nested pair bolds exactly the wrong half.
        #expect(MeetingStore.markedTitle("Cryo stage", tokens: ["cryo", "cry"]) == "«Cryo» stage")
    }

    @Test func titleSearchIsScopedByFolderAndSharesTheLimit() throws {
        let torch0 = try store.createFolder(Folder(name: "Torch0"))
        try store.createMeeting(TestStore.meeting(title: "Standup one", folderID: torch0.id))
        try store.createMeeting(TestStore.meeting(title: "Standup two"))

        #expect(try store.search(query: "standup").count == 2)
        #expect(try store.search(query: "standup", folderID: torch0.id).count == 1)
        #expect(try store.search(query: "standup", limit: 1).count == 1)
        #expect(try store.search(query: "standup", limit: 0).isEmpty)
    }

    /// Tokens are ANDed across the title the same way they are inside one indexed document, so
    /// half a name is not a match.
    @Test func titleTokensAreAndedAndMatchInsideAWord() throws {
        try store.createMeeting(TestStore.meeting(title: "Mater-AI intro"))

        #expect(try store.search(query: "mater intro").count == 1)
        #expect(try store.search(query: "mater kickoff").isEmpty, "tokens are ANDed")
        #expect(try store.search(query: "mater-ai").count == 1)
        #expect(try store.search(query: "ater").count == 1, "a title is matched on substrings")
    }

    @Test func searchScopesToAFolderAndRespectsTheLimit() throws {
        let torch0 = try store.createFolder(Folder(name: "Torch0"))
        let airbus = try store.createFolder(Folder(name: "Airbus"))
        try store.createMeeting(TestStore.meeting(title: "A", folderID: torch0.id, preNotes: "shared keyword one"))
        try store.createMeeting(TestStore.meeting(title: "B", folderID: torch0.id, preNotes: "shared keyword two"))
        try store.createMeeting(TestStore.meeting(title: "C", folderID: airbus.id, preNotes: "shared keyword three"))

        #expect(try store.search(query: "keyword").count == 3)
        #expect(try store.search(query: "keyword", folderID: torch0.id).count == 2)
        #expect(try store.search(query: "keyword", folderID: airbus.id).count == 1)
        #expect(try store.search(query: "keyword", limit: 2).count == 2)
    }

    /// FTS5's MATCH argument is a query language, so anything a user might reasonably type — a
    /// quote, a stray asterisk, the word OR — is a syntax error rather than zero results. A search
    /// box that throws on an apostrophe is broken, so none of these may throw.
    @Test(arguments: [
        "\"",
        "*",
        "a OR",
        "NEAR",
        "AND OR NOT",
        "^foo",
        "(unbalanced",
        "column:value",
        "-",
        "\"unclosed phrase",
        "NEAR(a b, 3)",
        "Ma'agan Michael",
        "  ",
        "",
        "😀",
        "a\u{0}b",
        "\u{0}",
    ]) func hostileQueriesDoNotThrow(query: String) throws {
        let meeting = try store.createMeeting(TestStore.meeting(preNotes: "a perfectly ordinary pre-note"))
        try store.insertSegment(
            TestStore.segment(meetingID: meeting.id, from: 0, to: 1_000, text: "nothing special was said", pass: .final)
        )
        // The contract is "does not throw". Whether it matches anything is the user's problem.
        _ = try store.search(query: query)
    }

    @Test func emptyQueriesShortCircuitRatherThanHitTheIndex() {
        #expect(MeetingStore.ftsQuery("") == nil)
        #expect(MeetingStore.ftsQuery("   \n\t ") == nil)
        #expect(MeetingStore.ftsQuery("hello") == "\"hello\"")
        #expect(MeetingStore.ftsQuery("a OR b") == "\"a\" \"OR\" \"b\"")
        #expect(MeetingStore.ftsQuery("say \"hi\"") == "\"say\" \"\"\"hi\"\"\"")
        // A NUL ends SQLite's C string, so quoting it through would produce an expression that
        // MATCH reports as `unterminated string` — the one input that made this throw.
        #expect(MeetingStore.ftsQuery("a\u{0}b") == "\"a\" \"b\"")
        #expect(MeetingStore.ftsQuery("\u{0}") == nil)
    }

    /// Operators are stripped of their meaning, which is the whole point of quoting: `OR` searches
    /// for the word "or", and the tokens are ANDed.
    @Test func operatorsAreTreatedAsWords() throws {
        try store.createMeeting(TestStore.meeting(title: "A", preNotes: "ship the recorder or the CLI"))
        try store.createMeeting(TestStore.meeting(title: "B", preNotes: "ship the app"))

        #expect(try store.search(query: "ship").count == 2)
        #expect(try store.search(query: "ship recorder").count == 1, "tokens are ANDed")
        #expect(try store.search(query: "recorder or CLI").count == 1)
        #expect(try store.search(query: "recorder OR app").isEmpty, "OR is a word here, not an operator")
    }

    /// The index holds no zero-length documents, for any kind. Beyond being meaningless, an empty
    /// document drags down bm25's average document length and skews the ranking of every other
    /// query in the store.
    @Test func emptyTextIsNeverIndexed() throws {
        let meeting = try store.createMeeting(TestStore.meeting())
        let segment = try store.insertSegment(
            TestStore.segment(meetingID: meeting.id, from: 0, to: 1_000, text: "said something", pass: .final)
        )
        try store.addNote(meetingID: meeting.id, tOffsetMs: 0, text: "wrote something")
        try store.updateMeeting(id: meeting.id) { $0.preNotes = "planned something" }
        #expect(try indexedTexts().count == 3)

        try store.editSegment(id: try #require(segment.id), text: "")
        try store.dbPool.write { db in try db.execute(sql: "UPDATE notes SET text = ''") }
        try store.updateMeeting(id: meeting.id) { $0.preNotes = "" }

        #expect(try indexedTexts() == [], "cleared text leaves no index row behind")
    }

    /// The triggers are the safety net so no write path can forget, and `editSegment` already saves
    /// the whole record — so the moment anything moves a segment or note between meetings, a
    /// text-only trigger would leave the index attributing those words to the wrong meeting.
    @Test func movingASegmentOrNoteBetweenMeetingsMovesItsIndexRow() throws {
        let from = try store.createMeeting(TestStore.meeting(title: "From"))
        let to = try store.createMeeting(TestStore.meeting(title: "To"))
        let segment = try store.insertSegment(
            TestStore.segment(meetingID: from.id, from: 0, to: 1_000, text: "ptychography", pass: .final)
        )
        let note = try store.addNote(meetingID: from.id, tOffsetMs: 0, text: "altinha")

        try store.dbPool.write { db in
            try db.execute(sql: "UPDATE transcript_segments SET meeting_id = ? WHERE id = ?", arguments: [to.id, segment.id])
            try db.execute(sql: "UPDATE notes SET meeting_id = ? WHERE id = ?", arguments: [to.id, note.id])
        }

        #expect(try store.search(query: "ptychography").map(\.meeting.id) == [to.id])
        #expect(try store.search(query: "altinha").map(\.meeting.id) == [to.id])
    }

    /// Deleting a meeting takes its segments and notes with it by foreign-key cascade, and the
    /// cascade fires their delete triggers — which is what lets the meeting's own trigger drop just
    /// its two rows instead of scanning the whole index.
    @Test func deletingAMeetingLeavesNothingBehindInTheIndex() throws {
        let kept = try store.createMeeting(TestStore.meeting(title: "Kept", preNotes: "keyword kept"))
        let doomed = try store.createMeeting(TestStore.meeting(title: "Doomed", preNotes: "keyword doomed"))
        try store.updateMeeting(id: doomed.id) { $0.summary = "keyword summary" }
        try store.insertSegments((0..<20).map {
            TestStore.segment(meetingID: doomed.id, from: $0 * 100, to: $0 * 100 + 90, text: "keyword segment \($0)", pass: .final)
        })
        try store.addNote(meetingID: doomed.id, tOffsetMs: 0, text: "keyword note")
        #expect(try indexedTexts().count == 24)

        #expect(try store.deleteMeeting(id: doomed.id))
        #expect(try indexedTexts() == ["keyword kept"])
        #expect(try store.search(query: "keyword").map(\.meeting.id) == [kept.id])
    }

    /// `search(limit:)` is agent-facing, and SQLite reads a negative LIMIT as "no limit" — so an
    /// off-by-one in a caller would hand back the whole store instead of nothing.
    @Test func aNegativeLimitReturnsNothingRatherThanEverything() throws {
        try store.createMeeting(TestStore.meeting(preNotes: "keyword one"))
        try store.createMeeting(TestStore.meeting(preNotes: "keyword two"))
        #expect(try store.search(query: "keyword").count == 2)
        #expect(try store.search(query: "keyword", limit: 0).isEmpty)
        #expect(try store.search(query: "keyword", limit: -1).isEmpty)
    }

    @Test func searchIsAccentAndCaseInsensitive() throws {
        try store.createMeeting(TestStore.meeting(preNotes: "call with Sofia Nunes about Ma'agan Michael"))
        #expect(try store.search(query: "nunes").count == 1)
        #expect(try store.search(query: "NUNES").count == 1)
        #expect(try store.search(query: "maagan").isEmpty)
        #expect(try store.search(query: "Ma'agan").count == 1)
    }

    /// The ⌘K palette's arrow keys. Return opens whatever this index points at, so an index that
    /// runs off either end of the list opens the wrong meeting or none at all.
    @Test func theArrowKeysStopAtBothEndsOfTheResultList() {
        #expect(SearchSelection.moved(0, by: 1, count: 3) == 1)
        #expect(SearchSelection.moved(1, by: 1, count: 3) == 2)
        #expect(SearchSelection.moved(2, by: 1, count: 3) == 2, "the down arrow must not run past the last hit")
        #expect(SearchSelection.moved(1, by: -1, count: 3) == 0)
        #expect(SearchSelection.moved(0, by: -1, count: 3) == 0, "nor the up arrow past the first")
    }

    /// An empty list has no row to be on. A held-down arrow over "No matches" that leaves the index
    /// at 7 would then open the eighth hit of the *next* search, a keystroke after it appeared.
    @Test func theHighlightHasNowhereToGoInAnEmptyResultList() {
        #expect(SearchSelection.moved(0, by: 1, count: 0) == 0)
        #expect(SearchSelection.moved(5, by: -1, count: 0) == 0)
        #expect(SearchSelection.moved(0, by: 4, count: 3) == 2, "a jump lands inside the list too")
    }
}
