#!/bin/bash
#
# Meetings — one-command install.
#
#   curl -fsSL https://raw.githubusercontent.com/yoelgal/meetings/main/install.sh | bash
#
# Clones (if needed), sets up code signing, builds, installs the app and the command line tool, and
# opens the app so it can fetch its speech models. Safe to re-run: it upgrades in place.
#
# Written to survive being piped into bash, which is the shape of the command above. Under a pipe
# stdin is the *script*, so anything reading from stdin eats its own source: every prompt here reads
# from /dev/tty instead, and everything this calls is handed /dev/tty too.
#
# Overrides, all optional:
#   MEETINGS_APPS=/path      where the .app goes            (default /Applications)
#   MEETINGS_BIN=/path       where the CLI symlink goes     (default /usr/local/bin)
#   MEETINGS_SRC=/path       where to clone if not in a checkout (default ./meetings)
#   MEETINGS_NO_OPEN=1       build and install, do not launch
set -euo pipefail

APPS="${MEETINGS_APPS:-/Applications}"
BIN="${MEETINGS_BIN:-/usr/local/bin}"
REPO="https://github.com/yoelgal/meetings.git"

say()  { printf '\033[1m==>\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mmeetings:\033[0m %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- requirements
[ "$(uname -s)" = "Darwin" ] || die "Meetings is macOS only."

major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || die "Needs macOS 26 or later; this is $(sw_vers -productVersion)."

# ---------------------------------------------------------------- the toolchain
# One requirement, and it is not Xcode: a Swift toolchain whose macOS SDK is 26 or newer, because
# Package.swift targets macOS 26. The Command Line Tools are enough — about 1.5 GB and no Apple ID,
# against Xcode's 12 GB — and this app deliberately uses no Xcode-only macro so that stays true;
# scripts/verify.sh pins it.
#
# What follows repairs the two states that are repairable and explains the two that are not. It used
# to do neither: the check that stood here asked "is there a macOS SDK", which the Command Line Tools
# pass and which says nothing about the SDK's version, so a Mac that could not build this cloned the
# repo, spent the user's login password on a signing certificate, fetched every package, and failed
# in the compiler half an hour later.

# Yes unless they say no, and a no when there is nobody to ask — every caller answers that with the
# exact command to run by hand, which is the right outcome for a CI job or an agent.
#
# From /dev/tty, because under `curl | bash` stdin is the script itself. `[ -r /dev/tty ]` is not
# enough on its own: with no controlling terminal the device is still readable by that test and the
# open fails anyway, so the read's own failure has to count as a no rather than fall through to the
# default yes. `2>/dev/null` before the redirection, not after — bash applies them left to right, and
# the other order prints "/dev/tty: Device not configured" before the suppression takes effect.
ask() {
    printf '    %s [Y/n] ' "$1"
    if ! read -r reply 2>/dev/null < /dev/tty; then echo "(no terminal to ask on)"; return 1; fi
    case "$reply" in [nN]*) return 1 ;; *) return 0 ;; esac
}

# The macOS SDK major of a developer directory ("26"), or nothing at all if it has none. `|| true`
# because a failing command substitution in an assignment takes the whole script down under `set -e`.
sdk_major() {
    DEVELOPER_DIR="$1" xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1 || true
}

CLT=/Library/Developer/CommandLineTools
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
SDK="$(sdk_major "$DEV_DIR")"

