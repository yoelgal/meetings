---
name: meetings
description: Read and write the user's local meeting store through the `meetings` CLI. Use whenever the request touches a meeting, call, standup, 1:1, one-on-one, sync, catch-up, huddle, interview, retro, review, kickoff, or names a person as shorthand for one ("my thing with Will", "the Sofia call", "before I talk to Dan"). Covers: adding notes before a meeting, writing up or summarising one afterwards, pulling action items, quoting or searching transcripts, answering "what did we decide about X", "what did I commit to", "who was on that call", and importing a backlog of old recordings or notes.
---

# Meetings

`meetings` is a local CLI over a single SQLite store of the user's recorded meetings: audio,
transcripts, pre-meeting notes, live notes, summaries and actions.

**The store is global, not per-project.** It lives at
`~/Library/Application Support/Meetings/store.db` and every command reads it from any working
directory. Never look for meeting files in the current repo, never create a `meetings/` folder,
never ask the user to `cd` anywhere. If `meetings` is not on `PATH`, it is inside the app at
`/Applications/Meetings.app/Contents/Helpers/meetings`.

A Mac app is looking at the same database. Every write posts a change notification, so an open
window refreshes on its own. Never tell the user to relaunch it.

## First move

```bash
meetings status            # which store, how many meetings, what is wired up
```

Run this once if anything looks wrong (empty results, a command that fails). It tells you the store
path and whether the transcription models are downloaded.

## Exit codes

Branch on these, not on the message text.

| Code | Meaning | What to do |
|---|---|---|
| 0 | Success | Continue |
| 1 | Unexpected failure | Show the user the stderr message; do not retry blindly |
| 2 | Not found. The ref, folder or segment does not resolve | Re-find the meeting; do not create one to compensate |
| 3 | Invalid state for this operation | Say why (e.g. you cannot edit a transcript while recording) |
| 4 | Ambiguous. The name matched more than one row | Ask the user which one |
| 64 | Usage error | Fix your command line |

Every command takes `--json` and then prints exactly one JSON value on stdout; logs and warnings go
to stderr. In `--json` mode a failure prints `{"error":{"code":2,"message":"…"}}` on **stdout** and
still sets the exit code. Prefer `--json` whenever you are going to branch on the result.

## Refs

A `<ref>` is one of two things, and every command accepts both:

| Form | Meaning |
|---|---|
| `<uuid>` | A meeting that exists in the store |
| `cal:<eventIdentifier>` | A calendar event that has **no** row yet |

**A write against a `cal:` ref materialises the row.** Adding pre-notes to `cal:ABC-123` creates the
meeting first, copying the title, times, attendees and calendar id from the event, then applies the
write. There is no separate create step, and running it twice does not create two rows. So:

- Never call `meetings create` for something that is already on the calendar. Write against its
  `cal:` ref.
- `meetings create` is only for meetings that exist nowhere yet, such as a migration of old files.
- **A write that is refused materialises nothing.** A row only appears when the write succeeded, so
  a non-zero exit against a `cal:` ref leaves the calendar event exactly as it was.

Refs are the first field of every listing, so `meetings list` pipes straight into another command.

## Finding the right meeting

```bash
meetings upcoming --days 7 --json                 # meetings ahead, calendar + store
meetings upcoming --match "will" --json           # scored candidates, links or not
meetings list --since 7d --json                   # recent past, newest first
meetings list --state ready --json                # recorded, transcribed, not yet written up
meetings search "pricing" --json                  # full text across all four kinds of text
```

The listing shows calendar events that carry a meeting link, plus scheduled rows from the store — a
birthday or a focus block is on the calendar but is not a meeting, and the app's Upcoming applies
the identical rule. `--match` and `cal:` refs are **not** filtered: a linkless event still scores,
still resolves, and still takes pre-notes.

`--match` scores against event title, attendee names, attendee emails and calendar name, and returns
**every** candidate above threshold with a `score`. It never resolves to one. Each candidate carries
`ref`, `title`, `start`, `score`, `matchedOn` and `attendees`, so you never have to `show` each one
before asking the disambiguation question.

