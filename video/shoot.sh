#!/usr/bin/env bash
#
# Shoots every frame of footage the launch film is cut from.
#
#   video/shoot.sh              # seed, pose, capture everything
#   video/shoot.sh --no-build   # reuse the bundle and seeder already built
#
# Nothing here touches your meetings, your calendar or the app you use. It seeds a throwaway store
# under $WORK, points a *separate* app bundle at it, and photographs that. It never activates,
# raises, focuses, moves or resizes a window, and it never types: every frame is posed with the
# launch-time environment overrides `Appearance` exists for, so the operator can keep using the Mac
# while it runs.
#
# What comes out:
#
#   video/film/public/shots/*.png   posed stills at 2x, one per app state the film cuts to
#   video/film/public/clips/*.mov   ProRes 4444 with alpha, for the two beats where the app moves
#   video/film/src/cli/session.json real `meetings` output, for the terminal beat
#
# The two clips are the interesting part. The app redraws itself whenever the store changes, from
# whichever process changed it — that is what makes "your agent writes it up" demonstrable rather
# than a claim. So the clips are recorded while this script drives the CLI against the same store,
# and what the camera sees is the real app reacting to a real write.
#
# One side effect worth knowing about: `scripts/build-app.sh` always assembles into `dist/Meetings.app`
# and has no output override, so a run leaves `dist/` holding the *film* bundle — same code, bundle id
# `com.yoelgal.meetings-film`. `scripts/dev.sh` does the same thing with its own identifier, and `dist/`
# is a build output rather than an artefact anybody keeps, so this follows that rather than fighting it.
# Run `scripts/build-app.sh` with no environment to put the ordinary bundle back.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="${MEETINGS_FILM_WORK:-/tmp/meetings-film}"
APP="$WORK/Meetings.app"
STORE="$WORK/store"
CALENDAR="$WORK/calendar.json"
PUBLIC="$ROOT/video/film/public"
SHOTS="$PUBLIC/shots"
CLIPS="$PUBLIC/clips"
# Bundled rather than served: the demo *imports* this, so it belongs beside the code that reads it and
# not in public/, which is for files fetched at runtime.
CLI_SESSION="$ROOT/video/film/src/cli/session.json"
SEED="$ROOT/video/seed/.build/debug/seed"
WINCAP="$WORK/wincap"
WINLIST="$WORK/winlist"
mkdir -p "$WORK"
# The path the process table will show, which is not $APP: /tmp is a symlink to /private/tmp, so a
# pkill pattern built from $APP matches nothing at all and every take is photographed against the
# leftovers of the last one.
APP_EXEC="$(cd "$WORK" && pwd -P)/Meetings.app/Contents/MacOS/Meetings"

# A distinct identifier, for the same reason scripts/dev.sh uses one: two running apps may not share
# a bundle id — the second gets no window at all — and the operator's own Meetings is running.
FILM_BUNDLE_ID="com.yoelgal.meetings-film"

BUILD=1
[ "${1:-}" = "--no-build" ] && BUILD=0

say() { printf '\n==> %s\n' "$1"; }

