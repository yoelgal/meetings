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
step() { STEP=$((STEP + 1)); echo; echo "=== $STEP/9  $*"; }

step "the toolchain gate, and the Command Line Tools staying enough to build this"
# fix/install-requires-xcode. A stranger's install cloned the repo, spent their login password on a
# signing certificate, fetched every package and then died on `@Entry` — because the check that stood
# in install.sh asked "is there a macOS SDK", which the Command Line Tools pass and which says
# nothing about its version. Two invariants came out of that, and this is the cheap end of both.
#
# First: no macro whose plugin ships only inside Xcode. `libSwiftUIMacros.dylib` and its siblings
# live under Xcode's Platforms directory and have no copy in the Command Line Tools, so one `@Entry`
# or `#Preview` silently turns a 1.5 GB dependency into a 12 GB one — and fails twenty-five modules
# into someone else's build, with an error that reads like a bug in this source. `^[^/]*` so the
# comments that explain this rule are not caught by it. scripts/clean-clone-check.sh proves the real
# thing, by building with those tools; this is the tripwire that fires the moment one is typed.
XCODE_ONLY='@Entry|#Preview|@Model|@Query|#Predicate|#Expression'
MACRO_HITS="$(grep -rEn "^[^/]*($XCODE_ONLY)" Sources --include='*.swift' || true)"
[ -z "$MACRO_HITS" ] || { echo "verify: a macro whose plugin ships only inside Xcode — the Command
                       Line Tools cannot expand it, and the build fails partway through:
$MACRO_HITS" >&2; exit 1; }
echo "no Xcode-only macros in Sources"

# Second: both doors refuse a toolchain too old to build this, before doing anything. A stub xcrun
# reporting the macOS 15 SDK is the whole test — the real one here is 26, so nothing else can say
# what a 2024 toolchain would meet.
STUB="$(mktemp -d)"
printf '#!/bin/sh\ncase "$*" in *--show-sdk-version*) echo 15.7 ;; *) exit 1 ;; esac\n' > "$STUB/xcrun"
chmod +x "$STUB/xcrun"

OLD="$(PATH="$STUB:$PATH" scripts/build-app.sh release 2>&1 </dev/null)" \
    && { echo "verify: build-app.sh accepted a macOS 15 SDK" >&2; exit 1; }
case "$OLD" in
    *"targets macOS 26"*) echo "build-app.sh: $(printf '%s' "$OLD" | head -1)" ;;
    *) echo "verify: build-app.sh failed on a macOS 15 SDK, but not at the gate:
$OLD" >&2; exit 1 ;;
esac

# install.sh carries its own copy of the check, on purpose: it is fetched over curl and runs before
# this repo exists, so it cannot source one from here. It is also the copy that has to fire before
# the certificate prompt spends a password, so it is checked the same way rather than grepped for.
#
# `--from-source` explicitly, because that is now the only path a toolchain can matter on: the
# default installs a prebuilt release and never compiles anything, so it must NOT consult the SDK —
# refusing to install a downloaded binary because the machine cannot build one would be the whole
# point of the download inverted. A bare `./install.sh` here would therefore reach the network, and
# the assertion below would fail for the right reason at the wrong door.
SRC_PROBE="$STUB/should-not-exist"
OLD="$(PATH="$STUB:$PATH" MEETINGS_SRC="$SRC_PROBE" MEETINGS_NO_OPEN=1 ./install.sh --from-source 2>&1 </dev/null)" \
    && { echo "verify: install.sh --from-source accepted a macOS 15 SDK" >&2; exit 1; }
case "$OLD" in
    *"macOS 26 SDK"*) echo "install.sh: $(printf '%s' "$OLD" | head -1)" ;;
    *) echo "verify: install.sh failed on a macOS 15 SDK, but not at the gate:
$OLD" >&2; exit 1 ;;
esac
[ ! -e "$SRC_PROBE" ] || { echo "verify: install.sh cloned before checking the toolchain" >&2; exit 1; }
rm -rf "$STUB"

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

# The recording-memory check, alone in its own process, which is the only way its number means
# anything. It reads the RSS of the whole test process, and appending three hours of buffers takes
# about a hundred seconds — so inside the default run its baseline and its second reading sit either
# side of the *entire* suite, and every other test's allocations count as growth against a 32 MB
# budget. That is what made the gate flaky, and a flaky gate means a green run proves nothing.
#
# `--filter` leaves one test in the process and `--no-parallel` says why out loud. Nothing is skipped
# by this: the check moved here, it did not go away.
step "swift test (the recording-memory check, alone in the process)"
MEETINGS_MEMORY_CHECK=1 swift test --no-parallel --filter "longRecordingIsFlat"

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
# v7 is the repair for the three implementations that shipped under the identifier v6. Recording it
# is what stops a future build re-running the backfill, so an upgrade that quietly skipped it would
# look identical here and diverge on the next one.
sqlite3 "$OLD_HOME/store.db" "SELECT identifier FROM grdb_migrations" | grep -qx 'v7' \
    || fail "v7 was not recorded — the corrected actions pass did not run"
# And the copy taken before all of that. It is the only undo an irreversible rewrite of somebody's
# prose has, and it is what StoreOpenError tells a locked-out user to restore from, so "the upgrade
# worked" is not the whole of what this step is for. `-s`: a zero-byte file is a failed VACUUM.
SNAPSHOT="$(ls -1 "$OLD_HOME"/backups/store-*.db 2>/dev/null | tail -1 || true)"
[ -n "$SNAPSHOT" ] && [ -s "$SNAPSHOT" ] \
    || fail "the migration rewrote the store without leaving a snapshot in $OLD_HOME/backups"
# A restorable store, not a marker file: it opens, and its write-up is the one from *before* the
# rewrite. A copy taken after v6 would pass every check above and be worth nothing as an undo.
sqlite3 "$SNAPSHOT" "SELECT count(*) FROM meetings" >/dev/null \
    || fail "the snapshot is not a readable store: $SNAPSHOT"
if sqlite3 "$SNAPSHOT" "SELECT summary FROM meetings WHERE id = '0112-weekly'" | grep -q 'Send the numbers'
then fail "the snapshot already carries the migrated actions — it was taken after the rewrite"
fi

# One read path past `actions list`, because markdown export is one-way: a write-up it drops actions
# from is a backup that silently is not one.
old export 0112-weekly --format md --out "$OLD_HOME/md" >/dev/null
grep -rq "Send the numbers" "$OLD_HOME/md" || fail "markdown export dropped the migrated actions"

step "the install a user actually does: a prebuilt release, on a Mac with no compiler"
# Last, because it rebuilds dist/ as a release-shaped bundle and every step above wants the ordinary
# one. It is its own script rather than inline here because it stages a whole rehearsal — a signed
# bundle, a zip, a checksum, a throwaway certificate and a file:// release — and needs a cleanup trap
# of its own for the keychain it creates.
#
# What it is guarding is not the happy path. Meetings is not notarized, so Gatekeeper never inspects
# it: a curl download carries no quarantine attribute and macOS runs that check on nothing else. The
# checksum and signature refusals in install.sh are therefore the only thing between a user and
# whatever the network handed them, and this proves all three — an ad-hoc-signed release, a corrupted
# download, and the certificate pin — refuse without touching the app already installed.
bash scripts/install-check.sh

echo
echo "VERIFY OK"
