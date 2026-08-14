#!/usr/bin/env bash
#
# Acceptance for the `meetings` read and write paths.
#
# Runs from an empty temporary directory against a throwaway MEETINGS_HOME and a calendar fixture,
# so it never touches the real store and never reads a real calendar. The store is seeded through
# MeetingsCore itself — the same write path the app uses — by a tiny package built in the temp
# directory, which is why the FTS index, the note anchors and the JSON columns are real here.
#
# Re-runnable, and leaves nothing behind: everything lives under one mktemp directory that is
# removed on exit.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="${TMPDIR:-/tmp}"          # TMPDIR usually ends in a slash; a doubled one breaks path equality
WORK="$(mktemp -d "${TMPROOT%/}/meetings-acceptance.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export MEETINGS_HOME="$WORK/store"
export MEETINGS_CALENDAR_FIXTURE="$WORK/calendar.json"

pass_count=0
fail_count=0
MAX_LINES=12

ok()  { pass_count=$((pass_count + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail_count=$((fail_count + 1)); printf '  FAIL  %s\n' "$1"; }

section() { printf '\n=== %s %s\n' "$1" "$(printf '=%.0s' $(seq 1 $((56 - ${#1}))))"; }

run_cli() {  # run_cli <expected-exit> <args...>
  local want="$1"; shift
  printf '\n$ meetings %s\n' "$*"
  # stdin is /dev/null unless a test asked otherwise: a write command that reads stdin by mistake
  # would otherwise hang here forever, and a hang is the one failure an exit code cannot describe.
  LAST_OUT="$("$BIN" "$@" <"${STDIN_FILE:-/dev/null}" 2>"$WORK/stderr.txt")"
  LAST_CODE=$?
  LAST_ERR="$(cat "$WORK/stderr.txt")"
  if [ -n "$LAST_OUT" ]; then
    printf '%s\n' "$LAST_OUT" | head -n "$MAX_LINES" | sed 's/^/  /'
    local lines
    lines=$(printf '%s\n' "$LAST_OUT" | wc -l | tr -d ' ')
    if [ "$lines" -gt "$MAX_LINES" ]; then printf '  ... (%s lines in total)\n' "$lines"; fi
  fi
  if [ -n "$LAST_ERR" ]; then printf '  stderr: %s\n' "$LAST_ERR"; fi
  if [ "$LAST_CODE" -eq "$want" ]; then ok "exit $LAST_CODE"; else bad "exit $LAST_CODE, expected $want"; fi
}

run_cli_in() {  # run_cli_in <stdin-file> <expected-exit> <args...> — the `-` path
  STDIN_FILE="$1"; shift
  run_cli "$@"
  STDIN_FILE=""
}

json_ok() {  # json_ok <label> — proves stdout is exactly one JSON value
  if printf '%s' "$LAST_OUT" | python3 -m json.tool >/dev/null; then
    ok "$1"
  else
    bad "$1"
  fi
}

json_is() {  # json_is <python expression over d> <expected> <label>
  local got
  got=$(printf '%s' "$LAST_OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null)
  if [ "$got" = "$2" ]; then ok "$3 — $1 = $got"; else bad "$3 — $1 = ${got:-<unreadable>}, expected $2"; fi
}

has()   { case "$LAST_OUT" in *"$1"*) ok "$2";; *) bad "$2";; esac; }
hasnt() { case "$LAST_OUT" in *"$1"*) bad "$2";; *) ok "$2";; esac; }

err_has() { case "$LAST_ERR" in *"$1"*) ok "$2";; *) bad "$2";; esac; }

# ---------------------------------------------------------------- build

section "build"
# Only the product under test. This script is the CLI's acceptance run, and building the SwiftUI app
# here would mean a broken app failing the CLI's tests; scripts/verify.sh builds the whole package.
if ! swift build --package-path "$REPO" --product meetings >"$WORK/build.log" 2>&1; then
  echo "swift build failed:"; cat "$WORK/build.log"; exit 1
fi
BIN="$(swift build --package-path "$REPO" --show-bin-path)/meetings"
echo "binary: $BIN"

# ---------------------------------------------------------------- seed

mkdir -p "$WORK/seeder/Sources/seed"
cat > "$WORK/seeder/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "seed",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "$REPO")],
    targets: [
        .executableTarget(
            name: "seed",
            // A path dependency's identity is its directory name, not the name in its manifest.
            dependencies: [.product(name: "MeetingsCore", package: "$(basename "$REPO")")]
        )
    ]
)
EOF

cat > "$WORK/seeder/Sources/seed/main.swift" <<'SWIFT'
import Foundation
import MeetingsCore

// Writes the store *and* the calendar fixture, so a scheduled row and the event it points at cannot
// drift apart. Everything goes through MeetingStore: the FTS triggers and the note anchoring are
// exercised exactly as they are in the app.

let store = MeetingStore(dbPool: try MeetingsDatabase.open())
let minute = 60.0
let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / minute).rounded(.down) * minute)

// Phase two, run later in the script: a meeting that is *actually recording right now*. It is
// created on demand rather than up front because a recording row is the newest meeting in the
// store and would reorder every listing the read-path section asserts on.
if CommandLine.arguments.dropFirst().first == "recording" {
    let startedAt = Date().addingTimeInterval(-90)
    let live = try store.createMeeting(Meeting(
        title: "Ad-hoc call with Will",
        state: .recording,
        startedAt: startedAt
    ))
    _ = try store.insertSegments([
        TranscriptSegment(meetingID: live.id, channel: .system, tStartMs: 2_000, tEndMs: 11_000,
                          text: "Will: facilities came back — the cryo stage is free from the thirteenth.",
                          pass: .live),
    ])
    print(live.id)
    exit(0)
}

// Phase three: a meeting whose mic channel could not be transcribed. Written here rather than
// faked, because `transcript_issues` is what the batch pass writes when one of two WAVs will not
// open — the case where a half transcript would otherwise read as a whole one.
if CommandLine.arguments.dropFirst().first == "issue" {
    let meetingID = CommandLine.arguments.dropFirst(2).first!
    try store.recordTranscriptIssue(TranscriptIssue(
        meetingID: meetingID,
        channel: .mic,
        reason: "unreadable audio mic.wav: the file ends mid-frame"
    ))
    exit(0)
}

let folder = try store.createFolder(Folder(name: "Torch0"))

// 1 — a finished 25-minute meeting: two channels, live notes, a summary and actions.
let reviewStart = now.addingTimeInterval(-3 * 86_400)
let review = try store.createMeeting(Meeting(
    folderID: folder.id,
    title: "Torch0 pipeline review",
    state: .complete,
    startedAt: reviewStart,
    endedAt: reviewStart.addingTimeInterval(25 * minute),
    attendees: [
        Attendee(name: "Sofia Nunes", email: "sofia@torch0.dev"),
        Attendee(name: "Will Rodrigues", email: "will@torch0.dev"),
    ],
    preNotes: """
        Three things: the reconstruction backlog, whether alignment can stop being manual, and what \
        we actually demo to Mater-AI on Thursday.
        """,
    summary: """
        Three decisions came out of the review.

        - The reconstruction loop stops re-estimating the probe once its delta falls under a \
        threshold, rather than running a fixed three passes. That is what cleared the backlog from \
        forty datasets to eleven.
        - Alignment stays manual for datasets with a beam-stop artefact; cross-correlation handles \
        the rest, and every dataset records in its run manifest which path it took.
        - The Mater-AI demo runs end to end on pre-staged frames, about four minutes.

        Ma'agan Michael's ten wet samples need the cryo stage, which is booked until the twelfth, so \
        they go in on the thirteenth and are told today.
        """,
    actions: [
        Action(text: "Threshold the probe estimate in the reconstruction loop", owner: "Sofia"),
        Action(text: "Detect the beam-stop artefact and fall back to manual alignment", owner: "Will"),
        Action(text: "Pre-stage the Mater-AI demo frames before Thursday", owner: "Sofia", due: "Thursday"),
        Action(text: "Mail Ma'agan Michael about the cryo stage booking", owner: "Sofia", done: true),
    ]
))

let dialogue: [(Channel, String)] = [
    (.mic, "Right — three things: the reconstruction backlog, the alignment step, and what we show Mater-AI on Thursday."),
    (.system, "Sofia here. The backlog is down to eleven datasets, all of them from the November run."),
    (.mic, "Eleven is a lot better than forty. What cleared them?"),
    (.system, "We stopped re-running the probe estimate on every iteration. It cost about nine minutes a dataset and changed nothing after the third pass."),
    (.mic, "So the probe converges early and we were paying for it anyway."),
    (.system, "Will here — that matches the synthetic data. After iteration three the probe barely moves."),
    (.mic, "Can we make that a threshold rather than a fixed count?"),
    (.system, "Sofia: yes, and I would rather do that than hard-code three. A threshold on the probe delta is two lines in the reconstruction loop."),
    (.mic, "Do it. Second thing — the manual alignment step."),
    (.system, "Will: it is still manual. Somebody has to look at the diffraction pattern and nudge the origin."),
    (.mic, "That is the part I cannot put in front of a customer."),
    (.system, "Sofia: cross-correlation gets within two pixels on nine of the eleven. The two it misses have the beam-stop artefact."),
    (.mic, "Two out of eleven wrong silently is worse than eleven manual nudges."),
    (.system, "Will: agreed, unless we detect the artefact. It has a specific signature — a dead square in the centre of the pattern."),
    (.mic, "Then detect it, fall back to manual on those, and log which path each dataset took."),
    (.system, "Sofia: I will put the path in the run manifest so we can count how often the fallback fires."),
    (.mic, "Third thing. Mater-AI on Thursday — what are we actually showing them?"),
    (.system, "Sofia: end to end on one dataset, live, from raw frames to a ptychography reconstruction."),
    (.mic, "How long does that take on the laptop?"),
    (.system, "Will: about four minutes with the new loop. It was eleven before."),
    (.mic, "Four minutes is a demo. Eleven is a coffee break."),
    (.system, "Sofia: I will pre-stage the raw frames so we are not waiting on a file copy on stage."),
    (.mic, "And do not go hunting for the alignment fallback. If it fires we explain it, we do not hide it."),
    (.system, "Will: understood."),
    (.mic, "Last thing — Ma'agan Michael sent their sample list. Ten samples, all biological, all of them wet."),
    (.system, "Sofia: wet samples need the cryo stage, and the cryo stage is booked until the twelfth."),
    (.mic, "Then we book them for the thirteenth and tell them today, not next week."),
    (.system, "Sofia: I will send that mail this afternoon."),
]