command -v ffmpeg >/dev/null || { echo "shoot: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

mkdir -p "$WORK" "$SHOTS" "$CLIPS" "$(dirname "$CLI_SESSION")"

# ---------------------------------------------------------------- tools

if [ "$BUILD" = 1 ]; then
    say "building the film bundle"
    # Same source as the shipping app, its own identifier, and the app name it ships under — the film
    # must not photograph a window whose menu bar says "meetings-dev".
    MEETINGS_BUNDLE_ID="$FILM_BUNDLE_ID" MEETINGS_APP_NAME="Meetings" \
        "$ROOT/scripts/build-app.sh" release >"$WORK/build.log" 2>&1 \
        || { echo "shoot: build failed, see $WORK/build.log" >&2; exit 1; }

    say "building the seeder"
    # Its own cache path: the shared SwiftPM repository cache races against the main checkout's own
    # resolve and fails with "already exists in file system".
    swift build --package-path "$ROOT/video/seed" --cache-path "$WORK/spm-cache" \
        >"$WORK/seed-build.log" 2>&1 \
        || { echo "shoot: seeder build failed, see $WORK/seed-build.log" >&2; exit 1; }

    say "building the capture tools"
    swiftc -O -parse-as-library "$ROOT/video/capture/wincap.swift" -o "$WINCAP"
    swiftc -O "$ROOT/video/capture/winlist.swift" -o "$WINLIST"
fi

for tool in "$SEED" "$WINCAP" "$WINLIST"; do
    [ -x "$tool" ] || { echo "shoot: $tool is missing — run without --no-build" >&2; exit 1; }
done

# The film bundle offers no CLI of its own. `CLIInstall.status()` compares /usr/local/bin/meetings
# against *this* bundle's copy, so a second bundle always reads as "points somewhere else" and the
# write-up card grows a "the meetings command is not installed" warning — which is false on a machine
# that has it on PATH, and this machine does. With no bundled copy the status is `unavailable`, the
# warning is not drawn, and the card renders exactly as it does for an installed user. It is removed
# after signing would otherwise seal it, so the bundle is re-signed here.
say "staging $APP"
rm -rf "$APP"
ditto "$ROOT/dist/Meetings.app" "$APP"
# The identity build-app.sh signed with, chosen the same way: the local certificate if this Mac
# has one, ad hoc otherwise. Hard-coding the certificate made a Mac without it exit here silently.
SIGN_IDENTITY="${MEETINGS_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "Meetings Local Signing"; then
        SIGN_IDENTITY="Meetings Local Signing"
    else
        SIGN_IDENTITY="-"
    fi
fi
# The bundle's own CLI drives the store from outside it — the same build as the app on screen, not
# whatever `meetings` happens to be on PATH (or none, which killed the shoot under set -e).
cp "$APP/Contents/Helpers/meetings" "$WORK/meetings"
meetings() { "$WORK/meetings" "$@"; }
rm -f "$APP/Contents/Helpers/meetings"
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ROOT/Packaging/Meetings.entitlements" --options runtime "$APP"
codesign --verify --deep --strict "$APP"

# A slept display has no window backing stores, and both screencapture and ScreenCaptureKit fail on
# one. `-u` wakes the display only: it takes no focus and makes no sound.
caffeinate -u -t 900 &
CAFFEINATE=$!
trap 'kill "$CAFFEINATE" 2>/dev/null; keepalive_stop 2>/dev/null; stop_app; true' EXIT

# ---------------------------------------------------------------- the store

say "seeding $STORE"
rm -rf "$STORE" "$CALENDAR"
mkdir -p "$STORE"
export MEETINGS_HOME="$STORE"
export MEETINGS_CALENDAR_FIXTURE="$CALENDAR"
"$SEED" >"$WORK/refs.json"
python3 -m json.tool "$WORK/refs.json"

ref() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$WORK/refs.json" "$1"; }
# Only the one the write-up clip drives. The rest of the store is selected by scope and state rather
# than by id, so nothing else here needs a ref.
STANDUP="$(ref standup)"

# ---------------------------------------------------------------- posing the window

APP_PID=""

# Every instance of the film bundle, not just the one this run started: an aborted take leaves one
# behind, and its window is in the diff of the next `pose` and gets photographed instead. Matched on
# the full executable path, so the operator's own Meetings — a different bundle, same executable
# name — is never signalled.
stop_app() {
    pkill -f "^$APP_EXEC$" 2>/dev/null || true
    APP_PID=""
    for _ in $(seq 20); do
        pgrep -f "^$APP_EXEC$" >/dev/null || break
        sleep 0.25
    done
}

# Launches a fresh instance against the demo store with the given overrides, and leaves its pid in
# $APP_PID and its window id in $APP_WINDOW.
#
# The window is found by *diffing* the window list across the launch. Taking the process's largest
# window is not enough: a launch that has not finished drawing has no window yet, and the previous
# take's window may still be closing, so both "no window" and "the wrong window" are reachable.
#
# Of the new windows, the largest is the main one. The app also owns the floating notes panel, which
# exists at 500x500 whether or not it is on screen — filming that instead of the window is a take
# that comes back as a small grey rectangle, and ProRes refuses some of those sizes outright.
#
# `open -g` keeps whatever the operator is working in on top.
pose() {
    stop_app
    local before after biggest
    before="$("$WINLIST" "$FILM_BUNDLE_ID" | cut -f2 | sort)"
    open -n -g \
        --env "MEETINGS_HOME=$MEETINGS_HOME" \
        --env "MEETINGS_CALENDAR_FIXTURE=$MEETINGS_CALENDAR_FIXTURE" \
        --env "MEETINGS_WINDOW=${FILM_WINDOW:-1600x900}" \
        --env "MEETINGS_APPEARANCE=dark" \
        "$@" "$APP"
    for _ in $(seq 60); do
        sleep 0.5
        after="$("$WINLIST" "$FILM_BUNDLE_ID")"
        # pid, window id, area — restricted to windows this launch added, largest area first.
        biggest="$(
            comm -13 <(echo "$before") <(echo "$after" | cut -f2 | sort) \
            | while read -r id; do
                echo "$after" | awk -F'\t' -v w="$id" '$2 == w {
                    split($3, d, "x"); print $1, $2, d[1] * d[2]
                }'
            done | sort -k3,3nr | head -1
        )"
        if [ -n "$biggest" ]; then
            APP_PID="$(echo "$biggest" | cut -d' ' -f1)"
            APP_WINDOW="$(echo "$biggest" | cut -d' ' -f2)"
            # Let the window finish its first layout and its open animation. Photographing before
            # this is how a shot comes back with an empty list in it.
            sleep "${FILM_SETTLE:-5}"
            return 0
        fi
    done
    echo "shoot: the window never appeared" >&2
    exit 1
}

