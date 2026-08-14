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
step() { STEP=$((STEP + 1)); echo; echo "=== $STEP/4  $*"; }

step "swift build"
swift build

step "swift test"
swift test

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
