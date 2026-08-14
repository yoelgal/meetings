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

command -v swift >/dev/null 2>&1 || die "No Swift toolchain. Install Xcode from the App Store, then run:
    sudo xcode-select -s /Applications/Xcode.app
    sudo xcodebuild -license accept"

# swift exists but points at the Command Line Tools, which cannot build a SwiftUI app.
xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 \
  || die "The active developer directory has no macOS SDK. Install Xcode, then:
    sudo xcode-select -s /Applications/Xcode.app"

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
if [ -d "$APPS/Meetings.app" ]; then
    say "Replacing $APPS/Meetings.app"
    # A running copy holds its bundle open, and mv over a live app leaves it half-replaced.
    pkill -x Meetings 2>/dev/null && sleep 1 || true
    rm -rf "$APPS/Meetings.app"
fi
say "Installing to $APPS"
mv dist/Meetings.app "$APPS/" 2>/dev/null || {
    say "$APPS needs an administrator; you will be asked for your password"
    sudo mv dist/Meetings.app "$APPS/"
}

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