still() {
    local name="$1"; shift
    pose "$@"
    "$ROOT/scripts/shot.sh" "$APP_PID" "$SHOTS/$name.png" 25
}

# ---------------------------------------------------------------- brand

# The closing card is the README banner: the repo's own mark, with the name beside it. Copied in here
# rather than committed under `public/`, so there is exactly one `logo.png` in the project and the demo
# cannot end up showing an old one. It is opaque, with its bloom and a navy background baked in — the
# closing composites it with `screen` over a near-black card, which is why that works.
say "brand"
mkdir -p "$PUBLIC/brand"
cp "$ROOT/brand/logo.png" "$PUBLIC/brand/logo.png"

# ---------------------------------------------------------------- stills

# Exactly the states the film cuts to, and no others. Every extra capture is a file that goes stale
# the next time the app's layout moves and that nothing notices, because nothing reads it — the first
# cut of this shoot produced nine stills for the four states that used one.
say "stills"

# The app at rest: a written-up meeting, the queue holding two, folders with counts.
still library --env "MEETINGS_SCOPE=all" --env "MEETINGS_SELECT=complete"

# Tomorrow's meeting, with the notes already written against it — the one beat that happens *before* a
# call rather than after one, which is what stops the demo reading as six views of the same screen.
#
# Scoped to the folder rather than to `upcoming`, which was the first attempt: `MEETINGS_SELECT` matches
# on a meeting's state against the model's list, and in the Upcoming scope the rows are calendar events
# whose identifiers are `cal:` refs, so setting the selection to a store id selected nothing and the
# detail pane came back reading "No meeting selected". The folder scope holds the same meeting and
# selects it, and its detail pane is the better frame anyway: Start recording, the call link, the
# attendees and the pre-notes all at once.
still upcoming --env "MEETINGS_SCOPE=folder:Clients" --env "MEETINGS_SELECT=scheduled" \
    --env "MEETINGS_DETAIL_OPEN=prenotes"

