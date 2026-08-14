import Foundation
import GRDB

public enum StoreError: Error, Equatable, LocalizedError {
    case meetingNotFound(String)
    case folderNotFound(String)
    case segmentNotFound(Int64)
    /// The operation is legal, just not from the state the row is in — a transcript edit while the
    /// meeting is still recording, for instance. Maps to CLI exit code 3.
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let ref): "No meeting with id \(ref)"
        case .folderNotFound(let ref): "No folder \(ref)"
        case .segmentNotFound(let id): "No transcript segment with id \(id)"
        case .invalidState(let reason): reason
        }
    }
}

/// A meeting sitting at `ready` with nobody having written it up yet, and how long it has been
/// sitting there. In the default manual AI mode nothing writes summaries on its own, so this list
/// is the only thing between you and fifty transcribed meetings you never processed.
public struct NeedsWriteUp: Sendable, Identifiable {
    public let meeting: Meeting
    /// Seconds since the meeting happened. Nil when it has neither a start nor a scheduled time,
    /// which is legal for an imported row.
    public let age: TimeInterval?

    public var id: String { meeting.id }
}

/// The single write surface over the store. Not an actor: `DatabasePool` is already thread-safe and
/// serialises writes itself, and wrapping it in an actor would only add a hop and make every read
/// `await` for no gain.
///
/// Every mutating method posts `StoreChange` **after** the transaction commits. Posting inside the
/// transaction would have the other process refetch state that has not landed yet.
public final class MeetingStore: Sendable {
    public let dbPool: DatabasePool

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Opens the shared store at `Paths.databaseURL` (or `$MEETINGS_DB`).
    public convenience init() throws {
        self.init(dbPool: try MeetingsDatabase.open())
    }

    // MARK: - Meetings

    @discardableResult
    public func createMeeting(_ meeting: Meeting) throws -> Meeting {
        let meeting = meeting.sanitized()
        try dbPool.write { try meeting.insert($0) }
        StoreChange.post(storePath: dbPool.path, meetingID: meeting.id)
        return meeting
    }

    public func meeting(id: String) throws -> Meeting? {
        try dbPool.read { try Meeting.fetchOne($0, key: id) }
    }

    /// The row this machine materialised for that event, if there is one.
    ///
    /// A bundle re-import can legitimately add a second row carrying the same `calendar_event_id`
    /// (never overwrites), so this prefers the locally materialised row over an imported
    /// copy, and the oldest one after that. Without the ordering a restore would silently start
    /// redirecting `cal:` writes onto the imported duplicate.
    public func meeting(calendarEventID: String) throws -> Meeting? {
        try dbPool.read { db in
            try Meeting.fetchOne(
                db,
                sql: """
                    SELECT * FROM meetings WHERE calendar_event_id = ?
                    ORDER BY (imported_from IS NULL) DESC, rowid ASC
                    """,
                arguments: [calendarEventID]
            )
        }
    }

    /// Whole-record save. Used by import and by anything holding a row it fetched a moment ago.
    /// Prefer ``updateMeeting(id:_:)`` when the app and the CLI might both be writing.
    public func updateMeeting(_ meeting: Meeting) throws {
        let meeting = meeting.sanitized()
        try dbPool.write { try meeting.update($0) }
        committed(meeting.id, state: meeting.state)
    }

    /// Read-modify-write inside one transaction. The whole point: the app and the CLI are two
    /// processes, and a `summary set` that fetched before the app's `state` change and saved after
    /// it would quietly undo it.
    @discardableResult
    public func updateMeeting(id: String, _ mutate: @Sendable (inout Meeting) throws -> Void) throws -> Meeting {
        let updated = try dbPool.write { db -> Meeting in
            guard var meeting = try Meeting.fetchOne(db, key: id) else {
                throw StoreError.meetingNotFound(id)
            }
            try mutate(&meeting)
            meeting = meeting.sanitized()
            try meeting.update(db)
            return meeting
        }
        committed(id, state: updated.state)
        return updated
    }

    /// After a committed write to a meeting row: announce it, and run
    /// markdown-on-complete if this write is what left the meeting `complete`.
    ///
    /// Wired here rather than at each call site because "everywhere a meeting reaches complete" is
    /// not a list anybody keeps up to date — `summary set` had been missing it since the export was
    /// written. Every transition into `complete` is a committed update of the row (`summary set`,
    /// the cloud enhancer, the batch re-pass on a meeting that already has a summary), so one hook
    /// on the update path covers all of them. The two paths that *assemble* a complete meeting from
    /// several statements — `MeetingCreate` and a bundle import — export at the end of assembly
    /// instead, because at the moment their row lands the transcript rows are not in yet and the
    /// export would write a transcript.md with nothing in it.
    ///
    /// Best-effort on purpose: the write has already committed, and an unwritable `~/Meetings`
    /// must not turn a successful `summary set` into a failure.
    private func committed(_ meetingID: String, state: MeetingState) {
        StoreChange.post(storePath: dbPool.path, meetingID: meetingID)
        guard state == .complete else { return }
        do {
            _ = try MarkdownExport.exportIfEnabled(meetingID: meetingID, store: self)
        } catch {
            // Best-effort, but not silent. Somebody who turned the markdown mirror on and then
            // pointed it at a volume that is not mounted would otherwise find out by noticing, some
            // weeks later, that it stopped.
            FileHandle.standardError.write(Data(
                "Meetings: markdown export for \(meetingID) failed: \(error.localizedDescription)\n".utf8))
        }
    }