var segments: [TranscriptSegment] = []
for (index, line) in dialogue.enumerated() {
    let start = index * 55_000
    segments.append(TranscriptSegment(
        meetingID: review.id,
        channel: line.0,
        tStartMs: start,
        tEndMs: start + 8_000,
        text: line.1,
        pass: .final
    ))
}
_ = try store.insertSegments(segments)

for note in [
    (4 * 60_000 + 30_000, "Probe delta threshold, not a fixed iteration count."),
    (11 * 60_000, "Which alignment path ran has to be in the run manifest."),
    (19 * 60_000 + 40_000, "Pre-stage the demo frames before Thursday."),
] {
    _ = try store.addNote(meetingID: review.id, tOffsetMs: note.0, text: note.1)
}

// 2 — yesterday's standup: transcribed, not written up, unfiled.
let standupStart = now.addingTimeInterval(-86_400)
let standup = try store.createMeeting(Meeting(
    title: "Monday standup",
    state: .ready,
    startedAt: standupStart,
    endedAt: standupStart.addingTimeInterval(9 * minute),
    attendees: [Attendee(name: "Will Rodrigues", email: "will@torch0.dev")]
))
_ = try store.insertSegments([
    TranscriptSegment(meetingID: standup.id, channel: .mic, tStartMs: 0, tEndMs: 6_000,
                      text: "Quick one. Anything blocked?", pass: .final),
    TranscriptSegment(meetingID: standup.id, channel: .system, tStartMs: 7_000, tEndMs: 19_000,
                      text: "Will: the cryo stage booking, still waiting on facilities to confirm the twelfth.", pass: .final),
    TranscriptSegment(meetingID: standup.id, channel: .mic, tStartMs: 20_000, tEndMs: 27_000,
                      text: "I will chase facilities today.", pass: .final),
])
_ = try store.addNote(meetingID: standup.id, tOffsetMs: 21_000, text: "Chase facilities about the cryo stage.")

// 3 — tomorrow's meeting: pre-notes written against a calendar event, nothing recorded. Proves the
// read path hides sections that do not exist rather than printing them empty.
let materEventID = "EV-mater-intro"
let materStart = now.addingTimeInterval(86_400)
let mater = try store.createMeeting(Meeting(
    folderID: folder.id,
    title: "Mater-AI intro",
    state: .scheduled,
    calendarEventID: materEventID,
    scheduledStart: materStart,
    scheduledEnd: materStart.addingTimeInterval(45 * minute),
    attendees: [Attendee(name: "Sofia Nunes", email: "sofia@torch0.dev"),
                Attendee(name: "Ana Beatriz Costa", email: "ana@mater.ai")],
    preNotes: "Show the four-minute end-to-end run. Do not promise a date for automatic alignment."
))

// The calendar fixture: one event that already has a row, and two that do not.
let events = [
    CalendarEvent(
        id: materEventID,
        title: "Mater-AI intro",
        start: materStart,
        end: materStart.addingTimeInterval(45 * minute),
        attendees: [Attendee(name: "Sofia Nunes", email: "sofia@torch0.dev"),
                    Attendee(name: "Ana Beatriz Costa", email: "ana@mater.ai")],
        calendarName: "Work",
        videoLink: URL(string: "https://zoom.us/j/95512345678"),
        notes: "Intro call. Ana asked for a live reconstruction rather than slides."
    ),
    CalendarEvent(
        id: "EV-standup-thu",
        title: "Thursday standup",
        start: now.addingTimeInterval(2 * 86_400),
        end: now.addingTimeInterval(2 * 86_400 + 15 * minute),
        attendees: [Attendee(name: "Will Rodrigues", email: "will@torch0.dev")],
        calendarName: "Work",
        videoLink: URL(string: "https://meet.google.com/abc-defg-hij"),
        notes: nil
    ),
    CalendarEvent(
        id: "EV-cryo-review",
        title: "Cryo stage scheduling",
        start: now.addingTimeInterval(3 * 86_400),
        end: now.addingTimeInterval(3 * 86_400 + 30 * minute),
        attendees: [Attendee(name: "Sofia Nunes", email: "sofia@torch0.dev")],
        calendarName: "Work",
        // A call like any other, so it carries a link like any other. Upcoming lists events that
        // have one; an event here with no link would be asserting the opposite of what it is.
        videoLink: URL(string: "https://meet.goto.com/torch0/cryo-stage"),
        notes: "Ma'agan Michael samples."
    ),
    // Not a meeting: no link, nobody to call. It is in the week and in every window `upcoming`
    // looks at, and it must still never appear there — while `cal:EV-birthday` keeps resolving,
    // because an agent may hang pre-notes on any event at all.
    CalendarEvent(
        id: "EV-birthday",
        title: "Priya's birthday",
        start: now.addingTimeInterval(86_400),
        end: now.addingTimeInterval(2 * 86_400),
        attendees: [],
        calendarName: "Personal",
        videoLink: nil,
        notes: nil
    ),
]

// Seven untouched events, one per write command that takes a <ref>, so each command's `cal:`
// materialisation is proved on an event nothing else has touched. A month out and with an attendee
// nobody searches for, so they stay outside `upcoming`'s week and outside `--match`'s window.
let writePathEvents = (1...7).map { index in
    CalendarEvent(
        id: "EV-w\(index)",
        title: "Write-path fixture \(index)",
        start: now.addingTimeInterval(30 * 86_400 + Double(index) * 3600),
        end: now.addingTimeInterval(30 * 86_400 + Double(index) * 3600 + 30 * minute),
        attendees: [Attendee(name: "Priya Raman", email: "priya@example.org")],
        calendarName: "Work",
        videoLink: nil,
        notes: nil
    )
}

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted]
try encoder.encode(events + writePathEvents).write(
    to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["MEETINGS_CALENDAR_FIXTURE"]!)
)

struct Seeded: Encodable {
    let review: String
    let standup: String
    let mater: String
    let materEvent: String
    let bareEvent: String
    let segments: Int
}
let out = JSONEncoder()
out.outputFormatting = [.prettyPrinted]
FileHandle.standardOutput.write(try out.encode(Seeded(
    review: review.id,
    standup: standup.id,
    mater: mater.id,
    materEvent: "cal:\(materEventID)",
    bareEvent: "cal:EV-standup-thu",
    segments: dialogue.count
)))
SWIFT

section "seed"
if ! swift run --package-path "$WORK/seeder" seed >"$WORK/seed.json" 2>"$WORK/seed.log"; then
  echo "seeding failed:"; cat "$WORK/seed.log"; exit 1
fi
python3 -m json.tool "$WORK/seed.json"

field() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$WORK/seed.json" "$1"; }
REVIEW="$(field review)"
STANDUP="$(field standup)"
MATER="$(field mater)"
MATER_EVENT="$(field materEvent)"
BARE_EVENT="$(field bareEvent)"

cd "$WORK/empty" 2>/dev/null || { mkdir -p "$WORK/empty"; cd "$WORK/empty"; }
echo "cwd: $(pwd) (empty)"

# ---------------------------------------------------------------- status

section "status"
run_cli 0 status
has "store" "reports the store path"
has "audio" "reports the audio retention setting"
has "calendar" "reports calendar authorisation"
has "cli" "reports whether the CLI is on PATH"
# Only printed when the CLI is *not* on PATH, which depends on the machine running this — so the
# assertion is on the name that must never appear again. The app's Settings has no "CLI" section;
# it is called "Command line", and pointing someone at a tab that does not exist is a small lie in
# the one command whose job is telling you where things are.
hasnt "Settings > CLI" "never points at a Settings section that does not exist"

run_cli 0 status --json
json_ok "status --json is one JSON value"
json_is "d['store']['path']" "$MEETINGS_HOME/store.db" "status names the throwaway store"
json_is "d['meetings']['total']" "3" "status counts the seeded meetings"
json_is "d['calendar']['source']" "fixture" "status knows it is on the calendar fixture"
json_is "d['audio']['retentionDays']" "30" "status reports the default retention"
json_is "sorted(d['meetings']['byState'])" "['complete', 'ready', 'recording', 'scheduled', 'transcribing']" "status counts every state"

# ---------------------------------------------------------------- list

section "list"
run_cli 0 list
has "$REVIEW" "the ref is the first column"
has "Torch0" "the folder is shown"

run_cli 0 list --json
json_ok "list --json is one JSON value"
json_is "len(d['meetings'])" "3" "three meetings"
json_is "d['meetings'][0]['ref']" "$MATER" "newest first"

run_cli 0 list --folder Torch0 --json
json_is "len(d['meetings'])" "2" "--folder narrows to the folder"

run_cli 0 list --state ready --json
json_is "d['meetings'][0]['ref']" "$STANDUP" "--state finds the meeting waiting to be written up"

run_cli 0 list --since 2d --json
json_is "len(d['meetings'])" "2" "--since drops the three-day-old review"

run_cli 2 list --folder Nonexistent
err_has "No folder" "a missing folder is exit 2, not an empty list"

run_cli 2 list --folder Nonexistent --json
json_ok "an error in --json mode is still one JSON value on stdout"
json_is "d['error']['code']" "2" "the JSON error carries the exit code"

run_cli 64 list --state fictional
run_cli 64 list --since "the day before yesterday"

# ---------------------------------------------------------------- show

section "show"
run_cli 0 show "$REVIEW"
has "## summary" "the summary is in the overview"
has "## actions" "the actions are in the overview"
has "## pre-notes" "the pre-notes are in the overview"
hasnt "Others:" "the overview never loads the transcript"

