#!/usr/bin/env bash
#
# The acceptance for "somebody else can build this". Clones the repo into a throwaway directory and
# then does only what README.md tells a stranger to do — no repo knowledge, no extra steps. If a
# documented step does not work, this fails here rather than in someone's first hour with the code.
#
#   scripts/clean-clone-check.sh
#
# Four deliberate departures from the README, all of them so this can run unattended on a machine
# somebody is using, each marked "HARNESS" where it happens:
#   · the app is "installed" into a throwaway directory instead of /Applications
#   · the CLI is run from inside the bundle instead of being symlinked into /usr/local/bin (sudo)
#   · the app is launched with `open -g` and killed by pid, so it never steals focus
#   · the setup guide is marked done in the throwaway store before launch
# Everything else — the clone, the build, the assembled bundle, the launch, the window — is the
# documented path, run for real.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOT="$ROOT/dist/clean-clone-check.png"

# -P: the physical path. mktemp hands back /var/folders/…, but a launched process reports itself as
# /private/var/folders/…, and the pid lookup below matches on that path.
WORK="$(cd "$(mktemp -d)" && pwd -P)"
APP_PID=""
cleanup() {
    # Look the app up again on the way out: if the run failed between launching it and learning its
    # pid, that process would otherwise outlive the directory it was started from.
    [ -z "$APP_PID" ] && APP_PID="$(pgrep -f "$WORK/Applications/Meetings.app" 2>/dev/null || true)"
    [ -n "$APP_PID" ] && kill $APP_PID 2>/dev/null
    rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

STEP=0
step() { STEP=$((STEP + 1)); echo; echo "=== $STEP/7  $*"; }
fail() { echo; echo "clean-clone-check FAILED: $*" >&2; exit 1; }

# A second copy of the same bundle id would be handed to the running instance by LaunchServices, and
# then nothing here would be testing the app it just built.
pgrep -f "Meetings.app/Contents/MacOS/Meetings" >/dev/null \
    && fail "Meetings is already running. Quit it and re-run — otherwise the launch check would
                       photograph the copy you already have open."

step "clone into $WORK"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
CLONE="$WORK/meetings"
git clone --quiet --branch "$BRANCH" "$ROOT" "$CLONE" || fail "the clone did not work"
echo "cloned $BRANCH at $(git -C "$CLONE" rev-parse --short HEAD)"

# A clone only carries what is committed. Work in progress is exactly what most needs checking, so
# carry the working tree's uncommitted and untracked files across and say how many.
PENDING=0
while IFS= read -r -d '' f; do
    mkdir -p "$CLONE/$(dirname "$f")"
    cp "$ROOT/$f" "$CLONE/$f"
    PENDING=$((PENDING + 1))
done < <(git -C "$ROOT" ls-files --modified --others --exclude-standard -z)
echo "carried $PENDING uncommitted file(s) across into the clone"

[ -f "$CLONE/README.md" ] || fail "there is no README.md — a stranger has nothing to follow"

step "build it — the README's one command: ./scripts/build-app.sh"
cd "$CLONE"
# With the Command Line Tools rather than this Mac's Xcode, when they are new enough. They are what
# README.md asks for and the cheaper thing a stranger installs — 1.5 GB against Xcode's 12 — so they
# are the toolchain a fresh clone is worth proving against. This is also the only mechanical proof
# that no macro whose plugin ships solely inside Xcode has crept into Sources: verify.sh greps for
# them in a fraction of a second, and this compiles the whole app without them.
#
# Stale Command Line Tools beside a current Xcode would fail the SDK gate for a reason that has
# nothing to do with this clone, so that case says so out loud and uses the default toolchain.
CLT="/Library/Developer/CommandLineTools"
CLT_SDK="$(DEVELOPER_DIR="$CLT" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
if [ "${CLT_SDK%%.*}" -ge 26 ] 2>/dev/null; then
    echo "building with the Command Line Tools (macOS $CLT_SDK SDK)"
    DEVELOPER_DIR="$CLT" ./scripts/build-app.sh \
        || fail "./scripts/build-app.sh did not succeed in a fresh clone with the Command Line Tools —
                       a stranger with no Xcode cannot build this"
else
    echo "no Command Line Tools with a macOS 26 SDK here (found ${CLT_SDK:-none}) — building with $(xcode-select -p)"
    ./scripts/build-app.sh || fail "./scripts/build-app.sh did not succeed in a fresh clone"
fi
[ -d "$CLONE/dist/Meetings.app" ] || fail "the README promises dist/Meetings.app and it is not there"

step "install it — the README's mv into /Applications"
# HARNESS: a throwaway directory stands in for /Applications. The move itself, and everything after
# it, runs against the moved copy exactly as it would on a real install.
APPS="$WORK/Applications"
mkdir -p "$APPS"
mv "$CLONE/dist/Meetings.app" "$APPS/" || fail "the assembled app could not be moved"
APP="$APPS/Meetings.app"
codesign --verify --strict "$APP" || fail "the moved app does not verify — it will not launch"
echo "installed at $APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|Signature|Authority)=' || true

step "install the CLI and run it"
# HARNESS: the README symlinks Contents/Helpers/meetings into /usr/local/bin, which needs sudo. The
# binary and the path are the documented ones; only the symlink is skipped. MEETINGS_HOME keeps the
# check away from a real store — it is the store this run creates, not the one on this Mac.
CLI="$APP/Contents/Helpers/meetings"
[ -x "$CLI" ] || fail "the README's CLI path does not exist inside the bundle: $CLI"
STORE="$WORK/store"
MEETINGS_HOME="$STORE" "$CLI" status || fail "meetings status failed"
MEETINGS_HOME="$STORE" "$CLI" status | grep -qF "$STORE" \
    || fail "meetings status did not report the store it was pointed at"

step "install the agent skill"
# A throwaway HOME: `meetings skill install` writes into ~/.claude, and a check has no business
# touching the agent configuration of whoever is running it.
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"
HOME="$FAKE_HOME" MEETINGS_HOME="$STORE" "$CLI" skill install || fail "meetings skill install failed"
[ -s "$FAKE_HOME/.claude/skills/meetings/SKILL.md" ] \
    || fail "skill install reported success but wrote no SKILL.md"

step "the optional signing script explains itself and does nothing"
# The README tells the reader --dry-run prints the plan and stops, so check that it does. Only the
# dry run: the real thing writes to a keychain, which is nobody's decision but the reader's.
PLAN="$("$CLONE/scripts/make-signing-identity.sh" --dry-run)" || fail "--dry-run did not succeed"
grep -q "delete-identity" <<<"$PLAN" || fail "--dry-run did not print how to undo itself"
grep -q "nothing was done" <<<"$PLAN" || fail "--dry-run did not say it had done nothing"
echo "--dry-run printed its plan and the undo command, and stopped"

step "launch it and photograph the window"
# HARNESS: `open -g` and a kill by pid. The README says to double-click it; this must not take focus
# from whoever is using the Mac. MEETINGS_CALENDAR_FIXTURE (an empty event list) guarantees the
# launched app cannot read a real calendar even if the permission happens to be granted.
echo "[]" > "$WORK/calendar.json"
# HARNESS: an empty store means the app opens its setup guide as a sheet, and a sheet on an app
# launched with `open -g` never gets a window backing store — CGWindowList reports both windows and
# screencapture can photograph neither. Someone double-clicking the app sees the guide and it works
# normally; this check cannot, so it marks setup done in its own throwaway store first.
MEETINGS_HOME="$STORE" "$CLI" config set onboarding.completed true >/dev/null \
    || fail "could not mark onboarding complete in the throwaway store"
open -g -a "$APP" \
    --env "MEETINGS_HOME=$STORE" \
    --env "MEETINGS_CALENDAR_FIXTURE=$WORK/calendar.json" \
    || fail "the app would not launch"

for _ in $(seq 1 20); do
    APP_PID="$(pgrep -f "^$APP/Contents/MacOS/Meetings" || true)"
    [ -n "$APP_PID" ] && break
    sleep 1
done
[ -n "$APP_PID" ] || fail "the app launched and then was not running"
echo "running as pid $APP_PID"

# A sleeping display has no window backing store and screencapture fails with "could not create
# image from window". -u wakes the display and nothing else — no focus, no sound. shot.sh
# caffeinates too, but it shoots the moment it finds the window, which can be sooner than the
# display comes back, so wake it first and retry once.
caffeinate -u -t 60 &
CAFF=$!
sleep 3
# scripts/shot.sh is part of the clone: it finds the window through CGWindowList by pid and captures
# it without raising it. No window inside its timeout is a failure — an app that launches into no
# window has not started for a user.
"$CLONE/scripts/shot.sh" "$APP_PID" "$SHOT" 25 \
    || "$CLONE/scripts/shot.sh" "$APP_PID" "$SHOT" 25 \
    || fail "no window could be photographed"
{ kill "$CAFF"; wait "$CAFF"; } 2>/dev/null || true   # wait, so bash does not print the job's death
[ -s "$SHOT" ] || fail "the screenshot is empty"

kill "$APP_PID"
for _ in $(seq 1 10); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 1; done
kill -0 "$APP_PID" 2>/dev/null && fail "the app did not exit"
APP_PID=""
echo "quit cleanly"

echo
echo "CLEAN CLONE OK — built from a fresh clone following README.md alone."
echo "window: $SHOT"