    /// The meeting, everything hanging off it, and its audio. There is no undo and no trash.
    ///
    /// The database half is one transaction and mostly the schema's own doing: `transcript_segments`,
    /// `notes` and `transcript_issues` are all `ON DELETE CASCADE` on `meetings(id)`, and SQLite
    /// fires a child table's delete trigger for a cascaded row exactly as it does for a direct one —
    /// so the FTS index loses the meeting's segments and notes along with the two rows
    /// `meeting_ad_fts` drops itself. That is load-bearing rather than incidental: a stale index row
    /// means a deleted meeting keeps coming back out of `meetings search`, quoting a transcript
    /// nothing can open. ``SearchTests`` and ``DeleteMeetingTests`` both hold it down.
    ///
    /// The audio is the half the schema cannot help with. It is a directory on disk with no foreign
    /// key to cascade, and the only thing that knew where it was is the row being deleted. Left
    /// behind it is unreclaimable: the retention sweep purges audio a row still *points at*, so a
    /// deleted meeting's WAVs would sit under `<root>/audio` until somebody found them by hand.
    ///
    /// Refused while the meeting is `recording` or `transcribing` — the two states the retention
    /// sweep refuses for the same reason. One is having audio written into it right now and the
    /// other is having it read; deleting the row under either leaves a recorder writing WAVs into a
    /// directory for a meeting that no longer exists, and a `stop()` that can only fail.
    ///
    /// Returns false for a meeting that is not there. A delete of something already gone is the
    /// outcome the caller wanted, not a failure — the CLI turns the false into its own exit 2.
    ///
    /// `audioRoot` is a parameter for the reason ``Retention`` takes one: `Paths` reads the process
    /// environment, and a test must not mutate that out from under the rest of the suite.
    @discardableResult
    public func deleteMeeting(id: String, audioRoot: URL = Paths.audioRoot) throws -> Bool {
        // The files go *after* the commit, never before. A crash in between leaks a directory nobody
        // points at, which costs disk and nothing else; the other order deletes the audio of a
        // meeting whose row then survives the failed transaction.
        let deleted = try dbPool.write { db -> Meeting? in
            guard let meeting = try Meeting.fetchOne(db, key: id) else { return nil }
            guard meeting.state != .recording, meeting.state != .transcribing else {
                throw StoreError.invalidState(
                    "\(meeting.title) is still \(meeting.state.rawValue), so it cannot be deleted yet."
                )
            }
            try meeting.delete(db)
            // In the same transaction as the delete: a tombstone written afterwards could be lost
            // to a crash in between, and the row would come back on the next calendar sync.
            try Self.dismissCalendarEvent(of: meeting, in: db)
            return meeting
        }
        guard let deleted else { return false }
        Self.removeAudio(of: deleted, audioRoot: audioRoot)
        StoreChange.post(storePath: dbPool.path, meetingID: id)
        return true
    }

    /// Remembers that this calendar meeting's row was deleted, so ``CalendarSync`` does not make it
    /// again while the event is still inside the look-ahead window.
    ///
    /// Only rows this machine materialised from the calendar. An imported row is a copy of somebody
    /// else's meeting and deleting it says nothing about whether you want the local one.
    ///
    /// A row with no dates at all cannot be in a look-ahead window, so its tombstone would never be
    /// consulted; `until` falls back to the delete instant rather than growing a special case.
    private static func dismissCalendarEvent(of meeting: Meeting, in db: Database) throws {
        guard let eventID = meeting.calendarEventID, meeting.importedFrom == nil else { return }
        let until = meeting.scheduledEnd ?? meeting.scheduledStart ?? Date()
        try db.execute(
            sql: """
                INSERT INTO calendar_dismissals(calendar_event_id, until) VALUES (?, ?)
                ON CONFLICT(calendar_event_id) DO UPDATE SET until = excluded.until
                """,
            arguments: [eventID, Int(until.timeIntervalSince1970)]
        )
    }