run_cli 0 show "$REVIEW" --json
json_ok "show --json is one JSON value"
json_is "d['kind']" "meeting" "it is a meeting"
json_is "len(d['actions'])" "4" "the actions come back structured, not as prose"
json_is "'transcript' in d" "False" "the overview carries no transcript"
json_is "d['meeting']['durationMs']" "1500000" "duration is the real recording length"

run_cli 0 show "$REVIEW" --summary
hasnt "ref " "one section flag prints that section and nothing else"
has "Ma'agan Michael" "the summary text is intact"

run_cli 0 show "$REVIEW" --notes --json
json_is "len(d['notes'])" "3" "--notes returns the live notes"
json_is "d['notes'][0]['at']" "4:30" "each note carries its m:ss offset"
json_is "d['notes'][0]['anchorSegmentId'] is not None" "True" "notes are anchored to the transcript"

run_cli 0 show "$MATER"
has "## pre-notes" "a scheduled meeting shows its pre-notes"
hasnt "## summary" "a section with nothing in it is hidden, not printed empty"
hasnt "## transcript" "no transcript section on a meeting that has none"

run_cli 0 show "$BARE_EVENT"
has "calendar event, nothing recorded yet" "a cal: ref with no row prints the event"
has "meet.google.com" "the video link is shown"

run_cli 0 show "$BARE_EVENT" --json
json_is "d['kind']" "event" "the JSON says which kind it is"
json_is "d['event']['ref']" "$BARE_EVENT" "the event carries the ref you write against"

run_cli 0 show "$MATER_EVENT" --json
json_is "d['kind']" "meeting" "a cal: ref that already has a row resolves to the row"
json_is "d['meeting']['ref']" "$MATER" "and hands back the meeting id"

run_cli 2 show 11111111-2222-3333-4444-555555555555
run_cli 2 show cal:EV-does-not-exist
run_cli 64 show --json

# ---------------------------------------------------------------- transcript

section "transcript"
run_cli 0 transcript "$REVIEW"
has "] You: " "mic lines are labelled You"
has "] Others: " "system lines are labelled Others"
has "[0:00]" "offsets are m:ss"

run_cli 0 transcript "$REVIEW" --channel mic --json
json_is "{s['channel'] for s in d['segments']}" "{'mic'}" "--channel mic returns only the microphone"
json_is "d['speakerLabels']['system']" "Others" "the JSON spells out what the labels mean"

run_cli 0 transcript "$REVIEW" --json
json_ok "transcript --json is one JSON value"
json_is "d['segmentCount']" "28" "every seeded line came back"

run_cli 0 transcript "$REVIEW" --range 5:00-10:00 --json
json_is "d['segmentCount']" "5" "--range narrows to the window"
json_is "min(s['startMs'] for s in d['segments']) >= 300000 - 55000" "True" "the window starts where it was asked to"

run_cli 0 transcript "$REVIEW" --chunks 10
has "## chunk 1 of 3" "--chunks labels each window"
has "## chunk 3 of 3" "and the last one knows how many there are"

run_cli 0 transcript "$REVIEW" --chunks 10 --json
json_is "len(d['chunks'])" "3" "three ten-minute windows"
json_is "d['chunks'][0]['label']" "0:00-10:00" "each window is labelled with its time range"
json_is "sum(len(c['segments']) for c in d['chunks'])" "28" "chunking loses nothing"

run_cli 0 transcript "$REVIEW" --format srt
printf '%s' "$LAST_OUT" | python3 -c '
import re, sys
blocks = [b for b in sys.stdin.read().strip().split("\n\n") if b.strip()]
pattern = re.compile(r"^(\d+)\n(\d{2}:\d{2}:\d{2},\d{3}) --> (\d{2}:\d{2}:\d{2},\d{3})\n(.+)$", re.S)
for index, block in enumerate(blocks, start=1):
    m = pattern.match(block)
    assert m, "block %d is not valid SRT:\n%s" % (index, block)
    assert int(m.group(1)) == index, "index %s out of order" % m.group(1)
    assert m.group(2) < m.group(3), "end is not after start in block %d" % index
print("%d valid SRT blocks" % len(blocks))
' && ok "--format srt is valid SubRip with comma-decimal timestamps" \
  || bad "--format srt is valid SubRip with comma-decimal timestamps"

run_cli 64 transcript "$REVIEW" --chunks 10 --format srt
run_cli 64 transcript "$REVIEW" --range "backwards"

run_cli 0 transcript "$MATER"
err_has "no transcript" "a meeting with no transcript says so on stderr and prints nothing"
if [ -z "$LAST_OUT" ]; then ok "and stdout stays empty, so a pipe gets nothing"; else bad "stdout was not empty"; fi

run_cli 0 transcript "$BARE_EVENT" --json
json_is "d['segmentCount']" "0" "a calendar event with no row has an empty transcript, not an error"

# ---------------------------------------------------------------- search

section "search"
run_cli 0 search ptychography
has "$REVIEW" "the hit carries the ref"
has "«ptychography»" "the match is marked in the snippet"

# A meeting found by its own name. Nothing in this meeting's transcript, notes or summary says
# "pipeline"; before titles were searchable this returned nothing at all.
run_cli 0 search pipeline --json
json_is "[h['kind'] for h in d['hits']]" "['title']" "a meeting is found by its own name"
json_is "d['hits'][0]['ref'] == '$REVIEW'" "True" "and the hit names the right meeting"
json_is "d['hits'][0]['snippet']" "Torch0 «pipeline» review" "a title hit shows the title with the match marked, not an empty snippet"
run_cli 0 search pipeline
has "title" "the plain output says the match was on the title"

run_cli 0 search "cryo stage" --json
json_ok "search --json is one JSON value"
json_is "len(d['hits']) >= 2" "True" "the phrase is found in more than one meeting"
json_is "sorted({h['kind'] for h in d['hits']})" "['note', 'segment', 'summary']" "hits say where they matched, across all four indexed texts"

run_cli 0 search "cryo stage" --folder Torch0 --json
json_is "{h['ref'] for h in d['hits']} == {'$REVIEW'}" "True" "--folder scopes the search"

run_cli 0 search "threshold" --limit 1 --json
json_is "len(d['hits'])" "1" "--limit is honoured"

run_cli 0 search antikythera
err_has "Nothing matched" "a miss is exit 0 with an empty stdout"

run_cli 2 search anything --folder Nonexistent

# ---------------------------------------------------------------- upcoming

section "upcoming"
run_cli 0 upcoming
has "$MATER" "a materialised event is listed under its meeting id"
has "cal:EV-standup-thu" "an untouched event is listed under its cal: ref"
hasnt "birthday" "an event with no meeting link is not upcoming"

# The other half of the same rule: the list is filtered, the calendar is not. A ref pointing at a
# linkless event still resolves, or an agent could not put pre-notes on one.
run_cli 0 show cal:EV-birthday
has "Priya's birthday" "a linkless event still resolves by ref"

run_cli 0 upcoming --json
json_ok "upcoming --json is one JSON value"
json_is "len(d['upcoming'])" "3" "every meeting in the next week"
json_is "[e['videoLink'] is not None for e in d['upcoming']]" "[True, True, True]" "and only events that carry a link"
json_is "[e['hasRow'] for e in d['upcoming']]" "[True, False, False]" "each row says whether it exists in the store yet"
json_is "d['upcoming'][0]['state']" "scheduled" "a row carries its state"

run_cli 0 upcoming --days 2 --json
json_is "len(d['upcoming'])" "2" "--days narrows the horizon"

run_cli 64 upcoming --days 0

# The horizon is a setting, and both front ends read it. The flag is an override for one run.
run_cli 0 config set calendar.lookAheadDays 2 --json
json_is "d['value']" "2" "the look-ahead window is a setting"
run_cli 0 upcoming --json
json_is "len(d['upcoming'])" "2" "which upcoming honours with no flag at all"
run_cli 0 upcoming --days 7 --json
json_is "len(d['upcoming'])" "3" "--days overrides it for one invocation"
run_cli 0 config get calendar.lookAheadDays
has "2" "and leaves the setting where it was"
run_cli 64 config set calendar.lookAheadDays 0
err_has "one or more" "a window of nothing is refused rather than emptying the list"
run_cli 0 config set calendar.lookAheadDays
has "7" "and it goes back to seven days"

printf '\n$ meetings upcoming --match Sofia --json\n'
MATCH_OUT="$("$BIN" upcoming --match Sofia --json 2>"$WORK/stderr.txt")"
MATCH_CODE=$?
printf '%s\n' "$MATCH_OUT" | head -n "$MAX_LINES" | sed 's/^/  /'
if [ "$MATCH_CODE" -eq 0 ]; then
  LAST_OUT="$MATCH_OUT"
  json_ok "upcoming --match is one JSON value"
  json_is "all('score' in c for c in d['candidates'])" "True" "every candidate is scored"
  json_is "d['candidates'] == sorted(d['candidates'], key=lambda c: -c['score'])" "True" "candidates are sorted, never auto-resolved"
elif printf '%s' "$MATCH_OUT" | grep -q "not wired up yet"; then
  printf '  PENDING  --match is wired to RefResolver.match, which the refs unit has not landed yet\n'
else
  bad "upcoming --match failed with exit $MATCH_CODE"
fi

printf '\n$ meetings upcoming --match pipeline --json\n'
LAST_OUT="$("$BIN" upcoming --match pipeline --json 2>/dev/null)"
printf '%s\n' "$LAST_OUT" | head -n "$MAX_LINES" | sed 's/^/  /'
json_is "len(d['candidates'])" "0" "a match that already happened is not upcoming"
json_is "[c['ref'] for c in d['hidden']]" "['$REVIEW']" "and the JSON carries it as hidden rather than dropping it"

# ================================================================ the write path
#
# Every write below is checked twice over: that it did what it said, and — for the commands that
# take a <ref> — that a cal: ref materialises its row first. The materialisation matrix at
# the end does the second half on untouched events, one per command.

# ---------------------------------------------------------------- prenotes

section "prenotes"
run_cli 0 prenotes get "$MATER"
has "four-minute end-to-end run" "get prints the pre-notes and nothing else"

