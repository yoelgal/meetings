import Foundation
import GRDB

/// The one and only schema definition.
///
/// The FTS index is maintained by triggers rather than by call sites. Every write path — the app,
/// the CLI, an import, the batch re-pass — would otherwise have to remember to reindex, and the one
/// that forgets produces a meeting that is silently unsearchable. SQLite does not forget.
public enum Schema {
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: tables)
            try db.execute(sql: ftsTriggers)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: transcriptIssues)
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: transcriptIssueKind)
        }
        migrator.registerMigration("v4") { db in
            try db.execute(sql: splitAgentCommand)
        }
        migrator.registerMigration("v5") { db in
            try db.execute(sql: calendarDismissals)
        }
        migrator.registerMigration("v6") { db in
            try actionsIntoTheWriteUp(db)
        }
        // The same body as `v6`, deliberately, and that is the repair.
        //
        // One identifier carried three different rules across this release. `v6` first skipped any
        // document that already had a task item anywhere in it — stranding every real action of that
        // meeting in a column nothing reads. It then matched on set membership, which collapsed two
        // commitments that happened to read the same into one line. Only the third rule counts
        // matches, which is the one below. GRDB records the identifier and nothing else, so a store
        // migrated by either of the first two builds will never run the corrected code: `v6` is
        // applied, so `v6` is skipped, forever, and the actions sit in a column no surface reads.
        //
        // Re-running it under a new identifier is the whole fix, and it is safe because
        // ``MarkdownActions/appending(_:to:)`` is idempotent per action: a store the good `v6` handled
        // finds every action already in its write-up and is left byte-identical, and a store either
        // bad `v6` mishandled gets exactly the lines it is missing.
        migrator.registerMigration("v7") { db in
            try actionsIntoTheWriteUp(db)
        }
        return migrator
    }

    /// The write-up became the record for actions, so the actions that were only ever in the column
    /// move into it — appended to the summary as a GFM task list under an `## Actions` heading.
    ///
    /// **The column is not dropped and not cleared.** Nothing reads it after this, but it is the
    /// only copy of `owner` and `due`, which the markdown does not represent yet, and it is the
    /// safety net if this migration got a document wrong: the row still holds exactly what the agent
    /// wrote. `meetings export --format bundle` carries `owner` and `due` out onto the write-up's own
    /// actions — see ``MeetingBundle`` — and a `SELECT actions FROM meetings` reads the whole column
    /// back, including anything since deleted from the write-up.
    ///
    /// **Idempotent**, because it has to be: ``MarkdownActions/appending(_:to:)`` returns a document
    /// that already carries task items untouched, so a re-run — which the orphan repair and
    /// `RobustStoreTests` both provoke — cannot produce a second copy of the list.
    ///
    /// A meeting whose actions land on an *empty* summary gains one, and with it the state that
    /// having a write-up implies. That is ``Meeting/setSummary(_:)``'s own rule, restated here
    /// because a migration cannot call it: `ready` means "nothing written up yet", and a meeting
    /// whose write-up is its action list is written up.
    static func actionsIntoTheWriteUp(_ db: Database) throws {
        let rows = try Row.fetchAll(
            db, sql: "SELECT id, state, summary, actions FROM meetings WHERE actions IS NOT NULL"
        )
        for row in rows {
            let encoded: String = row["actions"] ?? ""
            guard let actions = try? JSONDecoder().decode([Action].self, from: Data(encoded.utf8)),
                  !actions.isEmpty
            else { continue }
            let summary: String = row["summary"] ?? ""
            let merged = MarkdownActions.appending(actions, to: summary)
            guard merged != summary else { continue }
            let state: String = row["state"] ?? ""
            let next = state == MeetingState.ready.rawValue ? MeetingState.complete.rawValue : state
            try db.execute(
                sql: "UPDATE meetings SET summary = ?, state = ? WHERE id = ?",
                arguments: [merged, next, row["id"] as String?]
            )
        }
    }

    /// Calendar meetings are given rows the moment they appear in the look-ahead window
    /// (``CalendarSync``), which runs again every time the window refreshes. Without a record of
    /// what was deleted, deleting one of those rows would put it straight back on the next pass —
    /// the row reappears seconds later with no way to be rid of it.
    ///
    /// `until` is when the tombstone stops mattering: the event's own end. Past it the event can no
    /// longer be in anybody's look-ahead window, so the sync prunes the row rather than keeping one
    /// per deleted meeting forever. No foreign key, deliberately — the whole point is that it
    /// outlives the meeting row it came from.
    ///
    /// `IF NOT EXISTS` so replaying this statement is a no-op. The orphan repair reopens a store
    /// mid-ladder and `RobustStoreTests` re-runs the last migration to reach that path, and a
    /// migration that can only ever run against a virgin database turns both into a hard failure.
    static let calendarDismissals = """
        CREATE TABLE IF NOT EXISTS calendar_dismissals (
          calendar_event_id TEXT PRIMARY KEY NOT NULL,
          until             INTEGER NOT NULL
        );
        """

    /// `ai.commandTemplate` was read by two things that need different values: the Needs-write-up
    /// card, which *displays* it to be pasted into an agent session, and ``EnhancementRunner``,
    /// which *execs* `argv[0]`. It is now two keys.
    ///
    /// The old row was the executed one — it is what Mode B ran — so that is where a customised
    /// value goes. Defaults are never written to this table, so this can only ever move a value
    /// somebody deliberately set, and dropping one of those silently would turn Mode B off with no
    /// trace of why. `OR REPLACE` because a rename onto an occupied primary key is otherwise a
    /// constraint failure that would fail the whole open.
    static let splitAgentCommand = """
        UPDATE OR REPLACE settings SET key = '\(SettingKey.aiLocalAgentRunCommand.rawValue)'
        WHERE key = '\(SettingKey.legacyAICommandTemplate.rawValue)';
        """

    /// One statement per foreign key above, each doing exactly what that key's `ON DELETE` clause
    /// already says to do with a child whose parent is gone: `CASCADE` deletes the row, `SET NULL`
    /// unlinks it. That is what makes this a repair rather than a guess — an orphan references
    /// nothing, there is no other answer, and the answer is written in the schema.
    ///
    /// Run by ``MeetingsDatabase/repairOrphans(at:)`` when a migration's `PRAGMA foreign_key_check`
    /// refuses to open the store. Kept here, next to the constraints it mirrors, because a new
    /// foreign key needs a new line here and nowhere else.
    /// The table is carried alongside each statement because the repair runs against a store that
    /// is part-way up the migration ladder: a v1 store failing on its way to v2 has no
    /// `transcript_issues` yet, and `DELETE FROM` a table that does not exist is an error, not a
    /// no-op.
    static let orphanRepairs: [(table: String, sql: String)] = [
        ("transcript_segments", "DELETE FROM transcript_segments WHERE meeting_id NOT IN (SELECT id FROM meetings)"),
        ("notes", "DELETE FROM notes WHERE meeting_id NOT IN (SELECT id FROM meetings)"),
        ("transcript_issues", "DELETE FROM transcript_issues WHERE meeting_id NOT IN (SELECT id FROM meetings)"),
        ("vocabulary", "DELETE FROM vocabulary WHERE folder_id IS NOT NULL AND folder_id NOT IN (SELECT id FROM folders)"),
        ("notes", """
            UPDATE notes SET anchor_segment_id = NULL
            WHERE anchor_segment_id IS NOT NULL
              AND anchor_segment_id NOT IN (SELECT id FROM transcript_segments)
            """),
        ("meetings", """
            UPDATE meetings SET folder_id = NULL
            WHERE folder_id IS NOT NULL AND folder_id NOT IN (SELECT id FROM folders)
            """),
        ("folders", """
            UPDATE folders SET parent_id = NULL
            WHERE parent_id IS NOT NULL AND parent_id NOT IN (SELECT id FROM folders)
            """),
    ]

    /// A channel the batch pass could not read, a case the original spec never covered: it assumed
    /// the pass either runs or does not.
    ///
    /// Its own table rather than a column on `meetings`, for two reasons. A column would mean
    /// `Meeting` — a type this unit does not own — has to learn a field before the failure can be
    /// stored at all, and the natural shape here is one row per channel, which is a list. The
    /// cascade means a deleted meeting takes its issues with it, like every other child table.
    ///
    /// One row per `(meeting, channel)`: a re-run of the pass replaces the verdict for the channel it
    /// re-read, and clears it when that channel finally succeeds.
    private static let transcriptIssues = """
        CREATE TABLE transcript_issues (
          meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
          channel    TEXT NOT NULL,
          reason     TEXT NOT NULL,
          at         INTEGER NOT NULL,
          PRIMARY KEY (meeting_id, channel)
        );
        """

    /// The table conflated two different facts under one primary key, and the collision lost the
    /// worse of the two.
    ///
    /// "The batch pass could not read this channel" is written by the transcriber and cleared by the
    /// transcriber when a re-run finally reads the file. "This channel captured nothing but digital
    /// silence" is written by the recorder and is a fact about the audio itself — a re-transcription
    /// of the same silent WAV does not make the user's voice reappear. Keyed on `(meeting, channel)`
    /// alone, the second was overwritten by the first and then cleared by the transcriber's own
    /// all-clear, which is exactly how a meeting with a dead microphone reached `ready` saying
    /// nothing was wrong.
    ///
    /// `kind` therefore joins the key, and ``MeetingStore/clearTranscriptIssue(meetingID:channel:)``
    /// only ever clears the transcriber's own verdict. Existing rows are all transcription verdicts,
    /// which is why the default backfills them correctly.
    private static let transcriptIssueKind = """
        CREATE TABLE transcript_issues_v3 (
          meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
          channel    TEXT NOT NULL,
          kind       TEXT NOT NULL DEFAULT 'transcription',
          reason     TEXT NOT NULL,
          at         INTEGER NOT NULL,
          PRIMARY KEY (meeting_id, channel, kind)
        );
        INSERT INTO transcript_issues_v3 (meeting_id, channel, kind, reason, at)
          SELECT meeting_id, channel, 'transcription', reason, at FROM transcript_issues;
        DROP TABLE transcript_issues;
        ALTER TABLE transcript_issues_v3 RENAME TO transcript_issues;
        """

    private static let tables = """
        CREATE TABLE folders (
          id          TEXT PRIMARY KEY NOT NULL,
          name        TEXT NOT NULL,
          parent_id   TEXT REFERENCES folders(id) ON DELETE SET NULL,
          sort_order  INTEGER NOT NULL DEFAULT 0,
          created_at  INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX idx_folders_name ON folders(name COLLATE NOCASE);

        CREATE TABLE meetings (
          id                TEXT PRIMARY KEY NOT NULL,
          folder_id         TEXT REFERENCES folders(id) ON DELETE SET NULL,
          title             TEXT NOT NULL,
          state             TEXT NOT NULL,
          calendar_event_id TEXT,
          scheduled_start   INTEGER,
          scheduled_end     INTEGER,
          started_at        INTEGER,
          ended_at          INTEGER,
          attendees         TEXT NOT NULL DEFAULT '[]',
          pre_notes         TEXT NOT NULL DEFAULT '',
          summary           TEXT,
          actions           TEXT,
          audio_path        TEXT,
          audio_purged_at   INTEGER,
          source            TEXT NOT NULL DEFAULT 'recorded',
          imported_from     TEXT
        );
        -- Uniqueness applies to rows this machine materialised from the calendar, and only to
        -- those: it is what makes `cal:` materialisation idempotent under a race, where
        -- the loser catches the constraint and reads back the winner's row. An imported row is
        -- exempt, because a bundle re-import "generates a new id and records
        -- imported_from — never overwrites", and a blanket unique index turns that restore into a
        -- hard failure. The second, non-unique index is what `meeting(calendarEventID:)` reads.
        CREATE UNIQUE INDEX idx_meetings_calendar_event ON meetings(calendar_event_id)
          WHERE calendar_event_id IS NOT NULL AND imported_from IS NULL;
        CREATE INDEX idx_meetings_calendar_event_all ON meetings(calendar_event_id);
        CREATE INDEX idx_meetings_state ON meetings(state);
        CREATE INDEX idx_meetings_folder ON meetings(folder_id);

        CREATE TABLE transcript_segments (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
          channel     TEXT NOT NULL,
          t_start_ms  INTEGER NOT NULL,
          t_end_ms    INTEGER NOT NULL,
          text        TEXT NOT NULL,
          pass        TEXT NOT NULL,
          edited      INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_seg_meeting ON transcript_segments(meeting_id, t_start_ms);

        CREATE TABLE notes (
          id                INTEGER PRIMARY KEY AUTOINCREMENT,
          meeting_id        TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
          t_offset_ms       INTEGER NOT NULL,
          anchor_segment_id INTEGER REFERENCES transcript_segments(id) ON DELETE SET NULL,
          text              TEXT NOT NULL
        );
        CREATE INDEX idx_notes_meeting ON notes(meeting_id, t_offset_ms);

        CREATE TABLE vocabulary (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          term      TEXT NOT NULL,
          folder_id TEXT REFERENCES folders(id) ON DELETE CASCADE,
          threshold REAL,
          source    TEXT NOT NULL,
          enabled   INTEGER NOT NULL DEFAULT 1
        );
        CREATE UNIQUE INDEX idx_vocab_scope ON vocabulary(term COLLATE NOCASE, ifnull(folder_id,''));

        CREATE TABLE settings (
          key   TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        );

        CREATE VIRTUAL TABLE meetings_fts USING fts5(
          text,
          meeting_id UNINDEXED,
          kind       UNINDEXED,
          source_id  UNINDEXED,
          tokenize = 'unicode61 remove_diacritics 2'
        );
        """

    /// Every trigger addresses its index row by **rowid**, computed from the source row's own id.
    ///
    /// `kind` and `source_id` are UNINDEXED, so `WHERE kind = 'segment' AND source_id = '123'` is a
    /// full scan of the entire index — and the batch re-pass deletes hundreds of segments in one
    /// transaction, which makes a scan per segment. Measured on a 95 000-row index that is 5.7 s to
    /// re-pass an 8 000-segment meeting and 11 s to delete an ordinary one-hour meeting, growing
    /// with the store forever, and it holds the write lock for all of it (the two-process
    /// mitigation is a 5 s busy timeout, so the other process's write simply fails). Keyed on rowid
    /// the same deletes are O(log n) and the whole problem goes away.
    ///
    /// The rowid is `source_id * 4 + kind`, so the four kinds occupy four disjoint residue classes
    /// and can never collide: segments +0, notes +1, prenotes +2, summary +3. Segment and note ids
    /// are AUTOINCREMENT and never reused; `meetings` has a TEXT primary key, so the trigger uses
    /// its implicit `rowid`, which is only ever reused after the row (and its two index rows) are
    /// gone.
    ///
    /// `source_id` is still written, because search results report it: a segment/note rowid for two
    /// kinds and a meeting uuid for the other two, cast to TEXT so one column never mixes types.
    ///
    /// Empty text is never indexed, for any kind: an unwritten summary — or a segment whose text was
    /// cleared — is not a document that matches everything, and a zero-length document still drags
    /// down bm25's average document length for every other query. Updates therefore delete and
    /// re-insert rather than UPDATE, so text cleared to empty leaves no index row behind.
    ///
    /// The update triggers watch `meeting_id` as well as `text`: a segment that moves between
    /// meetings with a stale index row is searchable under a meeting it no longer belongs to.
    private static let ftsTriggers = """
        CREATE TRIGGER seg_ai_fts AFTER INSERT ON transcript_segments BEGIN
          INSERT INTO meetings_fts(rowid, text, meeting_id, kind, source_id)
            SELECT new.id * 4 + 0, new.text, new.meeting_id, 'segment', CAST(new.id AS TEXT)
            WHERE new.text <> '';
        END;
        CREATE TRIGGER seg_au_fts AFTER UPDATE OF text, meeting_id ON transcript_segments BEGIN
          DELETE FROM meetings_fts WHERE rowid = old.id * 4 + 0;
          INSERT INTO meetings_fts(rowid, text, meeting_id, kind, source_id)
            SELECT new.id * 4 + 0, new.text, new.meeting_id, 'segment', CAST(new.id AS TEXT)
            WHERE new.text <> '';
        END;
        CREATE TRIGGER seg_ad_fts AFTER DELETE ON transcript_segments BEGIN
          DELETE FROM meetings_fts WHERE rowid = old.id * 4 + 0;
        END;

        CREATE TRIGGER note_ai_fts AFTER INSERT ON notes BEGIN
          INSERT INTO meetings_fts(rowid, text, meeting_id, kind, source_id)
            SELECT new.id * 4 + 1, new.text, new.meeting_id, 'note', CAST(new.id AS TEXT)
            WHERE new.text <> '';
        END;
        CREATE TRIGGER note_au_fts AFTER UPDATE OF text, meeting_id ON notes BEGIN
          DELETE FROM meetings_fts WHERE rowid = old.id * 4 + 1;
          INSERT INTO meetings_fts(rowid, text, meeting_id, kind, source_id)
            SELECT new.id * 4 + 1, new.text, new.meeting_id, 'note', CAST(new.id AS TEXT)
            WHERE new.text <> '';
        END;
        CREATE TRIGGER note_ad_fts AFTER DELETE ON notes BEGIN
          DELETE FROM meetings_fts WHERE rowid = old.id * 4 + 1;
        END;

        CREATE TRIGGER meeting_ai_fts AFTER INSERT ON meetings BEGIN
          INSERT INTO meetings_fts(rowid, text, meeting_id, kind, source_id)
            SELECT new.rowid * 4 + 2, new.pre_notes, new.id, 'prenotes', new.id
            WHERE new.pre_notes <> '';
          INSERT INTO meetings_fts(rowid, text, meeting_id, kind, source_id)
            SELECT new.rowid * 4 + 3, new.summary, new.id, 'summary', new.id
            WHERE new.summary IS NOT NULL AND new.summary <> '';
        END;
        CREATE TRIGGER meeting_au_prenotes_fts AFTER UPDATE OF pre_notes ON meetings BEGIN
          DELETE FROM meetings_fts WHERE rowid = old.rowid * 4 + 2;
          INSERT INTO meetings_fts(rowid, text, meeting_id, kind, source_id)
            SELECT new.rowid * 4 + 2, new.pre_notes, new.id, 'prenotes', new.id
            WHERE new.pre_notes <> '';
        END;
        CREATE TRIGGER meeting_au_summary_fts AFTER UPDATE OF summary ON meetings BEGIN
          DELETE FROM meetings_fts WHERE rowid = old.rowid * 4 + 3;
          INSERT INTO meetings_fts(rowid, text, meeting_id, kind, source_id)
            SELECT new.rowid * 4 + 3, new.summary, new.id, 'summary', new.id
            WHERE new.summary IS NOT NULL AND new.summary <> '';
        END;
        -- Only this meeting's own two rows. Its segments and notes are removed by the foreign-key
        -- cascade, which fires their delete triggers — verified by the cascade test in SearchTests.
        CREATE TRIGGER meeting_ad_fts AFTER DELETE ON meetings BEGIN
          DELETE FROM meetings_fts WHERE rowid IN (old.rowid * 4 + 2, old.rowid * 4 + 3);
        END;
        """
}
