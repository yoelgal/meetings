#!/usr/bin/env bash
#
# The edit → run loop in one command: debug build, swap the installed app, relaunch.
#
#   scripts/dev.sh                 # rebuild and relaunch in the background
#   DEV_FOREGROUND=1 scripts/dev.sh   # ... and bring it to the front
#   MEETINGS_DEV_APP=dist/Meetings.app scripts/dev.sh   # target a different copy
#
# Not hot reload — the process restarts, so window state resets. Your data does not: the store lives
# in ~/Library/Application Support/Meetings and outlives the bundle.
#
# Run scripts/make-signing-identity.sh once first, or macOS re-asks for the microphone and screen
# recording after every single rebuild — ad-hoc signatures are the binary's own hash, so each build
# is a stranger to the permission system.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${MEETINGS_DEV_APP:-/Applications/Meetings.app}"
EXEC_PATH="$TARGET/Contents/MacOS/Meetings"

"$ROOT/scripts/build-app.sh" debug

# Match on the full executable path, not the name: `pkill -x Meetings` would also take out anything
# else on this Mac that happens to be called that.
if pkill -f "^$EXEC_PATH$" 2>/dev/null; then
    echo "==> stopped the running app"
    for _ in $(seq 20); do
        pgrep -f "^$EXEC_PATH$" >/dev/null || break
        sleep 0.25
    done
fi

echo "==> installing to $TARGET"
parent="$(dirname "$TARGET")"
[ -w "$parent" ] || { echo "dev: $parent is not writable — set MEETINGS_DEV_APP" >&2; exit 1; }
rm -rf "$TARGET"
ditto "$ROOT/dist/Meetings.app" "$TARGET"

# -g leaves your current app in front. The background-only default is deliberate; DEV_FOREGROUND=1
# when you actually want to look at it.
if [ "${DEV_FOREGROUND:-0}" = "1" ]; then
    open "$TARGET"
else
    open -g "$TARGET"
fi
echo "OK: running $TARGET"