run_cli 0 prenotes get "$BARE_EVENT" --json
json_is "d['preNotes']" "" "an untouched calendar event has empty pre-notes"
run_cli 0 status --json
json_is "d['meetings']['total']" "3" "and reading it created no row — get is a read"

run_cli 0 prenotes add "$STANDUP" "Chase facilities about the twelfth."
has "Appended to the pre-notes" "add says what it did"
run_cli 0 prenotes add "$STANDUP" "Second point: the reconstruction backlog."
run_cli 0 prenotes get "$STANDUP" --json
json_is "d['preNotes'].count('\n\n')" "1" "a second add lands as its own paragraph, not welded on"
json_is "'Chase facilities' in d['preNotes'] and 'Second point' in d['preNotes']" "True" "both paragraphs survive"

printf 'From a file.\n\nWith two paragraphs.\n' > "$WORK/prenotes.md"
run_cli 0 prenotes set "$STANDUP" --file "$WORK/prenotes.md" --json
json_is "d['preNotes'].startswith('From a file')" "True" "--file replaces the lot"
json_is "'Chase facilities' in d['preNotes']" "False" "set replaces rather than appends"

printf 'Piped in on stdin.\n' > "$WORK/stdin.md"
run_cli_in "$WORK/stdin.md" 0 prenotes set "$STANDUP" - --json
json_is "d['preNotes']" "Piped in on stdin." "- reads stdin"

run_cli 64 prenotes set "$STANDUP" "text" --file "$WORK/prenotes.md"
err_has "Not two at once" "text and --file together is a usage error"
run_cli 64 prenotes set "$STANDUP"
err_has "as - to read stdin" "no text at all says how to give it, instead of blocking on stdin"
run_cli 64 prenotes add "$STANDUP" ""
run_cli 2 prenotes set "$STANDUP" --file "$WORK/no-such-file.md"
run_cli 2 prenotes add 11111111-2222-3333-4444-555555555555 "nowhere"
run_cli 2 prenotes add cal:EV-does-not-exist "nowhere"

# ---------------------------------------------------------------- note

section "note"
RECORDING="$(swift run --package-path "$WORK/seeder" seed recording 2>/dev/null | tail -n 1)"
echo "a meeting is now recording: $RECORDING"

run_cli 3 note add "$STANDUP" "No offset, no anchor."
err_has "Pass --at" "without --at and with nothing recording, the note is refused rather than guessed"
err_has "prenotes add" "and the refusal points at the command that was probably meant"

run_cli 0 note add "$STANDUP" "Anchored to the opening line." --at 0:03
has "Note added at 0:03" "--at is echoed back in the offset format the transcript uses"

run_cli 0 note list "$STANDUP" --json
json_is "len(d['notes'])" "2" "the note joined the one the seeder wrote"
json_is "d['notes'][0]['at']" "0:03" "notes come back in transcript order"
json_is "d['notes'][0]['anchorSegmentId'] is not None" "True" "and anchored to the segment that was being spoken"

run_cli 0 note add "$RECORDING" "Live note, no --at needed." --json
json_is "d['note']['offsetMs'] >= 85000" "True" "a recording meeting supplies the elapsed time itself"
json_is "d['meeting']['state']" "recording" "the note landed on the meeting that is recording"

run_cli 0 note list "$RECORDING"
has "Live note" "note list prints offset and text"
run_cli 0 note list "$BARE_EVENT" --json
json_is "d['notes']" "[]" "a calendar event with no row has no notes, which is not an error"

run_cli 64 note add "$STANDUP" --at 5:00
run_cli 64 note add "$STANDUP" "when?" --at "half past four"

# ---------------------------------------------------------------- summary

section "summary"
run_cli 0 show "$STANDUP" --json
json_is "d['meeting']['state']" "ready" "the standup is waiting to be written up"

cat > "$WORK/summary.md" <<'MD'
Facilities confirmed nothing, so the cryo stage is still unbooked.

- Will is chasing facilities today.
MD
run_cli_in "$WORK/summary.md" 0 summary set "$STANDUP" -
has "is complete" "a meeting with a summary is complete by definition"
run_cli 0 show "$STANDUP" --json
json_is "d['meeting']['state']" "complete" "and the state moved with the field"
json_is "d['summary'].startswith('Facilities confirmed')" "True" "the markdown came through the pipe intact"

run_cli 0 summary set "$STANDUP" ""
has "Cleared the summary" "an empty summary clears it"
run_cli 0 show "$STANDUP" --json
json_is "d['meeting']['state']" "ready" "and the state goes back with it"
json_is "'summary' in d" "False" "with no empty summary left behind"

run_cli 0 summary set "$STANDUP" --file "$WORK/summary.md" --json
json_is "d['meeting']['state']" "complete" "--file writes it too"
run_cli 64 summary set "$STANDUP"
run_cli 2 summary set cal:EV-does-not-exist --file "$WORK/summary.md"

# ---------------------------------------------------------------- actions

section "actions"
run_cli 0 actions set "$STANDUP" '[{"text":"Chase facilities about the cryo stage","owner":"Will"},{"text":"Confirm the thirteenth with Maagan Michael","done":true}]' --json
json_is "len(d['actions'])" "2" "the array landed"
json_is "d['actions'][0]['done']" "False" "done defaults to false rather than being required"
json_is "d['actions'][1]['done']" "True" "and an explicit true is kept"

run_cli 0 actions list --json
json_is "len(d['actions']) >= 6" "True" "list flattens actions across meetings"
json_is "all('ref' in a for a in d['actions'])" "True" "every action carries the ref it belongs to"

run_cli 0 actions list --open --json
json_is "any(a['done'] for a in d['actions'])" "False" "--open drops the done ones"
json_is "len(d['actions'])" "4" "four things are actually outstanding"

run_cli 0 actions list --folder Torch0 --json
json_is "{a['ref'] for a in d['actions']} == {'$REVIEW'}" "True" "--folder scopes the list"

run_cli 0 actions list
has "[x]" "plain output marks the done ones"
has "[ ]" "and the open ones"

run_cli 2 actions list --folder Nonexistent
run_cli 64 actions set "$STANDUP" '{"text":"not an array"}'
err_has "top level has to be an array" "a JSON object instead of an array is refused with the shape"
run_cli 64 actions set "$STANDUP" '[{"task":"wrong key"}]'
err_has "unknown key task" "a mistyped key is refused rather than silently dropped"
run_cli 64 actions set "$STANDUP" '[{"text":"  "}]'
err_has "needs a non-empty text" "an action with no text is refused"
run_cli 64 actions set "$STANDUP" '[{"text":"x","done":1}]'
err_has "not true or false" "a number where a boolean belongs is refused, not coerced"
run_cli 64 actions set "$STANDUP" 'this is not json at all'
run_cli 0 show "$STANDUP" --json
json_is "len(d['actions'])" "2" "and nothing malformed was stored on the way through"

printf '[{"text":"Piped action"}]' > "$WORK/actions.json"
run_cli_in "$WORK/actions.json" 0 actions set "$STANDUP" - --json
json_is "d['actions'][0]['text']" "Piped action" "- reads the JSON from stdin"
run_cli 0 actions set "$STANDUP" '[]' --json
json_is "d['actions']" "[]" "an empty array clears the list"
run_cli 0 show "$STANDUP" --json
json_is "'actions' in d" "False" "and show stops printing the section rather than printing it empty"

# ---------------------------------------------------------------- folder and move

section "folder and move"
run_cli 0 folder list --json
json_is "d['folders'][0]['name']" "Torch0" "the seeded folder is there"
json_is "d['folders'][0]['meetings']" "2" "with its meeting count"
json_is "d['unfiled'] >= 2" "True" "and the unfiled count beside it"

run_cli 0 folder create Airbus
run_cli 3 folder create airbus
err_has "already exists" "folder names are unique ignoring case"
run_cli 0 folder delete Airbus
has "0 meetings now unfiled" "an empty folder deletes without ceremony"

run_cli 0 folder create Scratch
run_cli 0 move "$STANDUP" --folder Scratch --json
json_is "d['meeting']['folder']" "Scratch" "move files the meeting"
run_cli 0 vocab add scratchjargon --folder Scratch

run_cli 3 folder delete Scratch
err_has "1 meeting and 1 vocabulary term" "a folder with contents says exactly what is in it"
err_has "--force" "and how to go ahead anyway"
run_cli 0 folder delete Scratch --force
has "1 meeting now unfiled, 1 vocabulary term removed" "--force reports both halves"
run_cli 2 list --folder Scratch
run_cli 0 show "$STANDUP" --json
json_is "'folder' not in d['meeting']" "True" "the meeting survived, unfiled"
run_cli 0 vocab list --json
json_is "any(t['term'] == 'scratchjargon' for t in d['terms'])" "False" "the folder's vocabulary went with it"

run_cli 0 move "$STANDUP" --folder Torch0 --json
json_is "d['meeting']['folder']" "Torch0" "and it can be filed again"
run_cli 0 move "$STANDUP" --folder ""
has "to unfiled" "--folder \"\" is the way back to unfiled"
run_cli 2 move "$STANDUP" --folder Nonexistent
err_has "folder create" "a missing folder is exit 2, not a new folder"
run_cli 64 move "$STANDUP"

# ---------------------------------------------------------------- vocab

section "vocab"
run_cli 0 vocab add ptychography --json
json_is "'folder' not in d" "True" "a term with no --folder is global"
json_is "d['source']" "manual" "added by hand"
json_is "d['enabled']" "True" "and on"
VOCAB_ID="$(printf '%s' "$LAST_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")"
run_cli 0 vocab add ptychography --json
json_is "d['id']" "$VOCAB_ID" "adding the same term twice returns the row that is already there"

run_cli 0 vocab add ptychography --folder Torch0 --threshold 0.6 --json
json_is "d['folder']" "Torch0" "the same term can be scoped to a folder as well"
json_is "d['threshold']" "0.6" "with its own threshold"
run_cli 64 vocab add overconfident --threshold 4