`--json` also returns a `hidden` array alongside `candidates`. Those scored just as well but have
**already started**, so `upcoming` leaves them out of `candidates`. If `candidates` is empty and
`hidden` is not, the meeting the user means is probably in `hidden`. Say when it was rather than
"there is no such meeting".

**Disambiguation rule: never auto-pick the top `--match` result.** One candidate, proceed. Two or
more, stop and ask the user, listing title, date and attendees for each. This holds even when the
top score is far ahead of the rest. "Will Chen" and "Will Fraser" score identically on "will".

Ask at most one such question per task. If the user's phrasing already narrows it ("the standup this
morning", "the Torch0 review"), use the extra words. Filter the candidates on date, folder or
attendee before you decide it is ambiguous.

## Reading without burning context

- `meetings show <ref>` gives title, timings, attendees, pre-notes, summary and actions. It does
  **not** load the transcript. This is the cheap default; use it first.
- `meetings show <ref> --summary` prints that section alone, so it pipes to a file.
- `meetings show <ref> --notes` prints the live notes the user typed during the meeting.
- `meetings transcript <ref>` prints the full transcript. Expensive. Read the rules below first.
- `meetings search <query>` returns the ref, the meeting title and date, which kind of text matched
  (`segment`, `note`, `prenotes`, `summary`) and a snippet with the match wrapped in `« »`. Usually
  the right answer to "what did we say about X" without opening anything.

**Search one word first.** Words are ANDed *inside one* transcript line, note, pre-note or summary,
not across a meeting, so `"pricing model"` misses a call that says "hybrid pricing" in one line and
"the per-seat model" in another. Zero hits on a phrase means nothing. Zero hits on the strongest
single word means something. Search the one word that could not appear by accident, then narrow with
`--folder` or `list --since`. Never report "nothing on record" off a multi-word query alone.

A search hit tells you which meeting, not where inside it. To find the offset without reading the
transcript into your context, let the shell do it:

```bash
meetings transcript <ref> | grep -in "pricing"      # → [42:10] Others: … the pricing model …
```

Then read only that window with `--range`.

Transcript lines are labelled `You` for the microphone, which is the user, and `Others` for
everything from the speakers. Channel separation is the only speaker attribution there is. Do not
invent names for `Others` beyond what the words themselves make obvious.

**A transcript can be half a transcript.** When one channel failed to transcribe:

| Where | What you see |
|---|---|
| `show`, `transcript` (md) | a `## transcript issues` section, or a `> The mic channel could not be transcribed: …` line above the text |
| `show --json`, `list --json`, `transcript --json` | a `transcriptIssues` array, absent when the transcript is whole. Each entry carries `kind`: `capture` means the audio was never there and no re-run brings it back, `transcription` means the audio is there and could not be read. Branch on `kind`, not on the English in `reason` |
| `list` | the state marked with a `*` |
| `transcript --format srt` | on **stderr**, because a subtitle file has nowhere to put a line nobody said |

A meeting carrying one is missing a whole side of the conversation. Say so in the write-up rather
than summarising the half as if it were the whole, and never conclude "nobody mentioned X" from it.

## Long meetings

`meetings show <ref> --json` reports `durationMs`. **Over 40 minutes, never read the transcript in
one piece.** Instead:

1. Split into 10–15 minute windows and read one at a time:
   ```bash
   meetings transcript <ref> --range 0-15:00
   meetings transcript <ref> --range 15:00-30:00
   ```
   `--range` accepts `5:00-12:30`, `-10:00` (from the start) and `45:00-` (to the end).
2. Summarise each window on its own, with decisions, actions, open questions and timestamps.
3. Merge the window summaries into the final write-up. Deduplicate. A thread that runs across three
   windows is one point, not three.

`meetings transcript <ref> --chunks 15` does the same split in one call, emitting
`## chunk k of n  <start>-<end>` headings (`--chunks 15 --json` gives a `chunks` array). Use it when
you want the split written to a file and processed window by window.

Under 40 minutes, read it whole. Chunking a 20-minute call just loses cross-references.