if [ "${SDK:-0}" -lt 26 ]; then
    # Something newer may already be installed and simply not selected — a second Xcode, or the
    # Command Line Tools sitting behind an Xcode that is too old. Pick the best of what is here.
    BEST=""
    BEST_SDK=0
    for candidate in /Applications/Xcode*.app/Contents/Developer "$CLT"; do
        [ -d "$candidate" ] || continue
        found="$(sdk_major "$candidate")"
        if [ "${found:-0}" -gt "$BEST_SDK" ]; then
            BEST="$candidate"
            BEST_SDK="${found:-0}"
        fi
    done

    if [ "$BEST_SDK" -ge 26 ] && [ "$BEST" != "$DEV_DIR" ]; then
        echo
        echo "    The developer tools in use are ${DEV_DIR:-not set}, whose macOS SDK is"
        echo "    ${SDK:-too old to read} — this needs 26. You already have a newer one installed:"
        echo
        echo "        $BEST  (macOS $BEST_SDK SDK)"
        echo
        echo "    Switching is one command, and macOS will ask for your password because it changes"
        echo "    a system-wide setting: sudo xcode-select -s $BEST"
        echo
        ask "Switch to it now?" \
            || die "Left alone. Run this when you are ready, then re-run the install:
    sudo xcode-select -s $BEST"
        say "switching the developer tools to $BEST"
        sudo xcode-select -s "$BEST" < /dev/tty \
            || die "That did not take. Run it by hand, then re-run the install:
    sudo xcode-select -s $BEST"
    elif [ ! -d "$CLT" ]; then
        # Nothing usable is installed at all. `xcode-select --install` opens Apple's own installer,
        # needs no sudo and no Apple ID, and is the whole of what this app needs to build.
        echo
        echo "    This Mac has no Swift toolchain yet. The Command Line Tools are what this app"
        echo "    needs — about 1.5 GB, from Apple, no Apple ID and no Xcode. macOS runs its own"
        echo "    installer; a window will appear and this will wait for it."
        echo
        ask "Install them now?" \
            || die "Nothing installed. Run this when you are ready, then re-run the install:
    xcode-select --install"
        # A refused request is not something to wait 40 minutes on: Software Update has to be
        # reachable and offering them, and when it is not it says so immediately.
        if ! request="$(xcode-select --install 2>&1)"; then
            if [ -n "$request" ]; then printf '    %s\n' "$request"; fi
            die "macOS would not start the installer. Install the command line developer tools from
    System Settings → General → Software Update, then re-run this."
        fi
        say "Waiting for the Command Line Tools to finish installing"
        waited=0
        while :; do
            found="$(sdk_major "$CLT")"
            if [ "${found:-0}" -ge 26 ]; then break; fi
            waited=$((waited + 1))
            if [ "$waited" -ge 160 ]; then
                die "Still not installed after 40 minutes. Finish Apple's installer, then re-run this."
            fi
            if [ $((waited % 8)) -eq 0 ]; then say "still installing…"; fi
            sleep 15
        done
        # macOS makes a fresh install the active developer directory on its own. If it somehow did
        # not, the check below says so — better than a second sudo on a guess.
    fi

    # Whatever happened above, the requirement is the requirement.
    DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
    SDK="$(sdk_major "$DEV_DIR")"
    [ "${SDK:-0}" -ge 26 ] || die "The developer tools here (${DEV_DIR:-none}) have no macOS 26 SDK, and this
    app is built against macOS 26 APIs. Update the Command Line Tools in System Settings →
    General → Software Update, or Xcode in the App Store, then re-run this."
fi

# The toolchain is the right vintage; this asks whether it actually runs. An Xcode whose licence has
# never been accepted fails here rather than twenty-five modules into the build.
probe="$(swift --version 2>&1)" || case "$probe" in
    *[lL]icense*)
        echo
        echo "    Xcode's licence has not been accepted on this Mac, and nothing compiles until it"
        echo "    is. macOS will ask for your password: sudo xcodebuild -license accept"
        echo
        ask "Accept it now?" \
            || die "Not accepted. Run this, then re-run the install:
    sudo xcodebuild -license accept"
        sudo xcodebuild -license accept < /dev/tty \
            || die "The licence was not accepted. Run it by hand, then re-run the install:
    sudo xcodebuild -license accept"
        ;;
    *)
        die "The Swift toolchain at ${DEV_DIR:-none} does not run:
$probe"
        ;;
esac