# The notes beat is gone from the cut, and so is its still. The demo now runs as one continuous take of
# six window states, and "notes keep their place" was the weakest of the seven it used to have: it needed
# its own caption to mean anything, and the notes pane is on screen throughout the recording beat anyway,
# offsets and all. A capture nothing reads is a file that goes stale the next time the layout moves.

# Search across transcripts, notes, pre-notes and write-ups at once.
still search --env "MEETINGS_SCOPE=all" --env "MEETINGS_SELECT=complete" \
    --env "MEETINGS_SEARCH=pricing"

# A recording in progress.
#
# Two things have to be true at once. `MEETINGS_RECORDING_CHROME=1` moves one input — "a recording is
# in progress" — so the toolbar draws the transport without this process opening a microphone. And
# the row itself has to survive `RecordingRecovery`, which sweeps every `recording` meeting the
# running app does not own and moves it somewhere true; its liveness test is a `.wav` written inside
# the last fifteen seconds, so `seed keepalive` keeps appending to the two tracks for as long as any
# recording shot is up. Without it the sweep is right and the shot comes back reading "Needs
# write-up".
say "seeding the live meeting"
LIVE="$("$SEED" live)"
echo "    $LIVE"

keepalive_start() {
    ( while :; do "$SEED" keepalive "$LIVE" >/dev/null 2>&1 || true; sleep 4; done ) &
    KEEPALIVE=$!
}
keepalive_stop() {
    [ -n "${KEEPALIVE:-}" ] && kill "$KEEPALIVE" 2>/dev/null
    KEEPALIVE=""
}

keepalive_start

# ---------------------------------------------------------------- clips

# 1 — the live transcript arriving while the meeting is being recorded.
#
# The lines are inserted by the seeder's `say`, which is the only writer of live segments outside the
# transcriber. Each insert commits and posts a StoreChange, and the window redraws itself: what the
# camera records is the real app taking real text, at the pace a recogniser delivers it.
#
# Six lines at about 1.3s apart, over a twelve-second take, rather than the three at 2.2s this used to
# take. Two numbers drive that. The demo holds on this shot for 6.3 seconds — it is the only beat where
# something arrives on its own and the viewer is meant to watch it happen — and the camera does not reach
# the transcript until 2.6s into the hold, because the first thing worth seeing is the transport bar. So
# lines have to land roughly every 1.3s for three of them to arrive while the camera is actually looking
# at the pane, with three already there when it gets there. At the old pacing exactly one line arrived on
# screen, and a transcript that gains one line is indistinguishable from a screenshot.
say "clip: the live transcript"
pose --env "MEETINGS_RECORDING_CHROME=1" --env "MEETINGS_SELECT=recording"
(
    sleep 1.1
    "$SEED" say "$LIVE" 254000 system "Marcus: the migration note is drafted, I just need the pricing wording." >/dev/null
    sleep 1.3
    "$SEED" say "$LIVE" 259000 mic "You will have it today. Keep it to one page." >/dev/null
    sleep 1.3
    "$SEED" say "$LIVE" 264000 system "Marcus: and it goes out with the invite, not after it." >/dev/null
    sleep 1.3
    "$SEED" say "$LIVE" 271000 mic "Agreed. I will send the funnel numbers with it." >/dev/null
    sleep 1.3
    "$SEED" say "$LIVE" 277000 system "Marcus: Dana wants the seat count in the same note." >/dev/null
    sleep 1.3
    "$SEED" say "$LIVE" 283000 mic "Forty seats to start. I will put it under the pricing line." >/dev/null
    sleep 1.4
    meetings note add "$LIVE" "Migration note ships with the invite." --at 4:26 >/dev/null
) &
DRIVER=$!
"$WINCAP" --window-id "$APP_WINDOW" --out "$CLIPS/live.mov" --seconds 12 --fps 60
wait "$DRIVER"
keepalive_stop