    /// The calendar events whose rows were deleted and must not be made again, pruning the ones
    /// whose event has already ended on the way through — that prune is the only thing keeping the
    /// table from holding one row per deleted meeting for the life of the store.
    ///
    /// It writes, so it is not a read, but it posts no ``StoreChange``: nothing a user can see has
    /// changed, and a post here would have the window refresh, sync, prune and post again.
    public func dismissedCalendarEvents(now: Date = Date()) throws -> Set<String> {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM calendar_dismissals WHERE until <= ?",
                arguments: [Int(now.timeIntervalSince1970)]
            )
            return Set(try String.fetchAll(db, sql: "SELECT calendar_event_id FROM calendar_dismissals"))
        }
    }

    /// Both places a meeting's audio can be, because they are not always the same place.
    ///
    /// Every writer puts the WAVs in `<audioRoot>/<meeting id>/`, and normally records that path on
    /// the row. But a retention purge nulls `audio_path` while a purge interrupted between the two
    /// steps leaves the files, and an imported meeting has its WAVs on disk before the transcriber
    /// writes the path. Removing only what the row claims strands the first two; removing only the
    /// derived directory would miss a row pointing somewhere else entirely.
    ///
    /// The recorded path goes through ``Retention/safeAudioDirectory(_:audioRoot:)`` rather than a
    /// second copy of that check: `audio_path` is a string two processes and an importer can write,
    /// this calls `removeItem`, and a row saying `/Users/yoelgal` must delete nothing at all.
    private static func removeAudio(of meeting: Meeting, audioRoot: URL) {
        let derived = audioRoot.appendingPathComponent(meeting.id, isDirectory: true).standardizedFileURL
        let recorded = meeting.audioPath.flatMap { Retention.safeAudioDirectory($0, audioRoot: audioRoot) }
        for directory in Set([derived] + (recorded.map { [$0] } ?? [])) {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch let error as NSError where error.code == NSFileNoSuchFileError {
                // The ordinary case, twice over: a meeting that was never recorded has no directory
                // at all, and one whose audio the retention sweep already purged has none either.
            } catch {
                // Best-effort, but not silent. The row that named this directory has just gone, so
                // nothing will ever look for it again — a permission failure here is disk lost for
                // good, and the user should hear about it the first time rather than the fiftieth.
                let sentence = "Meetings: audio for deleted meeting \(meeting.id) could not be "
                    + "removed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(sentence.utf8))
            }
        }
    }

    /// Newest first. The sort key is `coalesce(started_at, scheduled_start)` — what actually
    /// happened, falling back to what was meant to — and ties break on `id` so the order is stable
    /// across fetches. SQLite sorts NULL lowest, so a row with neither date lands at the bottom
    /// rather than pretending to be today's meeting.
    public func allMeetings(limit: Int? = nil) throws -> [Meeting] {
        try meetings(where: nil, arguments: [], limit: limit)
    }

    /// `folderID` of nil means the Unfiled list, not "every folder" — use ``allMeetings(limit:)``
    /// for that.
    public func meetings(folderID: String?, limit: Int? = nil) throws -> [Meeting] {
        if let folderID {
            return try meetings(where: "folder_id = ?", arguments: [folderID], limit: limit)
        }
        return try meetings(where: "folder_id IS NULL", arguments: [], limit: limit)
    }

    public func meetings(state: MeetingState, limit: Int? = nil) throws -> [Meeting] {
        try meetings(where: "state = ?", arguments: [state.rawValue], limit: limit)
    }

    /// Everything at `ready`, oldest first — the one that has been waiting longest is the one you
    /// are most likely to have forgotten.
    public func needsWriteUp(now: Date = Date()) throws -> [NeedsWriteUp] {
        let rows = try dbPool.read { db in
            try Meeting.fetchAll(db, sql: """
                SELECT * FROM meetings
                WHERE state = ?
                ORDER BY coalesce(started_at, scheduled_start) ASC, id ASC
                """, arguments: [MeetingState.ready.rawValue])
        }
        return rows.map { NeedsWriteUp(meeting: $0, age: $0.sortDate.map { now.timeIntervalSince($0) }) }
    }

    private func meetings(where clause: String?, arguments: StatementArguments, limit: Int?) throws -> [Meeting] {
        var sql = "SELECT * FROM meetings"
        if let clause { sql += " WHERE \(clause)" }
        sql += " ORDER BY coalesce(started_at, scheduled_start) DESC, id DESC"
        var arguments = arguments
        if let limit {
            sql += " LIMIT ?"
            arguments += [limit]
        }
        return try dbPool.read { try Meeting.fetchAll($0, sql: sql, arguments: arguments) }
    }

    // MARK: - Folders

    /// Folder names are unique, case-insensitively — `folder(named:)` is how `meetings move x
    /// --folder torch0` resolves, and two folders called "Torch0" would make that ambiguous. The
    /// check is here as well as in the index so a legitimate CLI call gets a sentence it can print
    /// rather than a leaked `SQLITE_CONSTRAINT`.
    @discardableResult
    public func createFolder(_ folder: Folder) throws -> Folder {
        let folder = folder.sanitized()
        try dbPool.write { db in
            try Self.assertFolderNameIsFree(db, name: folder.name, excludingID: nil)
            try folder.insert(db)
        }
        StoreChange.post(storePath: dbPool.path)
        return folder
    }

    public func folders() throws -> [Folder] {
        try dbPool.read { db in
            try Folder.fetchAll(db, sql: "SELECT * FROM folders ORDER BY sort_order ASC, name ASC")
        }
    }

    public func folder(id: String) throws -> Folder? {
        try dbPool.read { try Folder.fetchOne($0, key: id) }
    }

    /// Case-insensitive, matching the unique index — `meetings move x --folder torch0` finds the
    /// folder the user actually called "Torch0".
    public func folder(named name: String) throws -> Folder? {
        try dbPool.read { db in
            try Folder.fetchOne(db, sql: "SELECT * FROM folders WHERE name = ? COLLATE NOCASE", arguments: [name])
        }
    }

    /// A rename into a name somebody else already has fails the same way a create does, and for the
    /// same reason.
    public func updateFolder(_ folder: Folder) throws {
        let folder = folder.sanitized()
        try dbPool.write { db in
            try Self.assertFolderNameIsFree(db, name: folder.name, excludingID: folder.id)
            try folder.update(db)
        }
        StoreChange.post(storePath: dbPool.path)
    }

    private static func assertFolderNameIsFree(_ db: Database, name: String, excludingID: String?) throws {
        let clash = try String.fetchOne(db, sql: """
            SELECT id FROM folders WHERE name = ? COLLATE NOCASE AND id IS NOT ?
            """, arguments: [name, excludingID])
        if clash != nil {
            throw StoreError.invalidState("A folder called \"\(name)\" already exists")
        }
    }

    /// Meetings in the folder become unfiled; folder-scoped vocabulary goes with the folder.
    @discardableResult
    public func deleteFolder(id: String) throws -> Bool {
        let deleted = try dbPool.write { try Folder.deleteOne($0, key: id) }
        if deleted { StoreChange.post(storePath: dbPool.path) }
        return deleted
    }

    // MARK: - Transcript segments

    @discardableResult
    public func insertSegment(_ segment: TranscriptSegment) throws -> TranscriptSegment {
        let inserted = try dbPool.write { db -> TranscriptSegment in
            var segment = segment.sanitized()
            try segment.insert(db)
            return segment
        }
        StoreChange.post(storePath: dbPool.path, meetingID: inserted.meetingID)
        return inserted
    }

    /// One transaction for the batch. The live path inserts a segment at a time; import inserts
    /// hundreds, and doing that as hundreds of transactions is how you make a restore take minutes.
    @discardableResult
    public func insertSegments(_ segments: [TranscriptSegment]) throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }
        let inserted = try dbPool.write { db -> [TranscriptSegment] in
            try segments.map { segment in
                var segment = segment.sanitized()
                try segment.insert(db)
                return segment
            }
        }
        for meetingID in Set(inserted.map(\.meetingID)) {
            StoreChange.post(storePath: dbPool.path, meetingID: meetingID)
        }
        return inserted
    }

    /// Grows a live segment rather than starting a new one — the live transcript's way of saying
    /// "this is more of the same phrase".
    ///
    /// Live text arrives a few words at a time because it has to (it has to be on screen inside
    /// a second, and a second is less than a sentence takes to say). Writing each burst as its own
    /// row is what made the window read as "sophia can you" / "confirm" / "the". Appending to the
    /// row instead costs no latency at all: the words appear when they appeared before, they simply
    /// land in the phrase they belong to.
    ///
    /// Only ever applied to an unedited `live` row: a correction is the user's text and a `final`
    /// row belongs to the batch pass.
    @discardableResult
    public func extendSegment(id: Int64, appending text: String, tEndMs: Int) throws -> TranscriptSegment {
        let updated = try dbPool.write { db -> TranscriptSegment in
            guard var segment = try TranscriptSegment.fetchOne(db, key: id) else {
                throw StoreError.segmentNotFound(id)
            }
            guard segment.pass == .live, !segment.edited else {
                throw StoreError.invalidState("Only an unedited live segment can be extended")
            }
            segment.text = "\(segment.text) \(text.withoutNULs)"
            segment.tEndMs = max(segment.tEndMs, tEndMs)
            try segment.update(db)
            return segment
        }
        StoreChange.post(storePath: dbPool.path, meetingID: updated.meetingID)
        return updated
    }

    /// Ordered by start offset, both channels interleaved unless one is asked for. Ties break on
    /// `id`, so mic and system segments that begin on the same millisecond keep a stable order.
    public func segments(meetingID: String, channel: Channel? = nil) throws -> [TranscriptSegment] {
        try dbPool.read { try Self.fetchSegments($0, meetingID: meetingID, channel: channel) }
    }

    /// A manual correction. Marks the row `edited`, which is what keeps a re-transcription from
    /// throwing the correction away.
    ///
    /// Only legal at `ready` or `complete`: during recording the batch pass replaces live rows
    /// wholesale and the edit would silently vanish.
    @discardableResult
    public func editSegment(id: Int64, text: String) throws -> TranscriptSegment {
        let updated = try dbPool.write { db -> TranscriptSegment in
            guard var segment = try TranscriptSegment.fetchOne(db, key: id) else {
                throw StoreError.segmentNotFound(id)
            }
            guard let meeting = try Meeting.fetchOne(db, key: segment.meetingID) else {
                throw StoreError.meetingNotFound(segment.meetingID)
            }
            guard meeting.state == .ready || meeting.state == .complete else {
                throw StoreError.invalidState(
                    "Transcript edits are only allowed once a meeting is ready or complete (this one is \(meeting.state.rawValue))"
                )
            }
            segment.text = text.withoutNULs
            segment.edited = true
            try segment.update(db)
            return segment
        }
        StoreChange.post(storePath: dbPool.path, meetingID: updated.meetingID)
        return updated
    }

    // MARK: - Notes

    /// Verbatim insert, anchor included. The import path uses this; live note-taking uses
    /// ``addNote(meetingID:tOffsetMs:text:)``.
    @discardableResult
    public func insertNote(_ note: Note) throws -> Note {
        let inserted = try dbPool.write { db -> Note in
            var note = note.sanitized()
            try note.insert(db)
            return note
        }
        StoreChange.post(storePath: dbPool.path, meetingID: inserted.meetingID)
        return inserted
    }

    /// Anchors the note to the transcript as it stands right now, using the same rule the batch
    /// re-pass uses to remap it later. One rule, one implementation — a note must not move just
    /// because the final pass ran.
    @discardableResult
    public func addNote(meetingID: String, tOffsetMs: Int, text: String) throws -> Note {
        let inserted = try dbPool.write { db -> Note in
            let segments = try Self.fetchSegments(db, meetingID: meetingID, channel: nil)
            var note = Note(
                meetingID: meetingID,
                tOffsetMs: tOffsetMs,
                anchorSegmentID: Self.anchorSegmentID(forOffsetMs: tOffsetMs, in: segments),
                text: text.withoutNULs
            )
            try note.insert(db)
            return note
        }
        StoreChange.post(storePath: dbPool.path, meetingID: meetingID)
        return inserted
    }

    public func notes(meetingID: String) throws -> [Note] {
        try dbPool.read { try Self.fetchNotes($0, meetingID: meetingID) }
    }

    // MARK: - The batch re-pass

    /// Replaces the machine-written transcript with the batch pass's output, in one transaction.
    ///
    /// The rules, in order:
    /// 1. Segments marked `edited` are preserved verbatim — never deleted, never rewritten. A
    ///    correction you typed survives every re-transcription.
    /// 2. Every unedited segment goes, whichever pass wrote it. Deleting only `pass = 'live'` rows
    ///    would work once and duplicate the whole transcript the second time this ran, and this
    ///    runs a second time whenever a meeting is re-transcribed.
    /// 3. The new segments land as `pass = 'final'`.
    /// 4. A new segment **wholly covered** by a preserved correction on the same channel is dropped:
    ///    the machine just re-transcribed audio the user has already fixed, and keeping both would
    ///    put the uncorrected words back into the transcript alongside the correction — which is the
    ///    failure that poisons every summary downstream, silently and confidently.
    ///    The correction owns its span, and *only* its span: a segment that merely overlaps an edge
    ///    survives. Dropping on any overlap meant a one-second correction deleted the thirty-second
    ///    segment it sat inside — twenty-nine seconds nobody had corrected, gone. Covered means
    ///    `new.start >= edited.start && new.end <= edited.end`. The cost is a few duplicated words
    ///    where a correction straddles a new boundary, which is visible and fixable; the other way
    ///    round loses speech silently.
    /// 5. Surviving edited rows become `pass = 'final'` too. After a batch pass every row is part of
    ///    the final transcript by definition, and a `live` row left in a finished
    ///    transcript is dropped by any consumer filtering on `pass`. Only the *text* of a correction
    ///    is preserved verbatim; its pass label is bookkeeping.
    /// 6. Every note's anchor is remapped against the resulting transcript.
    /// 7. The meeting moves to `ready` — unless it already has a summary, in which case it is
    ///    `complete` by definition and knocking it back would be a lie.
    ///
    /// `channels` is the set the pass actually read. A channel outside it keeps every row it has,
    /// including its live ones: when the batch pass cannot open `mic.wav`, the rough live text of
    /// your own voice is the only record of your half of the meeting, and replacing it with nothing
    /// destroys the thing the user could still read. The failure is recorded separately
    /// (``recordTranscriptIssue(_:)``) so it is visible rather than merely survivable.
    @discardableResult
    public func replaceLiveSegments(
        meetingID: String,
        with finalSegments: [TranscriptSegment],
        channels: Set<Channel> = Set(Channel.allCases)
    ) throws -> [TranscriptSegment] {
        let (segments, state) = try dbPool.write { db -> ([TranscriptSegment], MeetingState) in
            guard var meeting = try Meeting.fetchOne(db, key: meetingID) else {
                throw StoreError.meetingNotFound(meetingID)
            }

            for channel in channels.sorted(by: { $0.rawValue < $1.rawValue }) {
                try db.execute(
                    sql: """
                        DELETE FROM transcript_segments
                        WHERE meeting_id = ? AND edited = 0 AND channel = ?
                        """,
                    arguments: [meetingID, channel.rawValue]
                )
            }

            for segment in finalSegments {
                var segment = segment.sanitized()
                segment.id = nil
                segment.meetingID = meetingID
                segment.pass = .final
                segment.edited = false
                try segment.insert(db)
            }

            // One indexed range delete per correction, rather than one correlated subquery over the
            // whole transcript: there are a handful of corrections and there can be thousands of
            // segments, and doing it the other way round is quadratic in the segment count.
            //
            // Containment, not overlap. A long correction still swallows several machine segments —
            // the user corrected that stretch of audio, so that stretch is theirs — but a machine
            // segment that starts before the correction, or runs past its end, carries speech from
            // outside the corrected span and is kept.
            let corrections = try TranscriptSegment.fetchAll(db, sql: """
                SELECT * FROM transcript_segments WHERE meeting_id = ? AND edited = 1
                """, arguments: [meetingID])
            for correction in corrections {
                try db.execute(sql: """
                    DELETE FROM transcript_segments
                    WHERE meeting_id = ? AND edited = 0 AND channel = ?
                      AND t_start_ms >= ? AND t_end_ms <= ?
                    """, arguments: [meetingID, correction.channel.rawValue, correction.tStartMs, correction.tEndMs])
            }

            try db.execute(
                sql: "UPDATE transcript_segments SET pass = 'final' WHERE meeting_id = ? AND edited = 1",
                arguments: [meetingID]
            )

            let all = try Self.fetchSegments(db, meetingID: meetingID, channel: nil)
            for note in try Self.fetchNotes(db, meetingID: meetingID) {
                let anchor = Self.anchorSegmentID(forOffsetMs: note.tOffsetMs, in: all)
                guard anchor != note.anchorSegmentID, let noteID = note.id else { continue }
                // Targeted update rather than a whole-record save: rewriting `text` here would fire
                // the FTS trigger for a value that did not change.
                try db.execute(
                    sql: "UPDATE notes SET anchor_segment_id = ? WHERE id = ?",
                    arguments: [anchor, noteID]
                )
            }

            let hasSummary = !(meeting.summary ?? "").isEmpty
            let newState: MeetingState = hasSummary ? .complete : .ready
            if meeting.state != newState {
                meeting.state = newState
                try meeting.update(db)
            }
            return (all, newState)
        }
        committed(meetingID, state: state)
        return segments
    }

    /// The anchor rule, in one place.
    ///
    /// Containment first: the segment whose `[t_start_ms, t_end_ms]` covers the offset is the thing
    /// that was being said when you typed, even if some later segment happens to *begin* closer.
    /// Only when nothing contains the offset does distance decide it. Nil is returned exactly once:
    /// when the meeting has no segments at all.
    ///
    /// A user's correction wins over a machine segment covering the same instant. The batch re-pass
    /// only drops a machine segment a correction wholly covers, so the machine's retake of a span
    /// that merely straddles the correction's edge legitimately survives alongside it — and when
    /// both cover the note's offset, the words the user typed are the better anchor of the two.
    ///
    /// Distance is to the nearest **edge** of a segment, not to its start. Measuring from the start
    /// makes the bias grow with how long the previous person talked: a note typed 100 ms after a
    /// one-minute monologue ends anchors to whoever speaks next, 900 ms later — a sentence nobody
    /// had said when you typed. One reading is "distance to `t_start_ms`"; the other is the
    /// "nearest transcript segment", and nearest to the segment is what that means.
    ///
    /// The arithmetic is in `Double` because the subtraction is not: a corrupt import or a bad clock
    /// conversion carrying an extreme `t_start_ms` overflows `Int` here, and an overflow trap takes
    /// the whole app down rather than producing a wrong anchor.
    ///
    /// `segments` must be in `(t_start_ms, id)` order — that is what makes the choice deterministic
    /// when a mic and a system segment both qualify.
    static func anchorSegmentID(forOffsetMs offsetMs: Int, in segments: [TranscriptSegment]) -> Int64? {
        guard !segments.isEmpty else { return nil }
        let containing = segments.filter { $0.contains(offsetMs: offsetMs) }
        if let chosen = containing.first(where: \.edited) ?? containing.first {
            return chosen.id
        }
        func distance(to segment: TranscriptSegment) -> Double {
            let offset = Double(offsetMs)
            return min((offset - Double(segment.tStartMs)).magnitude, (offset - Double(segment.tEndMs)).magnitude)
        }
        return segments.min { distance(to: $0) < distance(to: $1) }?.id
    }

    // MARK: - Vocabulary

    /// Idempotent on the `(term, folder)` unique index: seeding attendees for the same meeting
    /// twice returns the existing row rather than failing.
    @discardableResult
    public func addVocabularyTerm(_ term: VocabularyTerm) throws -> VocabularyTerm {
        let saved = try dbPool.write { db -> VocabularyTerm in
            if let existing = try Self.fetchTerm(db, term: term.term, folderID: term.folderID) {
                return existing
            }
            var term = term
            try term.insert(db)
            return term
        }
        StoreChange.post(storePath: dbPool.path)
        return saved
    }

    public func vocabularyTerm(_ term: String, folderID: String?) throws -> VocabularyTerm? {
        try dbPool.read { try Self.fetchTerm($0, term: term, folderID: folderID) }
    }

    public func allVocabularyTerms() throws -> [VocabularyTerm] {
        try dbPool.read { db in
            try VocabularyTerm.fetchAll(db, sql: "SELECT * FROM vocabulary ORDER BY term COLLATE NOCASE ASC")
        }
    }

    /// Terms in one scope only. `folderID` nil means the global scope, not every scope.
    public func vocabularyTerms(folderID: String?) throws -> [VocabularyTerm] {
        try dbPool.read { db in
            if let folderID {
                return try VocabularyTerm.fetchAll(
                    db,
                    sql: "SELECT * FROM vocabulary WHERE folder_id = ? ORDER BY term COLLATE NOCASE ASC",
                    arguments: [folderID]
                )
            }
            return try VocabularyTerm.fetchAll(
                db,
                sql: "SELECT * FROM vocabulary WHERE folder_id IS NULL ORDER BY term COLLATE NOCASE ASC"
            )
        }
    }

    /// What the recogniser actually gets for this meeting: global terms plus the terms scoped to
    /// its folder, enabled only. Another folder's jargon is deliberately excluded — pushing every
    /// term into every meeting is what makes custom vocabulary fire on words nobody said.
    public func vocabularyInEffect(meetingID: String) throws -> [VocabularyTerm] {
        try dbPool.read { db in
            guard let meeting = try Meeting.fetchOne(db, key: meetingID) else {
                throw StoreError.meetingNotFound(meetingID)
            }
            return try VocabularyTerm.fetchAll(db, sql: """
                SELECT * FROM vocabulary
                WHERE enabled = 1 AND (folder_id IS NULL OR folder_id = ?)
                ORDER BY term COLLATE NOCASE ASC
                """, arguments: [meeting.folderID])
        }
    }

    /// Soft-disable. A badly auto-seeded term stays visible instead of coming back on the next seed.
    @discardableResult
    public func setVocabularyEnabled(id: Int64, _ enabled: Bool) throws -> Bool {
        let changed = try dbPool.write { db -> Bool in
            try db.execute(sql: "UPDATE vocabulary SET enabled = ? WHERE id = ?", arguments: [enabled, id])
            return db.changesCount > 0
        }
        if changed { StoreChange.post(storePath: dbPool.path) }
        return changed
    }

    @discardableResult
    public func deleteVocabularyTerm(id: Int64) throws -> Bool {
        let deleted = try dbPool.write { try VocabularyTerm.deleteOne($0, key: id) }
        if deleted { StoreChange.post(storePath: dbPool.path) }
        return deleted
    }

    // MARK: - Settings

    /// The stored value, else the documented default, else nil.
    public func setting(_ key: SettingKey) throws -> String? {
        let stored = try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key.rawValue])
        }
        return stored ?? key.defaultValue
    }

    public func settingInt(_ key: SettingKey) throws -> Int? {
        try setting(key).flatMap(Int.init)
    }

    public func settingBool(_ key: SettingKey) throws -> Bool? {
        guard let value = try setting(key)?.lowercased() else { return nil }
        return ["1", "true", "yes"].contains(value)
    }

    /// A nil value deletes the row, which restores the default rather than storing an empty string.
    public func setSetting(_ key: SettingKey, _ value: String?) throws {
        try dbPool.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key.rawValue, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key.rawValue])
            }
        }
        StoreChange.post(storePath: dbPool.path)
    }

    /// Only what is actually stored. Defaults are not materialised — `meetings config get` reports
    /// them through ``setting(_:)``, and writing them into the table would make a later change to a
    /// default invisible on an existing install.
    public func storedSettings() throws -> [String: String] {
        try dbPool.read { db in
            var result: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM settings") {
                result[row["key"]] = row["value"]
            }
            return result
        }
    }

    // MARK: - Shared fetches

    static func fetchSegments(_ db: Database, meetingID: String, channel: Channel?) throws -> [TranscriptSegment] {
        if let channel {
            return try TranscriptSegment.fetchAll(db, sql: """
                SELECT * FROM transcript_segments
                WHERE meeting_id = ? AND channel = ?
                ORDER BY t_start_ms ASC, id ASC
                """, arguments: [meetingID, channel.rawValue])
        }
        return try TranscriptSegment.fetchAll(db, sql: """
            SELECT * FROM transcript_segments
            WHERE meeting_id = ?
            ORDER BY t_start_ms ASC, id ASC
            """, arguments: [meetingID])
    }

    static func fetchNotes(_ db: Database, meetingID: String) throws -> [Note] {
        try Note.fetchAll(db, sql: """
            SELECT * FROM notes WHERE meeting_id = ? ORDER BY t_offset_ms ASC, id ASC
            """, arguments: [meetingID])
    }

    static func fetchTerm(_ db: Database, term: String, folderID: String?) throws -> VocabularyTerm? {
        try VocabularyTerm.fetchOne(db, sql: """
            SELECT * FROM vocabulary
            WHERE term = ? COLLATE NOCASE AND ifnull(folder_id, '') = ifnull(?, '')
            """, arguments: [term, folderID])
    }
}