# ---------------------------------------------------------------- get the source
# Only when this script is a real file sitting next to the package. Piped into bash there is no
# `$0` on disk, `dirname` of nothing is `.`, and the test would silently adopt whatever directory the
# user happened to be standing in if it had a Package.swift — building someone else's project.
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$SELF" ] && [ -f "$(dirname "$SELF")/Package.swift" ]; then
    cd "$(dirname "$SELF")"
else
    SRC="${MEETINGS_SRC:-$PWD/meetings}"
    if [ -d "$SRC/.git" ]; then
        say "Updating $SRC"
        git -C "$SRC" pull --ff-only --quiet
    else
        say "Cloning into $SRC"
        git clone --quiet "$REPO" "$SRC" || die "Clone failed. Check your network, or clone by hand:
    git clone $REPO"
    fi
    cd "$SRC"
fi

# ---------------------------------------------------------------- code signing
# Before the build, because build-app.sh reads the identity at signing time.
#
# macOS keys a permission grant to the app's code signature, and an ad-hoc signature *is* a hash of
# the app's own code. Without a stable certificate, this install and every future update look like
# different apps and each one re-asks for the microphone and for Screen Recording. That is the single
# worst thing about updating a build-from-source app, and it is one script to avoid.
#
# build-app.sh offers this too, but only when it can see a terminal on stdin — which it cannot when
# this script is piped into bash. So it is asked here, from /dev/tty, and build-app.sh is told not to
# ask again.
export MEETINGS_SIGN_ADHOC=1
LOCAL_IDENTITY="Meetings Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$LOCAL_IDENTITY"; then
    say "Signing with the certificate you already have"
elif [ -r /dev/tty ]; then
    cat <<'EXPLAIN'

    macOS ties app permissions to a code signature. Signed ad hoc, every rebuild looks
    like a brand new app, so you re-grant the microphone and Screen Recording after every
    update. A self-signed certificate that stays put fixes it, for this Mac only.

    macOS will ask for your login password once, to trust it.

EXPLAIN
    printf '    Create it now? [Y/n] '
    read -r reply < /dev/tty || reply=""
    case "$reply" in
        [nN]*)
            say "Skipped. Run scripts/make-signing-identity.sh whenever you want the re-asking to stop."
            ;;
        *)
            # --yes because the explanation above already asked; the script's own confirmation would
            # be the same question twice. /dev/tty because macOS prompts for the login password.
            bash scripts/make-signing-identity.sh --yes < /dev/tty \
                || say "Certificate setup did not finish. Continuing with an ad-hoc signature."
            ;;
    esac
else
    say "No terminal to ask on — signing ad hoc. Run scripts/make-signing-identity.sh later."
fi

# ---------------------------------------------------------------- build
say "Building (first run fetches packages, so it takes a few minutes)"
bash scripts/build-app.sh