# 2 — the write-up landing, written from outside the app.
#
# This is the whole thesis of the product in one shot: the queue is holding two, an agent writes one
# of them up at the command line, and the window it is sitting in changes by itself — the write-up
# appears, the actions become tickable checkboxes, and the queue drops to one.
say "clip: the write-up landing"
cat > "$WORK/standup-writeup.md" <<'MD'
## What we decided

- The migration note goes out with the Northwind invite rather than after it, and Marcus has the pricing wording today.

## Actions

- [x] Pull the funnel numbers for the invite step
- [ ] Send Marcus the pricing wording
- [ ] Ship the migration note with the invite

## Not covered

- Nothing else came up. It was an eleven-minute standup.
MD

# `all` rather than `needsWriteUp`: the demo no longer shows the write-up queue at all, and this scope
# puts a full, believable list beside the meeting instead of a two-row queue.
pose --env "MEETINGS_SCOPE=all" --env "MEETINGS_SELECT=ready"
(
    sleep 3
    meetings summary set "$STANDUP" --file "$WORK/standup-writeup.md" >/dev/null
) &
DRIVER=$!
"$WINCAP" --window-id "$APP_WINDOW" --out "$CLIPS/writeup.mov" --seconds 10 --fps 60
wait "$DRIVER"

stop_app

# ---------------------------------------------------------------- the terminal beat

# One real agent session, in order, captured rather than written by hand — so the terminal beat cannot
# drift away from what the CLI actually prints. The demo types these on screen itself rather than
# compositing a screen recording of a terminal, which keeps the beat in the demo's own typeface instead
# of importing whatever Terminal.app happens to be set to.
#
# It runs last, so `list --state ready` returns the one meeting the write-up clip left in the queue. One
# row reads better than two on screen, and it is the truth about the store at this moment either way.
say "cli session"
cat > "$WORK/review-writeup.md" <<'MD'
## What we decided

- The empty state says what to do next, not that the list is empty.

## Actions

- [ ] Apply the same pattern to search results
MD

SESSION="$WORK/session"
rm -rf "$SESSION"; mkdir -p "$SESSION"
STEP=0

# Command line and output go through files, never argv: a `meetings search` result carries « » and
# newlines, and would otherwise have to survive two levels of shell quoting to reach python.
step() {
    STEP=$((STEP + 1))
    local label="$1"; shift
    printf '%s\n' "$label" > "$SESSION/$STEP.cmd"
    "$@" > "$SESSION/$STEP.out" 2>&1 || true
    printf '    %s\n' "$label"
}

# The displayed command line is passed separately from the argv actually run, for one reason: the shown
# form is what a person would type, and `--file /tmp/meetings-film/review-writeup.md` is not.
REVIEW="$(ref review)"
step "meetings list --state ready" \
    meetings list --state ready
step "meetings summary set $REVIEW --file writeup.md" \
    meetings summary set "$REVIEW" --file "$WORK/review-writeup.md"
# Reading it back, rather than `actions list --open`: that one answers across every meeting and comes out
# as a wall of hex, which is the right answer to a different question. The write-up is the point here.
step "meetings show $REVIEW --summary" \
    meetings show "$REVIEW" --summary

python3 - "$CLI_SESSION" "$SESSION" "$STEP" <<'PY'
import json, sys
from pathlib import Path

out, folder, count = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
steps = [
    {
        "command": (folder / f"{n}.cmd").read_text().strip(),
        "output": (folder / f"{n}.out").read_text().rstrip("\n"),
    }
    for n in range(1, count + 1)
]
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(steps, indent=2) + "\n")
PY

say "done"
printf '    stills   %s\n' "$(find "$SHOTS" -name '*.png' | wc -l | tr -d ' ')"
printf '    clips    %s\n' "$(find "$CLIPS" -name '*.mov' | wc -l | tr -d ' ')"
printf '    session  %s steps\n' "$STEP"
printf '    into     %s\n' "$PUBLIC"