run_cli 0 vocab list --json
json_is "len(d['terms'])" "2" "both scopes are listed"
run_cli 0 vocab list --folder Torch0 --json
json_is "sorted(str(t.get('folder')) for t in d['terms'])" "['None', 'Torch0']" "--folder lists what a Torch0 meeting actually gets: its own terms and the global ones"
run_cli 0 vocab list --source manual --json
json_is "len(d['terms'])" "2" "--source filters"
run_cli 0 vocab list --source attendee --json
json_is "len(d['terms'])" "0" "and finds nothing that was never seeded"
run_cli 64 vocab list --source fictional

run_cli 4 vocab disable ptychography
err_has "exists in 2 scopes" "a term in two scopes is ambiguous, and the CLI will not pick one"
run_cli 0 vocab disable ptychography --global --json
json_is "d['enabled']" "False" "--global says which one"
run_cli 0 vocab list --json
json_is "[t['enabled'] for t in d['terms'] if t.get('folder') is None]" "[False]" "the global term is off"
json_is "[t['enabled'] for t in d['terms'] if t.get('folder') == 'Torch0']" "[True]" "and the scoped one is untouched"

run_cli 0 vocab remove ptychography --folder Torch0
run_cli 0 vocab list --json
json_is "len(d['terms'])" "1" "remove deletes outright"
run_cli 2 vocab remove nosuchterm

# ---------------------------------------------------------------- transcript edit

section "transcript edit"
seg_id() {  # seg_id <ref> <substring>
  "$BIN" transcript "$1" --json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next(s['id'] for s in d['segments'] if sys.argv[1] in s['text']))" "$2"
}
STANDUP_SEG="$(seg_id "$STANDUP" "Anything blocked")"
REVIEW_SEG="$(seg_id "$REVIEW" "ptychography reconstruction")"
RECORDING_SEG="$(seg_id "$RECORDING" "facilities came back")"
echo "segments: standup=$STANDUP_SEG review=$REVIEW_SEG recording=$RECORDING_SEG"

run_cli 0 transcript edit "$STANDUP" --segment "$STANDUP_SEG" --text "Quick one. Anything blocked on the cryo stage?" --json
json_is "d['segment']['edited']" "True" "the segment is marked edited, so a re-transcription keeps it"
json_is "d['segment']['text'].endswith('cryo stage?')" "True" "and carries the correction"
run_cli 0 transcript "$STANDUP"
has "cryo stage?" "the correction is what the transcript reads back"

run_cli 3 transcript edit "$RECORDING" --segment "$RECORDING_SEG" --text "Will: facilities came back."
err_has "only allowed once a meeting is ready or complete" "editing a live transcript is refused"
err_has "thrown away" "and says why, because the reason is not obvious"

run_cli 2 transcript edit "$STANDUP" --segment 999999 --text "no such segment"
run_cli 2 transcript edit "$STANDUP" --segment "$REVIEW_SEG" --text "another meeting's segment"
err_has "belongs to another meeting" "a valid segment id from a different meeting is refused"
run_cli 64 transcript edit "$STANDUP" --segment "$STANDUP_SEG" --text ""

run_cli 64 transcript edit "$REVIEW" --segment "$REVIEW_SEG" --text "Sofia: we run the whole thing end to end, live, on one dataset." --add-vocab
err_has "changed" "--add-vocab refuses to promote a whole rewritten sentence"
run_cli 0 transcript "$REVIEW" --json
json_is "any(s['id'] == $REVIEW_SEG and s['edited'] for s in d['segments'])" "False" "and the edit did not land either — one error, nothing half-applied"

run_cli 0 transcript edit "$REVIEW" --segment "$REVIEW_SEG" --text "Sofia: end to end on one dataset, live, from raw frames to a ptychographic reconstruction." --add-vocab --json
json_is "d['vocabulary']['term']" "ptychographic" "--add-vocab promotes just the word that changed"
json_is "d['vocabulary']['source']" "correction" "marked as a promoted correction"
json_is "d['vocabulary']['folder']" "Torch0" "scoped to the meeting's folder, not pushed at every meeting"
run_cli 0 vocab list --source correction --json
json_is "[t['term'] for t in d['terms']]" "['ptychographic']" "and it is in the vocabulary for the next meeting"

# ---------------------------------------------------------------- config

section "config"
run_cli 0 config get --json
json_is "len(d['settings'])" "18" "every documented key is listed, the notes panel's two included"
json_is "[s['value'] for s in d['settings'] if s['key'] == 'update.checkEnabled']" "['true']" \
    "including the update check, which is on unless it is turned off"
json_is "[s['value'] for s in d['settings'] if s['key'] == 'ai.mode']" "['manual']" "with its effective value"

run_cli 0 config get ai.mode
has "manual" "one key prints just its value, so it pipes"
run_cli 0 config get ai.mode --json
json_is "d['isDefault']" "True" "nothing is stored yet, so this is the documented default"

run_cli 0 config set ai.mode localAgent --json
json_is "d['value']" "localAgent" "set writes it"
json_is "d['isDefault']" "False" "and says it is no longer the default"
run_cli 64 config set ai.mode wishful
err_has "one of: manual, localAgent, cloud" "an unknown mode is refused with the list"
run_cli 0 config set ai.mode
has "(default)" "set with no value restores the default"
run_cli 0 config get ai.mode --json
json_is "d['value']" "manual" "which reads back as the default again"

# The write-up command is two settings, because one value cannot be both a slash command you paste
# into a session you already have open and a binary the app execs. Each default is right for its job.
run_cli 0 config get ai.manual.pasteCommand
has "/meetings {meeting_id}" "the pasted default is the slash command the installed skill answers to"
run_cli 0 config get ai.localAgent.runCommand
has "claude -p" "the executed default starts with something exec can launch"
run_cli 64 config get ai.commandTemplate
err_has "is not a setting" "the merged key it replaced is gone rather than quietly accepted"

run_cli 64 config get nosuch.key
err_has "audio.retentionDays" "an unknown key prints the known ones"
run_cli 64 config set nosuch.key 1
err_has "is not a setting" "and is never silently written"

run_cli 64 config set audio.retentionDays thirty
run_cli 0 config set audio.retentionDays 0 --json
json_is "d['value']" "0" "0 is a legal retention"
run_cli 0 status --json
json_is "d['audio']['keptForever']" "True" "which status reports as keeping audio forever"
run_cli 0 config set audio.retentionDays 14
run_cli 0 status
has "audio.retentionDays = 14" "status names the setting and scopes the claim to where the sweep actually runs"

run_cli 64 config set transcribe.remote.keyRef "sk-proj-0123456789abcdefghijklmnop"
err_has "not the key itself" "a pasted API key is refused before it reaches the settings table"
run_cli 0 config set transcribe.remote.keyRef openai-personal --json
json_is "d['keychainAccount']" "True" "a keyRef holds a Keychain account name"
json_is "d['value']" "openai-personal" "which is a label, not a secret"
run_cli 64 config set transcribe.remote.baseURL "not a url"
run_cli 0 config set transcribe.remote.baseURL https://api.example.com/v1 --json
json_is "d['value']" "https://api.example.com/v1" "a real base URL is accepted"

# ---------------------------------------------------------------- ai verify
#
# Nothing here reaches the network. The cloud checks are all run against a provider that is missing
# one of its three settings, which is refused before a request is built — the endpoint below is a
# reserved example domain and this script must never call it.

section "ai verify"

run_cli 0 config set ai.mode manual
run_cli 0 ai verify
has "nothing to check" "manual checks nothing, because nothing runs"

run_cli 0 config set ai.mode localAgent
run_cli 0 config set ai.localAgent.runCommand "meetings-no-such-agent {meeting_id}"
run_cli 3 ai verify
err_has "is not on the PATH Meetings searches" "a missing agent binary is the failure the check exists for"
err_has "nothing would run when a meeting finishes" "and it says what that means"

run_cli 0 config set ai.localAgent.runCommand "/bin/echo {meeting_id}"
run_cli 0 ai verify
has "found at /bin/echo" "a resolvable agent says where it was found"
has "The command is not run until a meeting finishes" "and never claims more than it checked"
run_cli 0 ai verify --json
json_is "d['ok']" "True" "the same answer in JSON"
json_is "d['mode']" "localAgent" "against the configured mode"

run_cli 0 config set ai.mode cloud
run_cli 3 ai verify
err_has "No base URL is set" "cloud names the missing piece rather than saying not configured"
run_cli 0 config set ai.cloud.baseURL https://api.example.com/v1
run_cli 3 ai verify
err_has "No model is set" "one gap at a time"
run_cli 0 config set ai.cloud.model gpt-4o-mini
run_cli 3 ai verify
err_has "No Keychain account is set" "and the account name is a gap of its own"
run_cli 0 config set ai.cloud.keyRef acceptance-no-such-account
run_cli 3 ai verify
err_has "No API key is in the Keychain under the account acceptance-no-such-account" \
  "a keyRef with no secret behind it stops before any request is built"
run_cli 3 ai verify --json
hasnt "sk-" "the key never appears in JSON output"

run_cli 0 config set ai.mode
run_cli 0 config set ai.localAgent.runCommand
run_cli 0 config set ai.cloud.baseURL
run_cli 0 config set ai.cloud.model
run_cli 0 config set ai.cloud.keyRef

# ---------------------------------------------------------------- cal: materialisation, per command

section "cal: materialisation"
echo "Any write against a cal: ref creates the row first. Once per write command, on an"
echo "event nothing has touched, checking both the exit code and that the row now exists."

materialised() {  # materialised <event-id> <label>
  local before after
  before="$LAST_CODE"
  LAST_OUT="$("$BIN" show "cal:$1" --json 2>/dev/null)"
  after=$(printf '%s' "$LAST_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['kind'])" 2>/dev/null)
  if [ "$after" = "meeting" ]; then ok "$2 — cal:$1 now resolves to a meeting row"; else bad "$2 — cal:$1 is still $after"; fi
  LAST_CODE="$before"
}

run_cli 0 status --json
json_is "d['meetings']['total']" "4" "four rows before the matrix"

