#!/usr/bin/env bash
#
# The edit → run loop in one command: debug build, install a *separate* dev copy, relaunch it.
#
#   scripts/dev.sh                    # rebuild and relaunch in the background
#   DEV_FOREGROUND=1 scripts/dev.sh   # ... and bring it to the front
#
# This does not touch the app you installed from install.sh. The dev copy is its own bundle in
# ~/Applications and its own store, so both can run at the same time and the real one is never the
# thing you just broke. Overrides, all optional:
#
#   MEETINGS_DEV_APP=/path/to.app    where the dev bundle goes  (default ~/Applications/meetings-dev.app)
#   MEETINGS_DEV_HOME=/path          the dev store tree         (default ~/Library/Application Support/meetings-dev)
#   MEETINGS_DEV_NAME=name           menu bar / Dock name       (default meetings-dev)
#
# The dev build calls itself `meetings-dev` in the menu bar, the Dock and the app switcher, so two
# identical "Meetings" are never sitting there daring you to guess which is which.
#
# The dev build is a separate app all the way down: its own CFBundleIdentifier, and therefore its
# own NSUserDefaults domain. That last part is not cosmetic. Sharing the installed app's identifier
# means sharing its window frame, split positions, panel state and settings, so a dev launch saves
# its own geometry over the app you actually use — including, once, a window taller than the screen
# with its resize edge off the bottom.
#
# The cost is one microphone and screen-recording prompt the first time the dev build records, since
# TCC keys on the identifier too. Grant it once per machine.
#
# The dev store starts empty, because pointing a debug build at your real meetings is how you lose
# them. To look at real data, either aim the dev build at the real tree:
#
#   MEETINGS_DEV_HOME="$HOME/Library/Application Support/Meetings" scripts/dev.sh
#
# ...or, safer, take a copy first: `meetings backup --out /tmp` writes one you can point at.
#
# The CLI is unaffected and still reads the real store. To drive the dev one:
#
#   MEETINGS_HOME="$HOME/Library/Application Support/meetings-dev" meetings list
#
# Not hot reload — the process restarts, so window state resets. The dev store outlives the bundle.
#
# Run scripts/make-signing-identity.sh once first, or macOS re-asks for the microphone and screen
# recording after every single rebuild — ad-hoc signatures are the binary's own hash, so each build
# is a stranger to the permission system.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${MEETINGS_DEV_APP:-$HOME/Applications/meetings-dev.app}"
DEV_HOME="${MEETINGS_DEV_HOME:-$HOME/Library/Application Support/meetings-dev}"
DEV_NAME="${MEETINGS_DEV_NAME:-meetings-dev}"
DEV_BUNDLE_ID="${MEETINGS_DEV_BUNDLE_ID:-com.yoelgal.meetings-dev}"
EXEC_PATH="$TARGET/Contents/MacOS/Meetings"

# A relative MEETINGS_HOME is a different store for every directory it is read from, and Paths
# rejects one — catch it here, where the error can name the variable the user actually set.
case "$DEV_HOME" in
    /*) ;;
    *) echo "dev: MEETINGS_DEV_HOME must be an absolute path, got '$DEV_HOME'" >&2; exit 1 ;;
esac

MEETINGS_APP_NAME="$DEV_NAME" MEETINGS_BUNDLE_ID="$DEV_BUNDLE_ID" "$ROOT/scripts/build-app.sh" debug

# Match on the full executable path, not the name: `pkill -x Meetings` would also take out the
# installed app, which is the one thing this script exists to leave alone.
if pkill -f "^$EXEC_PATH$" 2>/dev/null; then
    echo "==> stopped the running dev app"
    for _ in $(seq 20); do
        pgrep -f "^$EXEC_PATH$" >/dev/null || break
        sleep 0.25
    done
fi

echo "==> installing to $TARGET"
parent="$(dirname "$TARGET")"
mkdir -p "$parent"
[ -w "$parent" ] || { echo "dev: $parent is not writable — set MEETINGS_DEV_APP" >&2; exit 1; }
rm -rf "$TARGET"
ditto "$ROOT/dist/Meetings.app" "$TARGET"

mkdir -p "$DEV_HOME"

# -n because the installed app shares this bundle identifier and would otherwise just come to the
# front instead of a second instance starting. -g leaves whatever you are working in on top; the
# background-only default is deliberate, DEV_FOREGROUND=1 when you actually want to look at it.
args=(-n --env "MEETINGS_HOME=$DEV_HOME")
[ "${DEV_FOREGROUND:-0}" = "1" ] || args+=(-g)
open "${args[@]}" "$TARGET"

echo "OK: running $TARGET"
echo "    store: $DEV_HOME"