## Writing

Every write command takes text as a positional argument, as `--file <path>`, or as `-` to read
stdin, so generated markdown pipes straight in and never has to survive shell quoting:

```bash
printf '%s\n' "$SUMMARY" | meetings summary set <ref> -
```

Three things about the positional form:

- **A leading `-` is text.** `meetings prenotes add <ref> "- a bullet"` writes that bullet, and so
  does text that is exactly `-h`. Only a bare `-` means stdin, and `-h` means help in one place
  only: immediately after the command name, where `meetings prenotes add -h` puts it.
- **There are no escapes.** `"line one\nline two"` stores a literal backslash-n. Anything with more
  than one line goes through `--file` or stdin, where the newlines are real.
- **No write ever succeeds silently.** If no text reached the command from an argument, `--file` or
  stdin, it exits 64 and says which of the three forms it accepts. Exit 0 from a write means the
  write happened.

## Workflow 1: notes before a meeting

> "add some notes to my call with Will tomorrow"

1. `meetings upcoming --days 7 --match "will" --json`
2. One candidate, take its `ref`. Several, ask which.
3. `meetings prenotes get <ref>` to see what is already there.
4. Append rather than replace unless the user asked to rewrite. One line as an argument, several
   through stdin, because there is no `\n` escape:
   ```bash
   meetings prenotes add <ref> "- push back on the March timeline"

   printf '%s\n' "- push back on the March timeline" "- ask who owns migration" \
     | meetings prenotes add <ref> -
   ```
   `prenotes set` replaces the whole thing. Reach for it only on an explicit "rewrite" or "replace".
5. Confirm with the meeting's title and time, so the user can see it landed on the right one.

A `cal:` ref is fine here. The write materialises the row.

## Workflow 2: writing up after a meeting

> "write up my 1:1 with Sofia"

1. `meetings list --state ready --json` is the queue of **recorded** meetings that are transcribed
   and not yet written up. Match on title, date and attendees; ask if more than one fits.
   If it comes back empty, the meeting was probably created rather than recorded: `meetings create`
   lands a meeting at `complete` whether or not anybody has written it up, so it is never in
   `ready`. Fall back to `meetings list --since 7d --json` and pick from there.
2. `meetings show <ref> --json` gives pre-notes, attendees, duration and any existing summary.
3. `meetings show <ref> --notes` gives the notes the user typed live, each with its offset.
4. Read the transcript, chunked if over 40 minutes.
5. **The user's own notes steer the summary.** Their pre-notes are the agenda and their live notes
   are what they cared about. Structure the write-up around those points first, in their order, and
   only then add anything else worth keeping. A transcript-shaped summary that ignores the notes is
   the wrong output.
6. **Report what did not happen.** Every pre-note point that never came up in the meeting goes in a
   final section headed `Not covered`, listed verbatim. This is not optional. If everything was
   covered, say so in one line.
7. Write it back. **The actions go in the write-up**, as GFM task list items:
   ```markdown
   ## Actions

   - [ ] anchor live notes to system audio
   - [x] ship the gutter
   ```
   ```bash
   meetings summary set <ref> --file /tmp/writeup.md
   ```
   `summary set` replaces the write-up, and the one already there may be the user's own writing,
   because they can edit it in the app. Read it from step 2 and revise it rather than starting
   again: keep their wording where it still holds and change only what is wrong or missing.

   A `- [ ]` line **is** an action. There is no separate actions store: the user ticks the checkbox
   in the app, which changes the `[ ]` to `[x]` in this markdown, and `meetings actions list` reads
   the task items back out. Adding, editing and deleting an action is editing the document.

   `meetings actions set <ref> --file /tmp/actions.json` still exists and is the right tool when you
   only want to change the list. It takes a JSON array of
   `{"text":…,"owner":null,"due":null,"done":false}`, rewrites the `- [ ]` lines of the write-up and
   leaves every other line of it alone. It replaces the whole list, so include the ones already
   there that still stand — read them from `meetings show <ref> --json` first.

   The nth item you send rewrites the nth **action** of the document — the nth line `meetings
   actions list` gave you, counted exactly the way that command counts: an empty `- [ ]` the user is
   half-way through typing is not an action, so it is skipped and left alone rather than numbered.
   Each one is rewritten where it stands, with its own indentation: a sub-checklist nested under a
   decision stays nested, and a checkbox the user typed under "Open questions" is still under "Open
   questions" afterwards. Send fewer items than the document has and the leftover lines go; send
   more and the extras land after the last one, as new top-level actions. So send them
   in the order `meetings actions list` gave them, or you will rewrite one item over another.

   `owner` and `due` are still in the JSON shape and are still accepted, but **nothing stores them
   yet**: the markdown has nowhere to put them. They come back null. If who owes an action matters,
   write it into the text — `- [ ] Sofia: confirm the March timeline`.
