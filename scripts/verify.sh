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
step() { STEP=$((STEP + 1)); echo; echo "=== $STEP/6  $*"; }

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

step "the upgrade: a 0.1.2-shaped store, migrated by the shipped CLI"
# Every other step here runs against a store the current build created, which is a store already at
# the current schema — so nothing above this line has ever run a migration over data. `v6` moves
# actions out of a column and into the write-up, it runs exactly once on somebody's real store, and
# there is no second chance at it: this is the step that gets to be wrong before a release does.
#
# The input is scripts/fixtures/store-0.1.2.sql — raw SQL, frozen, written by hand. Building it by
# migrating with Schema.migrator would mean the check's input came from the code under test, and a
# migration cannot be caught misreading a shape it also defines.
OLD_HOME="$(mktemp -d)"
trap 'rm -rf "$HOME_DIR" "$OLD_HOME"' EXIT
sqlite3 "$OLD_HOME/store.db" < "$ROOT/scripts/fixtures/store-0.1.2.sql"

fail() { echo "verify: $1" >&2; exit 1; }
old() { MEETINGS_HOME="$OLD_HOME" "$CLI" "$@"; }

ACTIONS="$(old actions list)"
echo "$ACTIONS"

# The whole point: what was only ever in the `actions` column is readable through the write-up now.
[ "$(printf '%s\n' "$ACTIONS" | grep -c '0112-weekly')" = 2 ] \
    || fail "expected the 0.1.2 meeting's two actions, got:
$ACTIONS"
case "$ACTIONS" in *"Send the numbers"*) ;; *) fail "the open action did not survive the migration" ;; esac
case "$ACTIONS" in *"[x]"*"Book the follow-up"*) ;; *) fail "the done action lost its tick" ;; esac

# Nothing else in the write-up was touched. The 0.1.2 template's other three sections are the rest
# of what the user wrote, and a migration that appends to a document can also eat it.
SUMMARY="$(old show 0112-weekly --summary)"
case "$SUMMARY" in *"Do we grandfather the annual plans?"*) ;;
    *) fail "the migration lost the rest of the write-up:
$SUMMARY" ;; esac

# Idempotent through the ledger *and* through the merge: a second open must not deal a second copy.
old status >/dev/null
[ "$(old actions list | grep -c '0112-weekly')" = 2 ] || fail "a second open duplicated the actions"

# The safety net the migration is allowed to lean on when it drops owner and due into plain
# markdown: the old column still holds exactly what the old build wrote.
sqlite3 "$OLD_HOME/store.db" "SELECT actions FROM meetings WHERE id = '0112-weekly'" | grep -q 'Sofia' \
    || fail "the legacy actions column lost the owner it is the only copy of"
sqlite3 "$OLD_HOME/store.db" "SELECT identifier FROM grdb_migrations" | grep -qx 'v6' \
    || fail "the store was read without v6 being recorded — the migration did not run"

# One read path past `actions list`, because markdown export is one-way: a write-up it drops actions
# from is a backup that silently is not one.
old export 0112-weekly --format md --out "$OLD_HOME/md" >/dev/null
grep -rq "Send the numbers" "$OLD_HOME/md" || fail "markdown export dropped the migrated actions"

echo
echo "VERIFY OK"
