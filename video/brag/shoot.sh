#!/usr/bin/env bash
#
# Shoots the footage the launch film (video/brag) is cut from.
#
#   video/brag/shoot.sh              # build, seed, pose, capture
#   video/brag/shoot.sh --no-build   # reuse the bundle and tools already built
#
# Same rules as video/shoot.sh, whose patterns this reuses: a throwaway store of invented data under
# $WORK, a *separate* app bundle pointed at it, every window state posed with the launch-time
# `Appearance` overrides, nothing activated, raised, focused, moved, resized or typed into, and no
# sound. The operator keeps using the Mac while it runs.
#
# Its own bundle identifier (com.yoelgal.meetings-launch), not the demo's: macOS keeps per-identifier
# window restoration, and an identifier whose last instance was killed with its main window ordered
# out relaunches with no window at all — which reads as "the window never appeared" mid-shoot.
#
# Out:
#   video/film/public/launch/*.png   posed stills at 2x
#   video/film/public/launch/*.mov   ProRes 4444 with alpha, for the beats where the app moves
#   video/film/src/launch/session.json   real `meetings` output for the terminal beat
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${MEETINGS_LAUNCH_WORK:-/tmp/meetings-launch}"
APP="$WORK/Meetings.app"
STORE="$WORK/store"
OUT="$ROOT/video/film/public/launch"
SESSION_JSON="$ROOT/video/film/src/launch/session.json"
BUNDLE_ID="com.yoelgal.meetings-launch"
SEED="$WORK/seed-pkg/.build/debug/seed"
WINCAP="$WORK/wincap"
WINLIST="$WORK/winlist"
CLI="$WORK/meetings"
mkdir -p "$WORK" "$OUT" "$(dirname "$SESSION_JSON")"
APP_EXEC="$(cd "$WORK" && pwd -P)/Meetings.app/Contents/MacOS/Meetings"

say() { printf '\n==> %s\n' "$1"; }

if [ "${1:-}" != "--no-build" ]; then
    say "building the launch bundle"
    MEETINGS_BUNDLE_ID="$BUNDLE_ID" MEETINGS_APP_NAME="Meetings" \
        "$ROOT/scripts/build-app.sh" release >"$WORK/build.log" 2>&1 \
        || { echo "shoot: build failed, see $WORK/build.log" >&2; exit 1; }
    rm -rf "$APP"
    ditto "$ROOT/dist/Meetings.app" "$APP"

    # The seeder depends on the checkout by path, and SwiftPM names a path dependency after its
    # directory — so video/seed/Package.swift only resolves in a checkout called `meetings-thing`.
    # A generated manifest beside a copy of the sources resolves in any worktree.
    say "building the seeder"
    rm -rf "$WORK/seed-pkg"; mkdir -p "$WORK/seed-pkg"
    cp -R "$ROOT/video/seed/Sources" "$WORK/seed-pkg/"
    cat > "$WORK/seed-pkg/Package.swift" <<SWIFT
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "seed",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "$ROOT")],
    targets: [.executableTarget(name: "seed", dependencies: [
        .product(name: "MeetingsCore", package: "$(basename "$ROOT")")])]
)
SWIFT
    swift build --package-path "$WORK/seed-pkg" --cache-path "$WORK/spm-cache" \
        >"$WORK/seed-build.log" 2>&1 \
        || { echo "shoot: seeder build failed, see $WORK/seed-build.log" >&2; exit 1; }

    say "building the capture tools"
    swiftc -O -parse-as-library "$ROOT/video/capture/wincap.swift" -o "$WINCAP"
    swiftc -O "$ROOT/video/capture/winlist.swift" -o "$WINLIST"
fi

