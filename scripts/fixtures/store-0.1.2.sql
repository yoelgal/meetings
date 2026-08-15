-- A Meetings store exactly as v0.1.2 left one: schema at the last migration that release shipped
-- (`v5`), one meeting written the way 0.1.2 wrote them.
--
-- **Frozen. Never regenerate this from Schema.swift.** It is the input to a check on the v6
-- migration, and a fixture built by the code under test cannot catch that code changing its mind
-- about the shape it is migrating *from*. `git diff v0.1.2 -- Sources/MeetingsCore/Store/Schema.swift`
-- shows v1–v5 untouched since the tag, which is what makes this an accurate copy of the real thing.
-- If a future release changes v1–v5 in place — it should not — this file stays as it is: a store on
-- somebody's disk was written by 0.1.2, not by the current build's idea of it.
--
-- The meeting is the shape the upgrade actually meets: a write-up on the `## What we decided /
-- ## Actions / ## Open questions / ## Not covered` template SKILL.md handed agents in 0.1.2, whose
-- Actions section is prose bullets and *not* GFM checkboxes, plus the structured action list in the
-- legacy `actions` column that was the only real record of them. v6 has to move those into the
-- write-up, once, without losing the owner and due the column carries and the markdown cannot.

PRAGMA foreign_keys = OFF;

BEGIN;

-- ------------------------------------------------------------------ v1: tables
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

-- ------------------------------------------------------------------ v1: FTS triggers
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
CREATE TRIGGER meeting_ad_fts AFTER DELETE ON meetings BEGIN
  DELETE FROM meetings_fts WHERE rowid IN (old.rowid * 4 + 2, old.rowid * 4 + 3);
END;

-- ------------------------------------------------------------------ v2 + v3: transcript issues
-- The v3 shape, which is what a v5 store has: v2 created this table without `kind`, v3 rebuilt it
-- with `kind` in the primary key and renamed it back.
CREATE TABLE transcript_issues (
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  channel    TEXT NOT NULL,
  kind       TEXT NOT NULL DEFAULT 'transcription',
  reason     TEXT NOT NULL,
  at         INTEGER NOT NULL,
  PRIMARY KEY (meeting_id, channel, kind)
);

-- ------------------------------------------------------------------ v5: calendar dismissals
-- v4 renamed a settings row and left no schema behind.
CREATE TABLE calendar_dismissals (
  calendar_event_id TEXT PRIMARY KEY NOT NULL,
  until             INTEGER NOT NULL
);

-- ------------------------------------------------------------------ GRDB's own ledger
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
INSERT INTO grdb_migrations (identifier) VALUES ('v1'), ('v2'), ('v3'), ('v4'), ('v5');

-- ------------------------------------------------------------------ the 0.1.2-shaped meeting
INSERT INTO folders (id, name, parent_id, sort_order, created_at)
VALUES ('f-torch0', 'Torch0', NULL, 0, 1735689600);

INSERT INTO meetings (
  id, folder_id, title, state, attendees, pre_notes, summary, actions, source, started_at, ended_at
) VALUES (
  '0112-weekly',
  'f-torch0',
  'Torch0 weekly',
  'complete',
  '[{"name":"Sofia","email":null},{"name":"Dan","email":null}]',
  '',
  '## What we decided

Ship the pricing change on Friday.

## Actions

- Sofia sends the numbers
- Dan books the follow-up

## Open questions

Do we grandfather the annual plans?

## Not covered

Hiring.',
  '[{"text":"Send the numbers","owner":"Sofia","due":"Friday","done":false},{"text":"Book the follow-up","owner":null,"due":null,"done":true}]',
  'recorded',
  1735689600,
  1735693200
);

COMMIT;