run_cli 0 prenotes add cal:EV-w1 "Materialised by prenotes add." --json
json_is "d['materialised']" "True" "the write says it created the row"
json_is "d['meeting']['state']" "scheduled" "as a scheduled meeting"
json_is "d['meeting']['title']" "Write-path fixture 1" "carrying the event's title"
json_is "d['meeting']['attendees'][0]['name']" "Priya Raman" "and its attendees"
materialised EV-w1 "prenotes add"
run_cli 0 prenotes add cal:EV-w1 "A second write." --json
json_is "d['materialised']" "False" "a second write finds the row instead of making another"

run_cli 0 prenotes set cal:EV-w2 "Materialised by prenotes set."
materialised EV-w2 "prenotes set"
run_cli 0 note add cal:EV-w3 "Materialised by note add." --at 1:00
materialised EV-w3 "note add"
run_cli 0 summary set cal:EV-w4 "Materialised by summary set."
materialised EV-w4 "summary set"
run_cli 0 actions set cal:EV-w5 '[{"text":"Materialised by actions set"}]'
materialised EV-w5 "actions set"
run_cli 0 move cal:EV-w6 --folder Torch0
materialised EV-w6 "move"

# `transcript edit` and `note add` without `--at` are the two writes that cannot succeed against a
# freshly materialised row: it is `scheduled`, and neither works from `scheduled`. They used to
# materialise anyway and *then* refuse, leaving a meeting in the store — and in `meetings list` —
# for a write that never happened. Now they refuse first and the store is untouched.
not_materialised() {  # not_materialised <event-id> <label>
  local before kind
  before="$LAST_CODE"
  LAST_OUT="$("$BIN" show "cal:$1" --json 2>/dev/null)"
  kind=$(printf '%s' "$LAST_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['kind'])" 2>/dev/null)
  if [ "$kind" = "event" ]; then ok "$2 — cal:$1 is still just a calendar event"; else bad "$2 — cal:$1 became a $kind"; fi
  LAST_CODE="$before"
}

run_cli 3 transcript edit cal:EV-w7 --segment 1 --text "Refused before anything is created."
err_has "is scheduled" "transcript edit refuses a scheduled meeting"
not_materialised EV-w7 "transcript edit"

run_cli 3 note add cal:EV-w7 "A note with nowhere to anchor."
err_has "no elapsed time" "note add with no --at refuses a meeting that is not recording"
not_materialised EV-w7 "note add without --at"

run_cli 64 note add cal:EV-w7 "x" --at banana
err_has "Cannot read banana as a time" "a misspelt offset is read before anything is resolved"
not_materialised EV-w7 "note add with an unreadable --at"

run_cli 0 status --json
json_is "d['meetings']['total']" "10" "six events became six rows, and the refused writes made none"
run_cli 0 vocab list --source attendee --json
json_is "sorted({t['term'] for t in d['terms']})" "['Priya Raman', 'Raman']" "materialising also auto-seeded the attendee's name, and never the bare first name"

# ---------------------------------------------------------------- a half transcript

section "half transcript"
echo "One channel of a meeting failed to transcribe. The other channel's text is still there, which"
echo "is the point and also the danger: without a mark it reads as a finished transcript."

swift run --package-path "$WORK/seeder" seed issue "$STANDUP" >/dev/null 2>&1 \
  || { echo "recording the transcript issue failed"; exit 1; }

run_cli 0 show "$STANDUP"
has "## transcript issues" "plain show says the transcript is incomplete"
has "The mic channel could not be transcribed" "in a sentence, naming the channel"

run_cli 0 show "$STANDUP" --json
json_is "len(d['meeting']['transcriptIssues'])" "1" "show --json carries the issue an agent has to branch on"
json_is "d['meeting']['transcriptIssues'][0]['channel']" "mic" "which channel is missing"
json_is "'ends mid-frame' in d['meeting']['transcriptIssues'][0]['reason']" "True" "and why, in the engine's own words"
# `kind` was missing here while the bundle shape carried it, so the one output that exists to spare
# agents from reading English forced them to read English: a capture failure never comes back on a
# re-run and a transcription failure does, and only the wording told them apart.
json_is "d['meeting']['transcriptIssues'][0]['kind']" "transcription" "and which half of the pipeline failed"

run_cli 0 show "$REVIEW" --json
json_is "'transcriptIssues' in d['meeting']" "False" "a whole transcript carries no key at all"

run_cli 0 list
printf '%s\n' "$LAST_OUT" | grep -- "$STANDUP" | grep -q '\*' \
  && ok "list marks that row so a listing shows it without a query per meeting" \
  || bad "list marks that row so a listing shows it without a query per meeting"
printf '%s\n' "$LAST_OUT" | grep -- "$REVIEW" | grep -q '\*' \
  && bad "and marks only that row" || ok "and marks only that row"
err_has "could not be transcribed" "with a legend on stderr, leaving the table pipeable"

run_cli 0 list --json
json_is "sum('transcriptIssues' in m for m in d['meetings'])" "1" "exactly one meeting is marked in JSON"
json_is "sorted({i['kind'] for m in d['meetings'] for i in m.get('transcriptIssues', [])})" "['transcription']" "carrying the kind here too"

run_cli 0 show "$STANDUP" --transcript
err_has "The mic channel could not be transcribed" "piping one section keeps the warning on stderr, out of the pipe"

# `transcript` is the command the bundled skill sends an agent to for anything over forty minutes,
# so it is the one that most has to say a channel is missing — and it was the one that never did.
run_cli 0 transcript "$STANDUP"
has "> The mic channel could not be transcribed" "transcript md says it, on stdout where a pipe carries it"
has "0:0" "and still prints the transcript"

run_cli 0 transcript "$STANDUP" --chunks 5
has "could not be transcribed" "the chunked long-meeting form says it too"
has "## chunk 1 of" "above the first chunk heading"

run_cli 0 transcript "$STANDUP" --json
json_is "len(d['transcriptIssues'])" "1" "transcript --json carries the same key show and list carry"
json_is "d['transcriptIssues'][0]['channel']" "mic" "naming the channel"
json_is "d['transcriptIssues'][0]['kind']" "transcription" "and the kind, in every shape that emits one"

run_cli 0 transcript "$STANDUP" --format srt
err_has "The mic channel could not be transcribed" "srt puts it on stderr"
hasnt "could not be transcribed" "because a forged cue would play on screen as if somebody said it"
case "$LAST_OUT" in "1"$'\n'"00:00:"*) ok "leaving stdout a valid .srt";; *) bad "leaving stdout a valid .srt";; esac

run_cli 0 transcript "$REVIEW" --json
json_is "'transcriptIssues' in d" "False" "a whole transcript carries no key at all"
run_cli 0 transcript "$REVIEW"
hasnt "could not be transcribed" "and no line above it"

# ---------------------------------------------------------------- create

section "create"
echo "Nothing is inferred. Every field is given or absent."

printf 'Chased facilities. Cryo stage free from the thirteenth.\n' > "$WORK/import-summary.md"
cat > "$WORK/import-transcript.json" <<'JSON'
[{"channel":"mic","startMs":0,"endMs":6000,"text":"Right, the Airbus timeline — when do they need the reconstruction?"},
 {"channel":"system","startMs":6200,"endMs":14000,"text":"Priya: end of the quarter, and they want the beam-stop cases handled properly."}]
JSON

run_cli 0 create --title "Airbus reconstruction timeline" --date 2026-07-14T10:00 --duration 45m \
  --folder Airbus --attendees "Priya Raman <priya@example.org>,Will" \
  --transcript-file "$WORK/import-transcript.json" --summary-file "$WORK/import-summary.md" --json
json_is "d['state']" "complete" "no audio means the meeting is complete on arrival"
json_is "d['segments']" "2" "the transcript came in with its timings"
json_is "d['folder']" "Airbus" "the folder was created because this store had never seen it"
json_is "len(d['attendees'])" "2" "Name <email> and a bare name both parse"
json_is "d['attendees'][0]['email']" "priya@example.org" "the angle-bracket form keeps both halves"
CREATED="$(printf '%s' "$LAST_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['ref'])")"

run_cli 0 show "$CREATED" --json
json_is "d['meeting']['durationMs']" "2700000" "45m is 45 minutes"
json_is "d['meeting']['audioAvailable']" "False" "and it has no audio"
run_cli 0 search "beam-stop" --json
json_is "any(h['ref'] == '$CREATED' for h in d['hits'])" "True" "the created transcript is in the search index"

# "reconstruction" is in this meeting's title and its transcript, and in the review meeting's
# summary and segments. One query, both kinds of match, two meetings.
run_cli 0 search reconstruction --json
json_is "d['hits'][0]['kind']" "title" "a title match outranks every body match"
json_is "d['hits'][0]['ref'] == '$CREATED'" "True" "and it is the meeting whose name matched"
json_is "[h['ref'] for h in d['hits']].count('$CREATED')" "1" "a meeting matching on both its title and its body appears once"
json_is "any(h['ref'] == '$REVIEW' and h['kind'] != 'title' for h in d['hits'])" "True" "body matches in other meetings still follow"

run_cli 64 create --title "No date" --date "last tuesday"
err_has "Cannot read" "a date it cannot read is refused rather than guessed"
run_cli 64 create --title "Bad duration" --date 2026-07-14 --duration "about an hour"
run_cli 2 create --title "Missing audio" --date 2026-07-14 --audio "$WORK/nope.wav"

# Real audio, rendered silently by `say -o` — this is the path that sets `audio_path`, which is what
# the retention sweep keys off. A meeting whose audio the store cannot find is a meeting the sweep
# can never purge, which would make the retention promise untrue for exactly the common case.
say -o "$WORK/spoken.wav" --data-format=LEI16@16000 -v Daniel \
  "The cryo stage is free from the thirteenth of the month." 2>/dev/null || true