# The CLI comes out of the bundle and drives the store from outside it. Left inside, the app compares
# its own copy against /usr/local/bin/meetings, finds a different file and puts a "the meetings
# command is not installed" card on the write-up — false on a Mac that has it, and on screen.
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
if [ -f "$APP/Contents/Helpers/meetings" ]; then
    cp "$APP/Contents/Helpers/meetings" "$CLI"
    rm -f "$APP/Contents/Helpers/meetings"
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$ROOT/Packaging/Meetings.entitlements" --options runtime "$APP"
fi
# Footage from an earlier shoot must never stand in for a capture that failed this time.
rm -f "$OUT"/*.png "$OUT"/*.mov

caffeinate -u -t 900 &
CAFFEINATE=$!

stop_app() {
    pkill -f "^$APP_EXEC$" 2>/dev/null || true
    for _ in $(seq 20); do pgrep -f "^$APP_EXEC$" >/dev/null || break; sleep 0.25; done
}
trap 'kill "$CAFFEINATE" 2>/dev/null; keepalive_stop 2>/dev/null; stop_app; true' EXIT

say "seeding $STORE"
rm -rf "$STORE" "$WORK/calendar.json"; mkdir -p "$STORE"
export MEETINGS_HOME="$STORE" MEETINGS_CALENDAR_FIXTURE="$WORK/calendar.json"
"$SEED" >"$WORK/refs.json"
ref() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$WORK/refs.json" "$1"; }

# Launch posed, find the window this launch added (largest new one), wait for it to settle.
pose() {
    stop_app
    local before after biggest
    before="$("$WINLIST" "$BUNDLE_ID" | cut -f2 | sort)"
    open -n -g --env "MEETINGS_HOME=$MEETINGS_HOME" \
        --env "MEETINGS_CALENDAR_FIXTURE=$MEETINGS_CALENDAR_FIXTURE" \
        --env "MEETINGS_WINDOW=1600x900" --env "MEETINGS_APPEARANCE=dark" "$@" "$APP"
    for _ in $(seq 60); do
        sleep 0.5
        after="$("$WINLIST" "$BUNDLE_ID")"
        biggest="$(comm -13 <(echo "$before") <(echo "$after" | cut -f2 | sort) | while read -r id; do
            echo "$after" | awk -F'\t' -v w="$id" '$2 == w { split($3, d, "x"); print $1, $2, d[1] * d[2] }'
        done | sort -k3,3nr | head -1)"
        if [ -n "$biggest" ]; then
            APP_PID="$(echo "$biggest" | cut -d' ' -f1)"
            APP_WINDOW="$(echo "$biggest" | cut -d' ' -f2)"
            sleep "${SETTLE:-5}"
            return 0
        fi
    done
    echo "shoot: the window never appeared" >&2; exit 1
}

# Every on-screen window the app owns that is not the main one — the floating panels.
panel_window() {
    swift -e 'import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int ?? 0) != 0 {
    print(w[kCGWindowNumber as String]!) }' "$APP_PID" 2>/dev/null | head -1
}

still() { screencapture -x -o -l "$1" "$OUT/$2.png"; echo "    $2.png"; }

LIVE="$("$SEED" live)"
keepalive_start() { ( while :; do "$SEED" keepalive "$LIVE" >/dev/null 2>&1 || true; sleep 4; done ) & KEEPALIVE=$!; }
keepalive_stop() { [ -n "${KEEPALIVE:-}" ] && kill "$KEEPALIVE" 2>/dev/null; KEEPALIVE=""; }
keepalive_start

# ---------------------------------------------------------------- 1. live transcript, two tracks

say "clip: live transcript"
pose --env "MEETINGS_RECORDING_CHROME=1" --env "MEETINGS_SELECT=recording" --env "MEETINGS_NOTES_PANEL=0"
(
    sleep 1.0
    for line in \
        "254000|system|Marcus: the migration note is drafted, I just need the pricing wording." \
        "259000|mic|You will have it today. Keep it to one page." \
        "264000|system|Marcus: and it goes out with the invite, not after it." \
        "271000|mic|Agreed. I will send the funnel numbers with it." \
        "277000|system|Marcus: Dana wants the seat count in the same note." \
        "283000|mic|Forty seats to start. I will put it under the pricing line."; do
        IFS='|' read -r at ch text <<<"$line"
        "$SEED" say "$LIVE" "$at" "$ch" "$text" >/dev/null
        sleep 1.25
    done
    "$CLI" note add "$LIVE" "Migration note ships with the invite." --at 4:26 >/dev/null
) &
DRIVER=$!
"$WINCAP" --window-id "$APP_WINDOW" --out "$OUT/live.mov" --seconds 11 --fps 60
wait "$DRIVER"

# ---------------------------------------------------------------- 2. the panel, and screen share

say "stills: the notes panel over a call"
pose --env "MEETINGS_RECORDING_CHROME=1" --env "MEETINGS_SELECT=recording" \
    --env "MEETINGS_NOTES_PANEL=live" --env "MEETINGS_PANEL_CAPTURABLE=1" \
    --env "MEETINGS_PANEL_NOTE=Ask about the seat count before pricing."
still "$APP_WINDOW" recording-window
PANEL="$(panel_window)"
[ -n "$PANEL" ] || { echo "shoot: the notes panel never came on screen" >&2; exit 1; }
still "$PANEL" panel-live
keepalive_stop
"$SEED" drop "$LIVE"

# ---------------------------------------------------------------- 3. notes anchored in the transcript

say "still: notes beside the transcript"
pose --env "MEETINGS_SCOPE=folder:Clients" --env "MEETINGS_SELECT=complete" \
    --env "MEETINGS_DETAIL_OPEN=notes,transcript"
still "$APP_WINDOW" anchored

# ---------------------------------------------------------------- 4. an agent writes it up

say "clip: the write-up landing, and the terminal that lands it"
# One action, seen from both sides: the terminal beat is the agent's session verbatim — what is
# waiting, the write-up going in, reading it back — and the app clip is recorded while that same
# `summary set` runs, so the window that changes on screen is the one the terminal just wrote to.
STANDUP="$(ref standup)"
cat > "$WORK/writeup.md" <<'MD'
## What we decided

- The migration note goes out with the Northwind invite rather than after it, and Marcus has the pricing wording today.

## Actions

- [x] Pull the funnel numbers for the invite step
- [ ] Send Marcus the pricing wording
- [ ] Ship the migration note with the invite
MD
"$CLI" list --state ready > "$WORK/step1.out" 2>&1 || true
pose --env "MEETINGS_SCOPE=all" --env "MEETINGS_SELECT=ready"
# The CLI's exit status is checked after the clip, never swallowed: a failing `summary set` would
# otherwise be filmed as an empty write-up and typed on screen as the agent's output.
( sleep 3; "$CLI" summary set "$STANDUP" --file "$WORK/writeup.md" > "$WORK/step2.out" 2>&1; echo $? > "$WORK/step2.status" ) &
DRIVER=$!
"$WINCAP" --window-id "$APP_WINDOW" --out "$OUT/writeup.mov" --seconds 8 --fps 60
wait "$DRIVER"
stop_app
[ "$(cat "$WORK/step2.status")" = 0 ] || { echo "shoot: summary set failed: $(cat "$WORK/step2.out")" >&2; exit 1; }
"$CLI" show "$STANDUP" --summary > "$WORK/step3.out" 2>&1

python3 - "$STANDUP" "$WORK" > "$SESSION_JSON" <<'PY'
import json, re, sys
from pathlib import Path
ref, work = sys.argv[1], Path(sys.argv[2])
short = ref[:8]
shown = ["meetings list --state ready",
         f"meetings summary set {short} --file writeup.md",
         f"meetings show {short} --summary"]
uuid = re.compile(r"\b([0-9A-F]{8})(-[0-9A-F]{4}){3}-[0-9A-F]{12}\b")
steps = [{"command": c, "output": uuid.sub(r"\1", (work / f"step{n}.out").read_text().rstrip("\n"))}
         for n, c in enumerate(shown, 1)]
print(json.dumps(steps, indent=2))
PY

cp "$ROOT/brand/logo.png" "$OUT/logo.png"
say "done"; ls -1 "$OUT"