// MARK: - NUL sanitising

/// SQLite text is a C string and GRDB binds a Swift `String` as one, so a NUL byte anywhere in a
/// value truncates the column at that byte — no error, no warning, the rest of the summary simply
/// gone, and the search index with it. The store is the trust boundary for two sources that can
/// carry one: an agent writing a summary through the CLI, and an imported bundle. So it strips NULs
/// here, at the single write surface, rather than hoping every call site remembered to.
///
/// Sanitising rather than throwing: a NUL is never meaningful in any of these fields, and failing a
/// whole `summary set` over an invisible byte helps nobody. It becomes a space rather than nothing,
/// so the words either side of it stay two words to the tokenizer instead of being welded into one
/// token that matches nothing anybody would type. Same substitution as ``MeetingStore/ftsQuery(_:)``
/// makes on the way out.
extension String {
    var withoutNULs: String {
        contains("\0") ? replacingOccurrences(of: "\0", with: " ") : self
    }
}

extension Meeting {
    /// The JSON columns need this too, and the reason they were skipped was wrong.
    ///
    /// JSON encoding does escape a NUL rather than emitting one, so `actions` and `attendees` never
    /// truncated their column the way a plain text field would — but the escape *round-trips*. A
    /// `"ship the thing"` an agent piped into `actions set` came back out of `--json` as a raw
    /// NUL in the next agent's stdin, and out of the app into an `NSString`, having survived the one
    /// place in the system that exists to stop it. Sanitising is the trust boundary, not truncation
    /// avoidance: the byte is never meaningful in a title, an action or a person's name, wherever it
    /// happens to be stored.
    func sanitized() -> Meeting {
        var copy = self
        copy.title = title.withoutNULs
        copy.preNotes = preNotes.withoutNULs
        copy.summary = summary?.withoutNULs
        copy.actions = actions?.map { action in
            var action = action
            action.text = action.text.withoutNULs
            action.owner = action.owner?.withoutNULs
            action.due = action.due?.withoutNULs
            return action
        }
        copy.attendees = attendees.map { attendee in
            Attendee(name: attendee.name?.withoutNULs, email: attendee.email?.withoutNULs)
        }
        return copy
    }
}

extension TranscriptSegment {
    func sanitized() -> TranscriptSegment {
        var copy = self
        copy.text = text.withoutNULs
        return copy
    }
}

extension Note {
    func sanitized() -> Note {
        var copy = self
        copy.text = text.withoutNULs
        return copy
    }
}

extension Folder {
    func sanitized() -> Folder {
        var copy = self
        copy.name = name.withoutNULs
        return copy
    }
}