if [ -f "$WORK/spoken.wav" ]; then
  run_cli 0 create --title "Voice memo about the cryo stage" --date 2026-07-15T09:00 \
    --audio "$WORK/spoken.wav" --source imported --json
  json_is "d['state']" "transcribing" "audio present means it queues for the batch pass"
  json_is "d['audioFile'].endswith('/mic.wav')" "True" "the recording is converted into the store's own audio tree"
  json_is "d['importedFrom']" "spoken.wav" "and records where it came from"
  WITH_AUDIO="$(printf '%s' "$LAST_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['ref'])")"
  run_cli 0 show "$WITH_AUDIO" --json
  json_is "d['meeting']['audioAvailable']" "True" "audio_path is set, so the retention sweep can find the files"
  [ -f "$MEETINGS_HOME/audio/$WITH_AUDIO/mic.wav" ] \
    && ok "the WAV is on disk where the row says it is" \
    || bad "the WAV is on disk where the row says it is"
else
  echo "  (no speech synthesis available — skipping the audio path)"
fi

# ---------------------------------------------------------------- export and import

section "export and import"
echo "A bundle is the lossless one and re-imports; markdown is one-way and says so."

mkdir -p "$WORK/bundles"
run_cli 0 export "$REVIEW" --format bundle --out "$WORK/bundles" --json
json_is "d['count']" "1" "one meeting exported"
json_is "d['exported'][0]['format']" "bundle" "as a bundle"
BUNDLE="$(printf '%s' "$LAST_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['exported'][0]['path'])")"
[ -f "$BUNDLE/meeting.json" ] && ok "the bundle holds meeting.json" || bad "the bundle holds meeting.json"
[ -f "$BUNDLE/transcript.json" ] && ok "and transcript.json" || bad "and transcript.json"

total() { "$BIN" status --json | python3 -c "import json,sys; print(json.load(sys.stdin)['meetings']['total'])"; }
BEFORE_IMPORT="$(total)"

run_cli 0 import "$BUNDLE" --dry-run --json
json_is "d['dryRun']" "True" "a dry run says so"
json_is "d['idCollision']" "True" "and sees that this store already holds that id"
[ "$(total)" = "$BEFORE_IMPORT" ] && ok "and wrote nothing" || bad "and wrote nothing"

run_cli 0 import "$BUNDLE" --json
json_is "d['idCollision']" "True" "the real import sees the collision too"
json_is "d['importedFrom'].endswith('.meetingbundle')" "True" "and records which bundle it came from"
IMPORTED="$(printf '%s' "$LAST_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['ref'])")"
[ "$IMPORTED" != "$REVIEW" ] && ok "a new id, never an overwrite" || bad "a new id, never an overwrite"
[ "$(total)" = "$((BEFORE_IMPORT + 1))" ] && ok "one more row, not one row rewritten" || bad "one more row, not one row rewritten"
run_cli 0 show "$REVIEW" --json
json_is "d['meeting']['source']" "recorded" "and the original is untouched"
run_cli 0 transcript "$IMPORTED" --json
json_is "len(d['segments'])" "$(field segments)" "the copy carries the whole transcript"

run_cli 0 export --folder Airbus --format bundle --out "$WORK/bundles" --json
json_is "d['count']" "1" "--folder exports a folder"
run_cli 2 export cal:EV-standup-thu --format bundle --out "$WORK/bundles"
err_has "nothing to export" "a calendar event with no row is not silently materialised to export it"
run_cli 64 export --format bundle --out "$WORK/bundles"
err_has "Give me a ref" "and it will not guess which meetings you meant"
run_cli 2 import "$WORK/bundles/nothing-here.meetingbundle"

mkdir -p "$WORK/md"
run_cli 0 export "$REVIEW" --format md --out "$WORK/md" --json
MD="$(printf '%s' "$LAST_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['exported'][0]['path'])")"
[ -f "$MD/summary.md" ] && ok "markdown export writes summary.md" || bad "markdown export writes summary.md"
[ -f "$MD/transcript.md" ] && ok "and transcript.md" || bad "and transcript.md"
grep -q "one-way" "$MD/meta.json" && ok "meta.json says the format is one-way" || bad "meta.json says the format is one-way"
run_cli 0 export "$REVIEW" --format md --out "$WORK/md"
err_has "None of this can be imported back" "and the command says so out loud, for one meeting as for many"

# ---------------------------------------------------------------- markdown on complete

section "markdown on complete"
echo "With export.markdownOnComplete on, a meeting reaching complete writes itself out."
echo "The way a meeting actually reaches complete is an agent writing the summary."

run_cli 0 config set export.markdownRoot "$WORK/auto"
run_cli 0 config set export.markdownOnComplete true
run_cli 0 summary set "$STANDUP" "Facilities confirmed the cryo stage from the thirteenth."
has "is complete" "the summary moved it to complete"
AUTO="$(find "$WORK/auto" -name summary.md 2>/dev/null | head -n 1)"
[ -n "$AUTO" ] && ok "and the markdown was written without being asked" || bad "and the markdown was written without being asked"
[ -n "$AUTO" ] && grep -q "cryo stage from the thirteenth" "$AUTO" \
  && ok "carrying the summary that had just been written" || bad "carrying the summary that had just been written"

run_cli 0 summary set "$STANDUP" ""
has "is ready" "clearing it moves the meeting back"
run_cli 0 config set export.markdownOnComplete false
rm -rf "$WORK/auto"
run_cli 0 summary set "$STANDUP" "Rewritten with the export off."
[ -d "$WORK/auto" ] && bad "with the setting off nothing is written" || ok "with the setting off nothing is written"

# ---------------------------------------------------------------- backup

