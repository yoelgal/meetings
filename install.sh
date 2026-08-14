#!/bin/bash
#
# Meetings — one-command install.
#
#   gh repo clone yoelgal/meetings -- --quiet && bash meetings/install.sh
#
# Clones (if needed), builds, installs the app and the command line tool, and opens the app so it can
# fetch its speech models. Safe to re-run: it upgrades in place.
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
if [ -f "$(dirname "${BASH_SOURCE[0]}")/Package.swift" ]; then
    cd "$(dirname "${BASH_SOURCE[0]}")"
else
    SRC="${MEETINGS_SRC:-$PWD/meetings}"
    if [ -d "$SRC/.git" ]; then
        say "Updating $SRC"
        git -C "$SRC" pull --ff-only --quiet
    else
        say "Cloning into $SRC"
        git clone --quiet "$REPO" "$SRC" \
          || die "Clone failed. The repository is private — authenticate first with:
    gh auth login"
    fi
    cd "$SRC"
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