8. Tell the user the headline: decisions, who owes what, and anything in `Not covered`.

A summary shape to adapt, not to pad:

```markdown
## What we decided
## Actions
## Open questions
## Not covered
```

## Workflow 3: querying a past meeting

> "what did we decide about the pricing model last week?"

1. `meetings search "pricing" --json`, using the strongest single word rather than the user's
   phrase. A query is ANDed inside one line, so "pricing model" finds nothing in a call that says
   "hybrid pricing" and "the per-seat model" a minute apart. Narrow with `--folder` or a
   `list --since` if the user said when.
2. Prefer the summary: `meetings show <ref> --summary`. Answer from that if it covers the question.
3. Only if it does not, find the offset with `meetings transcript <ref> | grep -in "pricing"` and
   read that window alone: `meetings transcript <ref> --range 12:00-20:00`.
4. Answer with the meeting title, its date, and a quoted line if the exact wording matters. Never
   read a whole transcript to answer a narrow question.

`meetings actions list --open` across all meetings answers "what do I owe anyone". It reads the
task list out of every write-up, so an action exists exactly when a `- [ ]` line does.

## Workflow 4: migrating a backlog

The CLI infers **nothing**. No date from a filename, no title guess, no mtime fallback. That is your
job, and you do it by reading the files.

1. Walk the dump and group related files. A recording and its notes often share a stem, but not
   always. Open them and decide from the contents.
2. Extract title, date and attendees from what the files **say**, not from what they are called. A
   notes file usually names the date and the people in its first lines.
3. Present a table of everything you found (files, title, date, attendees, folder) and ask the user
   about every case you are unsure of. Do not create a meeting on a guessed date.
4. Create them one at a time, only after the user confirms:
   ```bash
   meetings create \
     --title "Mater-AI intro" \
     --date 2025-11-04T14:00Z \
     --duration 45m \
     --folder "Torch0" \
     --attendees "Will,Sofia Nunes" \
     --audio ~/old/nov4.m4a \
     --summary-file ~/old/nov4-notes.md \
     --source imported \
     --json
   ```
   In plain mode the new ref is the only thing on stdout and the rest goes to stderr, so
   `REF=$(meetings create …)` works; `--json` gives you the whole row. With `--audio` the meeting
   enters `transcribing` and joins the batch queue; without it, it lands at `complete` immediately.
   A meeting with notes and no audio is legal.
5. An old transcript comes in with `--transcript-file`, which reads one of two shapes:
   - **A JSON array** of `{"channel":"mic"|"system","startMs":…,"endMs":…,"text":…}`, the same shape
     a bundle's `transcript.json` has. Only `text` is required. Timings and channels survive, so
     `--range`, `--chunks` and note anchoring all work afterwards.
   - **Anything else**, meaning plain text or markdown, which lands as **one** `mic` segment
     covering the whole meeting. Everything in it then prints as `You:`. If the file has speakers in
     it, convert it to the JSON shape and put the other side on `system`, or the customer's words
     come back attributed to the user.
6. Report what you skipped and why. Never silently drop a file.

For a `.meetingbundle`, the app's own lossless export, use `meetings import <bundle>` instead. It
round-trips exactly and needs no agent. `meetings import <bundle> --dry-run` shows what it would do.