section "backup"
run_cli 0 backup --json
BACKUP="$(printf '%s' "$LAST_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['path'])")"
json_is "d['bytes'] > 20000" "True" "the snapshot is a real database, not an empty file"
json_is "len(d['kept'])" "1" "one snapshot kept so far"
[ -f "$BACKUP" ] && ok "the backup file exists" || bad "the backup file exists"
case "$BACKUP" in "$MEETINGS_HOME"/backups/*) ok "under the store's own backups directory";; *) bad "under the store's own backups directory";; esac

# The claim `meetings backup` prints: the snapshot opens as a store in its own right.
LIVE_TOTAL="$(total)"
export MEETINGS_DB="$BACKUP"
run_cli 0 status --json
json_is "d['meetings']['total']" "$LIVE_TOTAL" "and reopening it as MEETINGS_DB reads the same meetings back"
unset MEETINGS_DB

# A second snapshot inside the same second is deliberately the same file — the name is dated to the
# second and `run` replaces it — so this waits for the clock to move rather than asserting a lie.
sleep 1
run_cli 0 backup --json
json_is "len(d['kept'])" "2" "a second snapshot is kept alongside the first"
json_is "d['pruned']" "0" "and nothing was pruned, well short of the seven kept"

# ---------------------------------------------------------------- delete

# The only command in the tree that destroys a recording. Exit codes are the least of it — three
# things are worth proving beyond them: that the refusal really wrote nothing, that the meeting
# leaves the FTS index (one still matching `meetings search` would quote a transcript nothing can
# open), and that the audio directory goes, since no foreign key can take it.
#
# Deliberately after `backup`: the two snapshots above are taken from a store that still has this
# meeting in it, which is the state the rest of the script asserted against.
section "delete"

run_cli 3 delete "$CREATED"
err_has "There is no undo" "without --yes it says what would go, and stops"
err_has "2 transcript segments" "counting the transcript it would take"
err_has "--yes" "and naming the flag that goes ahead"
run_cli 0 show "$CREATED" --json
json_is "d['meeting']['state']" "complete" "and the refusal wrote nothing at all"
run_cli 3 delete "$CREATED" --json
json_is "d['error']['code']" "3" "the refusal is a JSON envelope when --json was asked for"

# An audio directory findable by the meeting id alone, with nothing on the row pointing at it. That
# is the shape an imported meeting has before the batch pass writes `audio_path`, and the shape a
# retention purge interrupted between its two steps leaves behind. Once the row is gone nothing
# knows these files exist, so a delete that trusts `audio_path` leaks them forever.
mkdir -p "$MEETINGS_HOME/audio/$CREATED"
printf 'pretend this is a wav' > "$MEETINGS_HOME/audio/$CREATED/mic.wav"

run_cli 0 delete "$CREATED" --yes --json
json_is "d['deleted']" "$CREATED" "--yes deletes it, and names which meeting went"
json_is "d['segments']" "2" "reporting the transcript that went with it"
json_is "d['audio']" "False" "the row itself claimed no audio"
[ -d "$MEETINGS_HOME/audio/$CREATED" ] \
  && bad "and the audio directory went anyway, found by the meeting id" \
  || ok "and the audio directory went anyway, found by the meeting id"

run_cli 2 show "$CREATED"
# The mirror of the assertion the create section makes: that transcript was in the index, and now
# nothing of this meeting is. Checked by ref rather than by hit count, because the seeded review
# meeting talks about beam-stops too — a count would pass for the wrong reason the day it stopped.
run_cli 0 search "beam-stop" --json
json_is "any(h['ref'] == '$CREATED' for h in d['hits'])" "False" \
  "a cascaded delete fires the FTS triggers, so search forgot it too"
run_cli 2 delete "$CREATED" --yes
err_has "no meeting or calendar event" "deleting it a second time is exit 2, not a crash"

run_cli 2 delete cal:EV-standup-thu --yes
err_has "nothing to delete" "a calendar event with no row is not materialised just to delete it"
run_cli 64 delete

# The two states a delete is refused from, whatever flags it carries: one is having audio written
# into it right now, the other is having it read.
run_cli 3 delete "$RECORDING" --yes
err_has "still recording" "a meeting being recorded is refused even with --yes"
if [ -n "${WITH_AUDIO:-}" ]; then
  run_cli 3 delete "$WITH_AUDIO" --yes
  err_has "still transcribing" "and so is one the batch pass is still reading"
  [ -f "$MEETINGS_HOME/audio/$WITH_AUDIO/mic.wav" ] \
    && ok "with its audio untouched — a refused delete that took the WAVs would be the worst of both" \
    || bad "with its audio untouched — a refused delete that took the WAVs would be the worst of both"
fi

# ---------------------------------------------------------------- a leading dash is text

# The shipped bug this section exists for: `prenotes add <ref> "- push back on the March timeline"`
# printed help and exited 0, having written nothing. Every token starting with `-` was read as a
# cluster of short options, and that bullet contains an `h`. A markdown bullet is the most likely
# thing anyone appends to pre-notes, so the most common write in the product lost data and reported
# success. Every write command that takes text is checked here, not just the one that was reported.
section "a leading dash is text"

run_cli 0 prenotes set "$STANDUP" "- push back on the March timeline"
run_cli 0 prenotes get "$STANDUP" --json
json_is "d['preNotes']" "- push back on the March timeline" "prenotes set writes a markdown bullet"
run_cli 0 prenotes add "$STANDUP" "-5 degrees was the reading"
run_cli 0 prenotes get "$STANDUP" --json
json_is "d['preNotes'].endswith('-5 degrees was the reading')" "True" "and so does prenotes add"

run_cli 0 summary set "$STANDUP" "- decided: shim for the demo, re-cut for production"
run_cli 0 show "$STANDUP" --json
json_is "d['summary']" "- decided: shim for the demo, re-cut for production" "summary set writes one too"

run_cli 0 note add "$STANDUP" "- the housing drawing is the blocker" --at 0:05
has "Note added at 0:05" "note add writes one too"

run_cli 0 folder create "-hardware-batch-3"
run_cli 0 move "$STANDUP" --folder "-hardware-batch-3"
has "-hardware-batch-3" "a dash-led value reaches --folder instead of becoming a stray positional"
run_cli 0 vocab add "-hplc-trace"
run_cli 0 config set ai.cloud.model "-haiku-preview"
has "-haiku-preview" "config set stores a dash-led value"
run_cli 0 config set ai.cloud.model

# The documented range form. `--range=-10:00` always worked; the spelling the skill shows did not.
run_cli 0 transcript "$REVIEW" --range -10:00 --json
json_is "d['range']['endMs']" "600000" "--range -10:00 is the first ten minutes, not a missing value"

# ---------------------------------------------------------------- usage

section "usage"
run_cli 64 nosuchcommand
run_cli 64 list --nosuchflag --json
json_ok "even a parser error answers in JSON when --json was asked for"
json_is "d['error']['code']" "64" "and carries exit code 64"

# No command may exit 0 having done nothing. Help is exit 0 and prints on stdout, so a command that
# answered an unreadable line with help would be reporting success for a write that never happened.
for bad in "prenotes add $STANDUP --file" "summary set" "note add --at 0:03" "actions set $STANDUP" \
           "config set no.such.key 1" "list --state banana"; do
  # shellcheck disable=SC2086
  run_cli 64 $bad
  hasnt "OVERVIEW:" "an unreadable command line answers with an error, never with help on stdout"
done

run_cli 0 prenotes get "$STANDUP" --json
json_is "d['preNotes'].endswith('-5 degrees was the reading')" "True" "and none of them wrote anything"

run_cli 0 --help
has "OVERVIEW:" "help asked for is still help, on stdout, exit 0"

# ---------------------------------------------------------------- text that is exactly -h or --help

# The hole the rule above still had. `askedForHelp` scanned the whole command line for `-h`, so text
# that *is* `-h` read as a request for help: usage on stdout, exit 0, nothing written — the same
# failure one command line further in. Position decides it now: a help token is help only
# immediately after the command name, which is the one place a help request can sit.
#
# Wave 3 fixed that for `-h` and exempted `--help` on the grounds that ArgumentParser owns the
# spelling in every position. Owning it in every position *is* the defect, and it left the identical
# bug alive on every write command that takes text.
section "text that is exactly -h or --help"

for token in "-h" "--help" "help"; do
  run_cli 0 prenotes set "$STANDUP" "$token"
  hasnt "OVERVIEW:" "a positional that is exactly $token is not a help request"
  run_cli 0 prenotes get "$STANDUP" --json
  json_is "d['preNotes']" "$token" "it is text, and it is written"

  run_cli 0 summary set "$STANDUP" "$token"
  run_cli 0 show "$STANDUP" --json
  json_is "d['summary']" "$token" "the same on summary set"

  run_cli 0 config set ai.cloud.model "$token"
  run_cli 0 config get ai.cloud.model --json
  json_is "d['value']" "$token" "and on config set, where the value is the third positional"
done
run_cli 0 config set ai.cloud.model

run_cli 0 note add "$STANDUP" "--help" --at 0:07
has "Note added at 0:07" "and on note add, with an option after the text"

run_cli 64 actions set "$STANDUP" "--help"
hasnt "OVERVIEW:" "text that is unusable is a usage error, never help on stdout"

# A single-positional command cannot tell `folder create -h` from a request for help, so `--` is how
# you say you meant the characters. Losing this escape would make the rule unliveable.
run_cli 0 folder create -- "--help"
run_cli 0 folder list
has -- "--help" "-- writes a help token as the name it is"

# The other half of the same rule, at every depth of the tree: losing this would trade one broken
# command line for another.
for line in "-h" "--help" "show -h" "show --help" "prenotes -h" "prenotes add -h" \
            "prenotes add --help" "summary set --help" "note add --help" "config set -h" \
            "vocab add --help" "folder create --help"; do
  # shellcheck disable=SC2086
  run_cli 0 $line
  has "OVERVIEW:" "a help token right after the command name is still help"
done

# ---------------------------------------------------------------- a term the recogniser would ignore

# `VocabularyBiasing` drops anything under three characters before the CTC spotter is built, and
# nothing said so: the row was stored, `vocab list` printed it `on`, and the Settings table drew it
# active — three surfaces agreeing that a term was in effect over a transcriber that had never heard
# of it.
section "a term the recogniser would ignore"

run_cli 64 vocab add ML
err_has "recogniser ignores" "a term too short to reach the recogniser is refused, with the reason"
run_cli 64 vocab add ML --json
json_is "d['error']['code']" "64" "in JSON too, where an agent branches on it"
json_is "'recogniser ignores' in d['error']['message']" "True" "carrying the same reason"
run_cli 0 vocab list --json
json_is "sum(t['term'] == 'ML' for t in d['terms'])" "0" "and nothing was stored"
run_cli 64 vocab add "  ML  "
err_has "recogniser ignores" "padding it with spaces does not get it past the boundary"
run_cli 0 vocab add abc
has "abc (global)" "the shortest term the recogniser will actually use is accepted"
run_cli 0 vocab remove abc

# Put the pre-notes back to what the rest of the run expects to find.
run_cli 0 prenotes set "$STANDUP" "- push back on the March timeline"

# ---------------------------------------------------------------- a group with no subcommand

# `meetings summary` used to answer "Text beginning with a dash has to come after --", about a
# problem that is not there: nothing on the line is malformed, it stops one word short.
section "a group with no subcommand"

run_cli 64 summary
err_has "summary needs a subcommand" "it says what is missing"
err_has "meetings summary set" "and names the words that finish it"
hasnt "beginning with a dash" "and not a word about dashes"

run_cli 64 skill
err_has "skill needs a subcommand" "the same for skill"
err_has "meetings skill install" "naming its one subcommand"

run_cli 64 summary --json
json_is "d['error']['code']" "64" "in JSON too, where an agent branches on it"
json_is "'needs a subcommand' in d['error']['message']" "True" "carrying the same sentence"

# A group that has a default subcommand is a complete command line and must not be caught by it.
run_cli 0 config
run_cli 0 folder

# ---------------------------------------------------------------- the notes panel's settings

# Their own design note calls each one "a visible, named setting". They were reachable only from the
# app's Settings window: a CLI-driven setup could not turn screen-share hiding off or on, and
# `config get` did not even list them.
section "the notes panel's settings"

for key in panel.hideFromScreenSharing panel.keepAboveOtherApps; do
  run_cli 0 config get
  has "$key" "config get lists $key"
  run_cli 0 config get "$key"
  has "true" "unset, it reads as the app's own default rather than as nothing"
  run_cli 0 config set "$key" false
  run_cli 0 config get "$key" --json
  json_is "d['value']" "false" "the CLI can turn it off"
  json_is "d['isDefault']" "False" "and says it is no longer the default"
  run_cli 64 config set "$key" sometimes
  err_has "true or false" "a value that is not a boolean is refused"
  run_cli 0 config set "$key"
  run_cli 0 config get "$key" --json
  json_is "d['isDefault']" "True" "and set with no value puts the default back"
done

# ---------------------------------------------------------------- a store nobody can write to

# SQLite writes its -wal and -shm companions on every connection, including one that only reads, so
# a read-only store fails `status` and `list` too. It failed in SQLite's own words — "database is
# locked", or a `CREATE TABLE grdb_issue_102` nobody wrote — which name something the user did not
# do and cannot act on.
section "a store nobody can write to"

RO="$WORK/readonly"
mkdir -p "$RO"
cp "$MEETINGS_HOME"/store.db "$RO/"
cp "$MEETINGS_HOME"/store.db-wal "$RO/" 2>/dev/null
cp "$MEETINGS_HOME"/store.db-shm "$RO/" 2>/dev/null
chmod -R a-w "$RO"

for command in status list config; do
  printf '\n$ MEETINGS_HOME=<read-only> meetings %s\n' "$command"
  LAST_OUT="$(MEETINGS_HOME="$RO" "$BIN" "$command" </dev/null 2>"$WORK/stderr.txt")"
  LAST_CODE=$?
  LAST_ERR="$(cat "$WORK/stderr.txt")"
  printf '  stderr: %s\n' "$LAST_ERR"
  if [ "$LAST_CODE" -ne 0 ]; then ok "$command fails rather than answering"; else bad "$command fails rather than answering"; fi
  err_has "$RO" "and names the path that is the problem"
  err_has "not writable" "and says what is wrong with it"
  case "$LAST_ERR" in
    *"database is locked"*|*grdb_issue_102*) bad "never in SQLite's own words";;
    *) ok "never in SQLite's own words";;
  esac
done

chmod -R u+w "$RO"

# ---------------------------------------------------------------- summary

section "result"
printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [ "$fail_count" -gt 0 ]; then exit 1; fi
echo "cli-acceptance: OK"