# ---------------------------------------------------------------- install the app
# The old bundle is moved aside rather than deleted, and only removed once its replacement is in
# place. `rm -rf` first meant a Ctrl-C, a full disk or a refused sudo in the seconds that followed
# left the Mac with no Meetings.app at all and a `meetings` symlink pointing into nothing — from an
# upgrade the user was told was safe to re-run. A rename is atomic and the undo is another rename.
OLD_BUNDLE=""
if [ -d "$APPS/Meetings.app" ]; then
    say "Replacing $APPS/Meetings.app"
    # A running copy holds its bundle open, and mv over a live app leaves it half-replaced. It also
    # holds the *store* open, which is the worse half: an old process still sitting on a write-up it
    # read before the upgrade will write that stale text back over a schema migration the new build
    # has meanwhile run and recorded as done. Migrations do not run twice, so nothing puts it back.
    #
    # So this waits for the process to really be gone rather than assuming it. One second was never
    # enough: while a recording is in flight the app *catches* SIGTERM on purpose
    # (RecordingController.installTerminationGuard) to close both WAVs and move the meeting on before
    # it exits, and stopping a ScreenCaptureKit stream takes longer than the sleep it was given. Ten
    # seconds and then a refusal — this is a one-shot upgrade, not the edit-run loop, so it can
    # afford to wait, and stopping is always better than replacing the app underneath a live process.
    #
    # Matched on the full executable path rather than `pkill -x Meetings`: scripts/build-app.sh keeps
    # CFBundleExecutable as `Meetings` for the dev bundle too, so the name alone also kills a running
    # meetings-dev — the same collateral scripts/dev.sh matches by path to avoid in the other
    # direction.
    EXEC_PATH="$APPS/Meetings.app/Contents/MacOS/Meetings"
    if pgrep -f "^$EXEC_PATH$" >/dev/null 2>&1; then
        say "Waiting for the running app to finish and quit"
        pkill -f "^$EXEC_PATH$" 2>/dev/null || true
        for _ in $(seq 40); do
            pgrep -f "^$EXEC_PATH$" >/dev/null 2>&1 || break
            sleep 0.25
        done
        if pgrep -f "^$EXEC_PATH$" >/dev/null 2>&1; then
            die "Meetings is still running and will not quit.

    Quit it yourself — stop any recording first, then Meetings > Quit — and run this again.
    Replacing the app now would leave the old process writing to a store this build has
    already migrated."
        fi
    fi
    OLD_BUNDLE="$APPS/Meetings.app.replaced-$$"
    mv "$APPS/Meetings.app" "$OLD_BUNDLE" 2>/dev/null || {
        say "$APPS needs an administrator; you will be asked for your password"
        sudo mv "$APPS/Meetings.app" "$OLD_BUNDLE"
    }
    # Anything that goes wrong from here to the install leaves the old app one rename from working,
    # so put it back rather than leaving the user with neither. EXIT only: with no handler on INT,
    # Ctrl-C terminates the script the normal way and this runs on the way out.
    trap 'if [ -d "$OLD_BUNDLE" ] && [ ! -d "$APPS/Meetings.app" ]; then
              mv "$OLD_BUNDLE" "$APPS/Meetings.app" 2>/dev/null \
                  || sudo mv "$OLD_BUNDLE" "$APPS/Meetings.app" 2>/dev/null || true
          fi' EXIT
fi
say "Installing to $APPS"
mv dist/Meetings.app "$APPS/" 2>/dev/null || {
    say "$APPS needs an administrator; you will be asked for your password"
    sudo mv dist/Meetings.app "$APPS/"
}
# Committed. The old one goes now, and the restore trap with it.
trap - EXIT
if [ -n "$OLD_BUNDLE" ]; then
    rm -rf "$OLD_BUNDLE" 2>/dev/null || sudo rm -rf "$OLD_BUNDLE"
fi

# ---------------------------------------------------------------- install the CLI
CLI="$APPS/Meetings.app/Contents/Helpers/meetings"
if ln -sfn "$CLI" "$BIN/meetings" 2>/dev/null; then
    say "Linked $BIN/meetings"
elif sudo ln -sfn "$CLI" "$BIN/meetings" 2>/dev/null; then
    say "Linked $BIN/meetings"
else
    say "Could not write to $BIN — link it yourself with:"
    printf '      sudo ln -sfn "%s" %s/meetings\n' "$CLI" "$BIN"
fi

# ---------------------------------------------------------------- install the agent skill
if "$CLI" skill install >/dev/null 2>&1; then
    say "Installed the agent skill"
fi

# ---------------------------------------------------------------- done
echo
say "Installed."
echo "    Meetings.app   $APPS/Meetings.app"
command -v meetings >/dev/null 2>&1 && echo "    meetings       $(command -v meetings)"
echo
echo "    Setup will ask for the microphone and for Screen Recording — macOS files"
echo "    audio-only capture under that name, and Meetings never records your screen."
echo "    It then downloads about 1 GB of speech models, once."
echo

[ "${MEETINGS_NO_OPEN:-}" = "1" ] || open "$APPS/Meetings.app"