## Command reference

Read:

```
meetings status [--json]
meetings list [--folder <name>] [--since <date>] [--state <state>] [--json]
meetings show <ref> [--notes] [--transcript] [--summary] [--json]
meetings transcript <ref> [--channel mic|system] [--format md|json|srt]
                          [--range <start>-<end>] [--chunks <minutes>] [--json]
meetings search <query> [--folder <name>] [--limit n] [--json]
meetings upcoming [--days n] [--match <text>] [--json]
```

Write:

```
meetings prenotes get <ref>
meetings prenotes add <ref> [<text>|--file <path>|-]     # append
meetings prenotes set <ref> [<text>|--file <path>|-]     # replace
meetings note add <ref> <text> [--at <offset>]           # live notes, anchored to the transcript
meetings note list <ref>
meetings summary set <ref> [--file <path>|-]
meetings actions set <ref> [--file <path>|-]              # rewrites the `- [ ]` lines of the write-up, in place
meetings actions list [--open] [--folder <name>]          # the task items, across every meeting
meetings folder list|create|delete <name> [--force]       # --force: delete a folder that holds meetings
meetings move <ref> --folder <name>
meetings delete <ref> [--yes]                             # no undo; without --yes it only reports
meetings vocab list [--folder <name>] [--source <s>]
meetings vocab add <term> [--folder <name>] [--threshold <0-1>]   # a confidence, not a count
meetings vocab disable|remove <term>
meetings transcript edit <ref> --segment <id> --text <t> [--add-vocab]
meetings config get|set <key> [<value>]                   # get with no key lists every key
meetings export <ref> [--format bundle|md] [--out <dir>] [--with-audio]
meetings create --title <t> --date <d> [--duration <n>] [--folder <name>] [--attendees <list>]
                [--audio <f>] [--transcript-file <f>] [--summary-file <f>] [--prenotes-file <f>]
                [--source imported]
meetings import <bundle> [--folder <name>] [--dry-run]
meetings backup [--out <path>]
meetings skill install [--dry-run]
```

Time formats accepted anywhere an offset is: `12:30`, `1:05:00`, `12m`, `750s`, or bare seconds.
`--since` also takes `2026-08-01`, a full ISO-8601 instant, or a window like `7d`, `36h`, `2w`.

`--out` on `export` is the **directory** to write into, not the name of the thing written. The path
that was actually created is what the command prints, so `BUNDLE=$(meetings export <ref> --out /tmp)`
gives you something `meetings import` can take.

The transcriber is not configurable from the command line: Meetings picks one local model from the
system language and runs it, so there is nothing here to measure or select.

## States

`scheduled` → `recording` → `transcribing` → `ready` → `complete`.

That is the path a **recorded** meeting walks. `ready` means the transcript is final and nobody has
written it up, so `meetings list --state ready` is the user's write-up queue, and setting a summary
is what moves one of those to `complete`.

A meeting from `meetings create` does not walk it. With `--audio` it starts at `transcribing`;
without audio it lands at `complete` on arrival, summary or no summary, and so never appears in
`ready`. Find migrated meetings with `list --since` or `search`, not with the queue.

## Rules

- Never invent a meeting to make a command succeed. Exit 2 means find the right one, or ask.
- Never write to a meeting you picked from more than one candidate without asking.
- Never `cat` a full transcript into your context when `search`, `show --summary` or `--range`
  answers the question.
- Never quote the transcript as verbatim gospel. It is machine transcription, and names and jargon
  come through wrong. If a term looks mangled and matters, say so, and consider
  `meetings vocab add <term>` so the next meeting gets it right.
- Do not delete anything. Two commands destroy data — `meetings folder delete`, which takes the
  folder's vocabulary with it, and `meetings delete <ref>`, which takes a meeting's transcript,
  notes and audio and cannot be undone. Neither is part of any workflow here. Run them only when the
  user has asked for that meeting or that folder to be deleted, in those words; never to tidy up,
  never to fix a mistake you made, and never on a meeting you picked from more than one candidate.
  Run without `--yes` first and show the user what it says will go.
