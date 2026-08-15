#!/usr/bin/env bash
#
# The repo's one verify command. Build, test, assemble the app, smoke the shipped CLI.
#
#   scripts/verify.sh
#
# Non-zero exit on any failure. It never touches the real store: the smoke run points MEETINGS_HOME
# at a throwaway directory and checks that the CLI actually honoured it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STEP=0
step() { STEP=$((STEP + 1)); echo; echo "=== $STEP/5  $*"; }

step "swift build"
swift build

step "swift test"
swift test

# The editor suites — the probe walk, the bus round trip, the anchor, /todo and strikethrough — are
# gated behind MEETINGS_LIVE_EDITOR because they build a real AppKit view hierarchy, and an earlier
# harness that did that appeared on the operator's screen mid-session. Gated is not the same as
# unrun: without this step ~670 lines of the only tests covering those paths never execute under the
# repo's one verify command, which is indistinguishable from not having written them.
#
# They construct **no window** — no NSWindow anywhere in Tests/MeetingsAppTests, an NSHostingView is
# laid out off-screen, and the activation policy is .prohibited — which is what makes running them
# here safe rather than merely convenient. `AppSourceGuardTests` pins that no window is opened.
step "swift test (the editor suites, behind MEETINGS_LIVE_EDITOR)"
MEETINGS_LIVE_EDITOR=1 swift test --filter "EditorMountTests|ViewportProbeTests"

step "assemble dist/Meetings.app"
scripts/build-app.sh release

step "CLI smoke run against a throwaway store"
HOME_DIR="$(mktemp -d)"
trap 'rm -rf "$HOME_DIR"' EXIT
# Deliberately the copy inside the .app, not the one in .build: that binary is what a user actually
# gets when Settings symlinks it to /usr/local/bin, so that is the one worth smoking.
CLI="$ROOT/dist/Meetings.app/Contents/Helpers/meetings"
OUTPUT="$(MEETINGS_HOME="$HOME_DIR" "$CLI" status)"
echo "$OUTPUT"
case "$OUTPUT" in
    *"$HOME_DIR"*) ;;
    *) echo "verify: the CLI ignored MEETINGS_HOME — it resolved a store outside $HOME_DIR" >&2
       exit 1 ;;
esac

echo
echo "VERIFY OK"
