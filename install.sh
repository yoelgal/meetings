#!/bin/bash
#
# Meetings — one-command install.
#
#   curl -fsSL https://raw.githubusercontent.com/yoelgal/meetings/main/install.sh | bash
#
# Downloads the current release, checks it against its published checksum and its code signature,
# installs the app and the command line tool, and opens the app so it can fetch its speech models.
# Fifteen seconds, no compiler, no password. Safe to re-run: it upgrades in place.
#
#   install.sh --from-source     clone and build here instead. Slower by half an hour and it needs
#                                Apple's command line tools, but it is how you run your own changes.
#
# Written to survive being piped into bash, which is the shape of the command above. Under a pipe
# stdin is the *script*, so anything reading from stdin eats its own source: every prompt here reads
# from /dev/tty instead, and everything this calls is handed /dev/tty too.
#
# The release is not notarized and never will be — notarizing needs a paid Apple Developer
# membership. It does not need to be: Gatekeeper runs its notarization check on files carrying the
# com.apple.quarantine attribute, and that attribute is written by browsers and by Archive Utility,
# not by curl. Downloaded here the app launches with no dialog; the same zip fetched in Safari and
# double-clicked would be refused. So the checks Apple would have done are done here instead: the
# download is checked against its published checksum, and the unpacked bundle against the signing
# certificate this file names. Nothing installed is touched until both have passed — the unpacking in
# between happens in a temp directory that is deleted on the way out.
#
# Overrides, all optional:
#   MEETINGS_ASSET_URL=url     download this instead of the GitHub release (file:// works)
#   MEETINGS_ASSET_SHA256=hex  the expected digest, instead of fetching <asset-url>.sha256
#   MEETINGS_VERSION=v0.3.0    install this release rather than the latest
#   MEETINGS_APPS=/path        where the .app goes                (default /Applications)
#   MEETINGS_BIN=/path         where the CLI symlink goes         (default /usr/local/bin)
#   MEETINGS_SRC=/path         where --from-source clones to      (default ./meetings)
#   MEETINGS_NO_OPEN=1         install, do not launch
#
# On the piped command at the top they go on `bash`, on the right of the pipe:
#
#   curl -fsSL …/install.sh | MEETINGS_VERSION=v0.3.0 bash
#
# In front of `curl` they end up in the downloader's environment and this script never sees them, so
# the install silently does the default thing — which for MEETINGS_VERSION means reinstalling the
# release you were trying to get away from.
set -euo pipefail

APPS="${MEETINGS_APPS:-/Applications}"
REPO="https://github.com/yoelgal/meetings.git"
RELEASES="https://github.com/yoelgal/meetings/releases"
ASSET="Meetings-arm64.zip"
# The SHA-1 of the one certificate every release is signed with, and the only thing here that decides
# whether a download is genuinely ours. A literal rather than a file read, because this script is
# normally piped straight out of `main` into bash with no checkout anywhere near it, and a check that
# needs a file it cannot have is a check that never runs.
#
# It is the value in Packaging/distribution-cert.sha1, and the two are cross-checked below whenever a
# checkout is present. Rotating the certificate means changing both, in the same commit.
DIST_CERT_SHA1="f5568c5d976fef4de1f44da76d6df5498a4fe882"

# Pinned alongside the certificate, because a requirement naming only a certificate would accept any
# app that certificate ever signed. Both halves together are what "this is Meetings, from us" means.
BUNDLE_ID="com.yoelgal.Meetings"

say()  { printf '\033[1m==>\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mmeetings:\033[0m %s\n' "$1" >&2; exit 1; }

# Only when this script is a real file on disk. Piped into bash there is no `$0` to read, `$0` is
# `bash` itself, and anything resolved relative to it points at /bin.
SELF="${BASH_SOURCE[0]:-}"
[ -n "$SELF" ] && [ -f "$SELF" ] || SELF=""

# ---------------------------------------------------------------- arguments
# The header block above is the usage text, the way scripts/make-signing-identity.sh does it, except
# read up to the first non-comment line rather than to a hardcoded line number — a range in here
# silently stops covering the last paragraph the first time someone adds one. Piped into bash there
# is no file to read it back out of, so that case says where the text lives instead of printing
# nothing.
usage() {
    if [ -n "$SELF" ]; then
        awk 'NR == 1 { next } /^#/ { print substr($0, 3); next } { exit }' "$SELF"
    else
        echo "Meetings installer. Downloads the current release and installs it."
        echo "    --from-source   clone and build from source instead"
        echo "Every option: https://github.com/yoelgal/meetings/blob/main/install.sh"
    fi
}

FROM_SOURCE=0
for arg in "$@"; do
    case "$arg" in
        --from-source) FROM_SOURCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install: unknown argument: $arg" >&2; exit 64 ;;
    esac
done

# ---------------------------------------------------------------- what this Mac has to be
# Before anything is downloaded, cloned or replaced: every one of these is a refusal, and a refusal
# after a 90 MB download is a refusal that wasted the download.
[ "$(uname -s)" = "Darwin" ] || die "Meetings is macOS only."

major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || die "Needs macOS 26 or later; this is $(sw_vers -productVersion)."

# Named rather than called an unsupported platform, because "unsupported" reads as an oversight
# somebody could fix. Transcription runs the speech models through CoreML on the Apple Silicon
# neural engine, so there is no slower Intel build waiting to be enabled — there is no Intel build.
[ "$(uname -m)" = "arm64" ] || die "This Mac has an Intel processor, and there is no Intel build of Meetings.
    Transcription runs its speech models on the Apple Silicon neural engine through CoreML, so
    there is nothing here to fall back to — not a slower build, none."

# ---------------------------------------------------------------- where the app is going
# Resolved here, before anything at all is derived from it. THE INVARIANT: nothing computed from
# $APPS may be computed before $APPS is final. This block used to sit down beside the swap, three
# hundred lines after the recording guard had already built $EXEC_PATH, $INSTALLED_CLI and
# $INSTALLED_REQ out of the pre-fallback value — so on the fallback path the guard probed a bundle
# nobody was replacing, `pkill` matched a path nothing was running from, and $INSTALLED_REQ stayed
# empty, which printed the fresh-install text over somebody's upgrade and no permission note at all.
# A live app kept running straight through "Installed." That was every standard non-admin account:
# the exact population the fallback exists for.
#
# An unwritable /Applications used to mean a sudo prompt, and this script no longer has a reason to
# ask for a password: nothing it does needs root except writing there. ~/Applications is a real
# application directory that Spotlight, Launchpad and `open` all know, so the fallback costs the user
# nothing but a path.
#
# Only when they did not name a directory themselves. An explicit MEETINGS_APPS is an instruction,
# and installing somewhere else because that one was awkward is ignoring it. The directory itself is
# created at the swap rather than here, so a run that refuses leaves no directories behind.
if [ -z "${MEETINGS_APPS:-}" ] && [ ! -w "$APPS" ]; then
    APPS="$HOME/Applications"
    say "/Applications needs an administrator and this installer never asks for your password, so
    the app is going to $APPS instead."
fi

# ---------------------------------------------------------------- one install at a time
# Two of these running at once share every path they touch, and the window is not small: the
# quit-and-wait below can hold one of them for ten seconds between testing the destination and
# renaming onto it. The outcomes range from one run deleting the aside copy the other's trap is about
# to restore, to a bundle nested inside a bundle. The guard at the swap makes the nesting impossible;
# this makes the collision itself unlikely, and turns it into a sentence instead of a race.
#
# `mkdir` is the lock because it is atomic on every filesystem this can land on, needs no flock (which
# macOS `/usr/bin` does not ship) and leaves something a human can read and delete. The holder's pid
# goes inside it, so a lock left behind by a killed run is recognisable rather than permanent: no live
# process behind it means it is stale and gets taken. Compared with a timeout, this has no wrong
# answer to pick — an install that legitimately takes longer than any timeout would still be running.
LOCK=""
LOCK_DIR="${TMPDIR:-/tmp}/meetings-install.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    HOLDER="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; then
        die "Another Meetings install is running (process $HOLDER). Two at once can leave this Mac
    with a broken app, so this one has stopped and changed nothing. Wait for that one to finish."
    fi
    # Stale: whoever made it is gone. Reclaimed rather than reported, because the alternative is
    # telling somebody to delete a directory in TMPDIR to install an app.
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    mkdir "$LOCK_DIR" 2>/dev/null \
        || die "Could not take the install lock at $LOCK_DIR. Remove it and try again."
fi
LOCK="$LOCK_DIR"
printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true

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

# ---------------------------------------------------------------- cleanup
# One EXIT handler for both things that need undoing, because a shell has one EXIT trap and this
# script now has two undos: the download directory, and the old bundle waiting to be put back. Two
# `trap` statements would mean the second silently replacing the first, and the `trap - EXIT` that
# used to mark the swap as committed would take the download cleanup with it.
#
# The old bundle has exactly one owner — this function — and one question decides its fate on every
# path out: is there a working app at the destination? That replaces a commit step that cleared
# `OLD_BUNDLE` and then deleted the aside copy itself, which was wrong twice over. An interrupt
# between the rename and the clearing orphaned a `Meetings.app.replaced-<pid>` nobody would ever
# recognise, and the delete ran unguarded under `set -e`: a root-owned old bundle routes the
# move-aside through `sudo`, which makes the aside copy root-owned too, so a declined password ended
# the script *after* the new app was in place — skipping the CLI symlink, the skill install, the
# version summary, the permission note and `open`, and exiting 1 from a command the README calls safe
# to re-run.
WORK=""
OLD_BUNDLE=""
cleanup() {
    if [ -n "$OLD_BUNDLE" ] && [ -d "$OLD_BUNDLE" ]; then
        # A directory at the destination is not the same thing as an app: a cross-device `mv` copies,
        # and one that fails halfway leaves a bundle with no executable in it. `[ -d ]` alone read
        # that wreck as a finished install and suppressed the undo, leaving the user with half an app
        # and a good one parked under a name they would never think to look at.
        if [ -x "$APPS/Meetings.app/Contents/MacOS/Meetings" ]; then
            # Committed, so the old copy is litter. Failing to sweep litter is not a failed install,
            # so it is said and never raised.
            rm -rf "$OLD_BUNDLE" 2>/dev/null || sudo rm -rf "$OLD_BUNDLE" 2>/dev/null \
                || printf '\033[1mnote:\033[0m the install is complete; the previous version is still
    at %s and needs an administrator to remove:  sudo rm -rf "%s"\n' "$OLD_BUNDLE" "$OLD_BUNDLE"
        else
            # The wreck has to go before the rename or `mv` puts the old bundle *inside* it. Safe to
            # delete because it is a copy this run made and never finished; the app it was replacing
            # is the one being put back on the next line.
            if [ -e "$APPS/Meetings.app" ]; then
                rm -rf "$APPS/Meetings.app" 2>/dev/null \
                    || sudo rm -rf "$APPS/Meetings.app" 2>/dev/null || true
            fi
            # A restore that fails has to contradict what the user has already read: `die` prints its
            # "the app that was there has been put back" before exiting, and the trap runs after that
            # text is on the screen. Silence here left them believing an app they no longer have is
            # installed.
            mv "$OLD_BUNDLE" "$APPS/Meetings.app" 2>/dev/null \
                || sudo mv "$OLD_BUNDLE" "$APPS/Meetings.app" 2>/dev/null \
                || printf '\033[1;31mmeetings:\033[0m the previous version could NOT be put back, so
    disregard any message above saying it was. It is on disk and unharmed, one command away:
        sudo mv "%s" "%s"\n' "$OLD_BUNDLE" "$APPS/Meetings.app" >&2
        fi
    fi
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
    # Last, so it outlives the two undos above: another install must not be able to start while this
    # one is still putting a bundle back. Only ours is released — $LOCK is empty on the paths that
    # refused because somebody else held it, so a run that never took the lock cannot free it.
    if [ -n "$LOCK" ]; then rm -rf "$LOCK" 2>/dev/null || true; fi
    return 0
}
# EXIT only: with no handler on INT, Ctrl-C terminates the script the normal way and this runs on the
# way out.
trap cleanup EXIT

# ---------------------------------------------------------------- the toolchain (--from-source only)
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
#
# None of it runs on the default path any more. A prebuilt app needs no compiler, so there is nothing
# for a toolchain gate to protect there — and the 1.5 GB download it used to ask for is the whole
# reason the default path exists.

# The macOS SDK major of a developer directory ("26"), or nothing at all if it has none. `|| true`
# because a failing command substitution in an assignment takes the whole script down under `set -e`.
sdk_major() {
    DEVELOPER_DIR="$1" xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1 || true
}

require_toolchain() {
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
            echo "    This Mac has no Swift toolchain yet. The Command Line Tools are what building"
            echo "    from source needs — about 1.5 GB, from Apple, no Apple ID and no Xcode. macOS"
            echo "    runs its own installer; a window will appear and this will wait for it."
            echo
            echo "    Nothing here is needed to install the released build: re-run without"
            echo "    --from-source and this whole step goes away."
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

    # The toolchain is the right vintage; this asks whether it actually runs. An Xcode whose licence
    # has never been accepted fails here rather than twenty-five modules into the build.
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
}

# ---------------------------------------------------------------- --from-source
# Clones if it has to, offers the signing certificate, builds. `cd` here deliberately escapes the
# function: swift build resolves the package from the working directory, and everything after this
# point wants to be standing in the checkout too.
build_from_source() {
    require_toolchain

    # The checkout is only adopted when this script is a real file sitting next to the package. Piped
    # into bash there is no `$0` on disk, `dirname` of nothing is `.`, and the test would silently
    # adopt whatever directory the user happened to be standing in if it had a Package.swift —
    # building someone else's project.
    if [ -n "$SELF" ] && [ -f "$(dirname "$SELF")/Package.swift" ]; then
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

    # Code signing, before the build, because build-app.sh reads the identity at signing time.
    #
    # macOS keys a permission grant to the app's code signature, and an ad-hoc signature *is* a hash
    # of the app's own code. Without a stable certificate, this install and every future update look
    # like different apps and each one re-asks for the microphone and for Screen Recording. That is
    # the single worst thing about updating a build-from-source app, and it is one script to avoid.
    # (The released build has this solved outright: every release is signed with the same
    # certificate, so permissions survive every update without anyone creating anything.)
    #
    # build-app.sh offers this too, but only when it can see a terminal on stdin — which it cannot
    # when this script is piped into bash. So it is asked here, through `ask`, and build-app.sh is
    # told not to ask again.
    #
    # Through `ask` and not a hand-rolled read, which is what this was and what it got wrong. The gate
    # was `[ -r /dev/tty ]`, which is true with no controlling terminal — the exact trap the comment
    # above `ask` documents — and the read that then failed left $reply empty, which fell into the
    # default arm and ran make-signing-identity.sh --yes: the one step here that spends the user's
    # login password and adds a trusted certificate to their keychain, done on silence, in a job where
    # nobody could have answered. It also printed "/dev/tty: Device not configured" at them twice,
    # because the read had no `2>/dev/null` before its redirection. `ask` counts a failed read as a
    # no and suppresses the device error; both are the reason it exists.
    export MEETINGS_SIGN_ADHOC=1
    LOCAL_IDENTITY="Meetings Local Signing"
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$LOCAL_IDENTITY"; then
        say "Signing with the certificate you already have"
    else
        cat <<'EXPLAIN'

    macOS ties app permissions to a code signature. Signed ad hoc, every rebuild looks
    like a brand new app, so you re-grant the microphone and Screen Recording after every
    update. A self-signed certificate that stays put fixes it, for this Mac only.

    macOS will ask for your login password once, to trust it.

EXPLAIN
        if ask "Create it now?"; then
            # --yes because the explanation above already asked; the script's own confirmation would
            # be the same question twice. /dev/tty because macOS prompts for the login password.
            bash scripts/make-signing-identity.sh --yes < /dev/tty \
                || say "Certificate setup did not finish. Continuing with an ad-hoc signature."
        else
            say "Signing ad hoc. Run scripts/make-signing-identity.sh whenever you want the
    re-asking to stop."
        fi
    fi

    say "Building (first run fetches packages, so it takes a few minutes)"
    bash scripts/build-app.sh
    STAGED="$PWD/dist/Meetings.app"
}

# ---------------------------------------------------------------- the release
# Downloads the asset, proves it is the published one, and unpacks it. Nothing installed is touched
# until all of that has passed.
download_release() {
    # The asset name carries no version, which is what makes `latest/download` work: GitHub serves
    # releases/latest/download/<name> as a redirect to the newest release's asset of that exact name.
    # So there is one stable URL here, no API call, no JSON to parse and no rate limit to hit.
    #
    # That matters more than it sounds. Parsing GitHub's API answer in bash needs a JSON reader, and
    # the obvious one — /usr/bin/python3 — is a stub on a Mac with no developer tools: running it
    # pops Apple's "install the command line developer tools?" dialog, which is the exact situation
    # this whole path exists to avoid.
    if [ -n "${MEETINGS_ASSET_URL:-}" ]; then
        URL="$MEETINGS_ASSET_URL"
    elif [ -n "${MEETINGS_VERSION:-}" ]; then
        URL="$RELEASES/download/$MEETINGS_VERSION/$ASSET"
    else
        URL="$RELEASES/latest/download/$ASSET"
    fi

    # The protocol allowlist for both fetches. `=https` is exact — no http, and `--proto-redir` says
    # a redirect cannot leave https either, which matters because the release URL is a redirect by
    # design.
    #
    # file:// is allowed only when the caller named a file:// URL themselves, never as a redirect
    # target. scripts/install-check.sh serves a staged release that way so the whole install can be
    # rehearsed with no network and no published release, and that one caller is the entire reason
    # this is not a flat https-only rule.
    PROTO="--proto =https --proto-redir =https"
    case "$URL" in
        file://*) PROTO="--proto =file" ;;
    esac

    WORK="$(mktemp -d)"   # removed by the EXIT trap, on every path out of here

    if [ -n "${MEETINGS_ASSET_URL:-}" ]; then
        say "Downloading $URL"
    else
        say "Downloading ${MEETINGS_VERSION:-the latest release}"
    fi
    # Saved under the canonical asset name whatever the URL called it, so the digest check below
    # always has one name to check. --retry because a release asset is a redirect to a CDN and a
    # cold one occasionally answers 5xx on the first ask. The progress bar stays on: this is 90 MB
    # over a redirect, and silence for a minute is indistinguishable from a hang.
    #
    # $PROTO pins the scheme on both the asset and its checksum. Without it `-L` will follow a
    # redirect out of https into any protocol curl was built with, and a release asset IS a redirect
    # to a CDN — so the one hop this has to make is exactly the hop an attacker who can answer it
    # would use to downgrade to something with no certificate to check. Downloading the app over
    # plain http is not made safe by the checksum, because the checksum comes down the same wire.
    curl -fL $PROTO --retry 3 --progress-bar -o "$WORK/$ASSET" "$URL" \
        || die "Could not download $URL
    Check your network, or download the zip from $RELEASES/latest and unzip it into /Applications."

    # The digest, from the caller or from beside the asset. `<asset-url>.sha256` is published by
    # scripts/package-release.sh and is one line of `shasum -a 256` output.
    #
    # Where it came from is carried along, because both of the refusals below name it and naming the
    # wrong one sends the reader to fix a file they never used: a bad MEETINGS_ASSET_SHA256 used to
    # be reported as a bad published checksum, at a URL this run had not even fetched.
    EXPECTED="${MEETINGS_ASSET_SHA256:-}"
    DIGEST_FROM="MEETINGS_ASSET_SHA256"
    if [ -z "$EXPECTED" ]; then
        DIGEST_FROM="$URL.sha256"
        curl -fsSL $PROTO --retry 3 -o "$WORK/$ASSET.sha256" "$DIGEST_FROM" \
            || die "The download has no published checksum at $DIGEST_FROM, so there is nothing to
    check it against. Refusing to install an app this script cannot verify."
        EXPECTED="$(cut -d' ' -f1 < "$WORK/$ASSET.sha256")"
    fi
    # Shape-checked before it is used as an expectation. A 200 that is really a login page or an
    # error document passes curl -f, and a "digest" of HTML would otherwise be compared against the
    # real hash and reported as a corrupt download — the wrong diagnosis for a wrong URL.
    if [ "${#EXPECTED}" -ne 64 ] || [ -n "$(printf '%s' "$EXPECTED" | tr -d '0-9a-f')" ]; then
        die "The checksum from $DIGEST_FROM is not a SHA-256 digest:
    $EXPECTED"
    fi

    # The trust boundary, and the reason the rest of this can be relaxed about Gatekeeper: the app is
    # not notarized, so this digest and the release's own attestation are what stand where Apple's
    # check would be. It runs before anything installed is touched, so a failure here costs the user
    # a download and nothing else.
    #
    # From inside the download directory, because the names in a `shasum -c` list resolve relative to
    # the working directory.
    say "Checking it against the checksum from $DIGEST_FROM"
    ( cd "$WORK" && printf '%s  %s\n' "$EXPECTED" "$ASSET" | shasum -a 256 -c --status - ) \
        || die "The download does not match the checksum from $DIGEST_FROM.

    Expected $EXPECTED
    Got      $(shasum -a 256 "$WORK/$ASSET" | cut -d' ' -f1)

    Nothing has been installed or removed. This is either a corrupted download — try again — or
    a file that is not the release it claims to be, in which case do not install it."

    # ditto, not unzip: the archive was written by ditto and carries the symlinks and sealed resource
    # forks an .app is made of.
    ditto -x -k "$WORK/$ASSET" "$WORK/unpacked" || die "The download will not unpack."
    STAGED="$WORK/unpacked/Meetings.app"
    [ -d "$STAGED" ] || die "There is no Meetings.app inside $ASSET."

    codesign --verify --strict "$STAGED" \
        || die "The downloaded app's code signature does not verify, so the bundle has been altered
    since it was signed. Nothing has been installed. Do not run it."
}

# The signature's Designated Requirement, which is the string macOS keys permission grants to. One
# line, or nothing when the bundle is unsigned. The "designated => " line is stdout; codesign's
# "Executable=" banner is stderr, so nothing has to be filtered out of it.
#
# The leading `# ` is stripped first because an ad-hoc signature's requirement comes back commented
# out — `# designated => cdhash H"…"` — since a cdhash requirement is not one anybody could compile
# back in. Matching only the bare form read every ad-hoc bundle as unsigned, which turned the
# refusal below into the wrong sentence and made the permission note miss the one upgrade it exists
# for: a locally built ad-hoc app being replaced by the signed release.
designated_requirement() {
    codesign -d -r- "$1" 2>/dev/null | sed -n 's/^# *//; s/^designated => //p' || true
}

# ---------------------------------------------------------------- get a bundle to install
if [ "$FROM_SOURCE" = 1 ]; then
    build_from_source
else
    download_release
fi

NEW_REQ="$(designated_requirement "$STAGED")"

if [ "$FROM_SOURCE" != 1 ]; then
    # A release must be signed with the distribution certificate, and this is the one place that can
    # be checked. macOS keys TCC grants — the microphone, and Screen & System Audio Recording — to the
    # Designated Requirement, and a requirement naming a certificate is stable across releases while
    # an ad-hoc `cdhash` requirement is the hash of that one build. So a release signed ad hoc would
    # install and run, and would silently reset every permission on every future update, forever.
    # That is worth failing an install over: it cannot be noticed from the outside and it cannot be
    # fixed after the fact.
    #
    # Asked of codesign as a requirement, not scraped out of its printed one. That distinction is the
    # whole of this block, and it was learned the hard way: the previous version extracted the hash
    # with `sed -nE 's/.*certificate (leaf|root) = H"([0-9a-fA-F]*)".*/\2/'` and compared it. The
    # leading `.*` is greedy, so it captured the LAST certificate hash in the requirement — and a
    # designated requirement is not a fact about the signer, it is a string the signer chooses. An
    # attacker signs with their own certificate and sets `-r` to
    #
    #     designated => certificate leaf = H"<theirs>" or certificate leaf = H"<ours>"
    #
    # which their own signature satisfies, so `codesign --verify --strict` passes; the cdhash arm is
    # not hit because the requirement does name certificates; and the greedy regex hands the pin our
    # own fingerprint out of their app. Proven end-to-end against this installer, twice, as a file and
    # piped into bash: a bundle signed by a stranger installed with exit 0 and no warning.
    #
    # `--verify -R` evaluates the code against the requirement WE wrote, so no clause the signer adds
    # can satisfy it: an `or` only ever widens what their requirement accepts, never what ours does.
    # Both `leaf` and `root` are asked because a self-signed certificate is its own anchor and either
    # word can appear; measured that a genuine bundle satisfies both forms and the forged one neither.
    case "$NEW_REQ" in
        *cdhash*)
            die "The downloaded app is signed ad hoc, not with the distribution certificate:
    $NEW_REQ
    macOS keys permissions to that requirement, so installing this would re-ask for the
    microphone and for Screen Recording after every future update. Refusing." ;;
    esac
    codesign --verify \
        -R "=identifier \"$BUNDLE_ID\" and certificate leaf = H\"$DIST_CERT_SHA1\"" "$STAGED" \
        >/dev/null 2>&1 \
    || codesign --verify \
        -R "=identifier \"$BUNDLE_ID\" and certificate root = H\"$DIST_CERT_SHA1\"" "$STAGED" \
        >/dev/null 2>&1 \
    || die "The downloaded app is not signed by the distribution certificate.
    its requirement  ${NEW_REQ:-(unsigned)}
    expected         identifier \"$BUNDLE_ID\" signed by $DIST_CERT_SHA1
    Nothing has been installed. Either this asset did not come from the project's release
    pipeline, or the signing certificate was rotated without updating install.sh — in which case
    install it by hand from $RELEASES after checking why."

    # The checkout's copy of the same fingerprint, when there is a checkout, as a cross-check on the
    # two staying in step. A rotation has to touch both, and the failure mode of touching one is
    # silent: the release workflow signs with the file's fingerprint, so a stale literal here would
    # refuse every install of a correctly signed release, and a stale file would have CI sign with a
    # certificate this script rejects. Either way the disagreement is the bug, and it is worth saying
    # so rather than letting the pin above report it as a bad download.
    if [ -n "$SELF" ] && [ -r "$(dirname "$SELF")/Packaging/distribution-cert.sha1" ]; then
        FILED="$(tr -d '[:space:]' < "$(dirname "$SELF")/Packaging/distribution-cert.sha1" | tr 'A-F' 'a-f')"
        [ "$FILED" = "$DIST_CERT_SHA1" ] || die "This checkout disagrees with itself about the signing certificate:
    install.sh                          $DIST_CERT_SHA1
    Packaging/distribution-cert.sha1    $FILED
    The release workflow signs with the second and this script pins the first, so one of them is
    stale. Fix that before installing anything."
    fi
fi

# ---------------------------------------------------------------- is anything being recorded?
# The one thing an upgrade can destroy that no rename puts back. Replacing the bundle kills the
# running app, and the app is what is holding the microphone and the ScreenCaptureKit stream open, so
# a meeting somebody is in the middle of recording ends here, mid-sentence, with whatever audio has
# been written so far.
#
# Probed through the *installed* CLI, which reads the same store the running app writes. Only "there
# is no installed app at all" is genuinely nothing to lose. A bundle with no CLI helper inside it can
# be recording exactly as well as one with — the app holds the microphone, not the helper — so the
# helper's absence is an unanswered question and is handled as one. It used to skip the whole guard,
# prompt included, and fall through to the `pkill` below, which ends a live recording without asking.
#
# `list --state recording` is the probe, and its stdout is the whole answer: matching rows go to
# stdout and "No meetings match." goes to stderr (Out.note), so empty stdout means nothing is
# recording and there is no JSON to parse to find that out. Non-zero exit means the question was not
# answered — which is a different thing from "no" and is treated as one below.
INSTALLED_REQ=""
EXEC_PATH="$APPS/Meetings.app/Contents/MacOS/Meetings"
INSTALLED_CLI="$APPS/Meetings.app/Contents/Helpers/meetings"
if [ -d "$APPS/Meetings.app" ]; then
    # The requirement is captured now because the swap below destroys it, and the permission note at
    # the end needs to compare it against the new one.
    INSTALLED_REQ="$(designated_requirement "$APPS/Meetings.app")"
    RUNNING=0
    if pgrep -f "^$EXEC_PATH$" >/dev/null 2>&1; then RUNNING=1; fi
    # Two separate facts: whether the question was answered, and what the answer was. Collapsing them
    # into "empty output" is what made a missing helper look like a quiet no.
    RECORDING=""
    ANSWERED=0
    if [ -x "$INSTALLED_CLI" ] \
        && RECORDING="$("$INSTALLED_CLI" list --state recording 2>/dev/null)"; then
        ANSWERED=1
    fi
    if [ "$ANSWERED" = 1 ]; then
        # A `recording` row with no process behind it is an interrupted recording, not a live one:
        # RecordingRecovery closes those out the next time the app launches. Refusing on one would
        # mean an install nobody can complete without first launching the app they are replacing.
        if [ -n "$RECORDING" ] && [ "$RUNNING" = 1 ]; then
            die "Meetings is recording right now, and installing over it would end that recording:

$RECORDING

    Stop the recording in the app, then run this again."
        fi
    elif [ "$RUNNING" = 1 ]; then
        # The question was not answered — no helper to ask, an older CLI, a store it cannot open — and
        # the app is running, so this cannot tell a live meeting from an idle window. Asked with the
        # default the other way round from every other prompt here: `ask` answers yes to silence
        # because its questions are all "shall I fix this for you", and the cost of a wrong yes here
        # is somebody's meeting.
        echo
        echo "    Meetings is running and this could not check whether it is recording."
        echo "    Installing quits it, and a recording in progress would end where it is."
        echo
        printf '    Install anyway? [y/N] '
        read -r reply 2>/dev/null < /dev/tty || reply=""
        case "$reply" in
            [yY]*) : ;;
            *) die "Left alone. Quit Meetings — stop any recording first — and run this again." ;;
        esac
    fi
fi

# ---------------------------------------------------------------- install the app
# $APPS was resolved up with the platform gates and has not changed since; see the invariant there.
# The directory is created only now, so nothing above this line leaves one behind on a refusal. A
# directory the caller named and has not created yet is created for them: naming it is the whole
# instruction, and `mv` into a path that does not exist fails with an error about the wrong thing.
mkdir -p "$APPS" || die "Could not create $APPS. Point MEETINGS_APPS at somewhere writable, or leave
    it unset and the app goes to /Applications."

# The old bundle is moved aside rather than deleted, and only removed once its replacement is in
# place. `rm -rf` first meant a Ctrl-C, a full disk or a refused sudo in the seconds that followed
# left the Mac with no Meetings.app at all and a `meetings` symlink pointing into nothing — from an
# upgrade the user was told was safe to re-run. A rename is atomic and the undo is another rename.
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
    # The sudo fallbacks here are all that is left of the password prompts, and they are only
    # reachable when the directory is writable but the bundle inside it is not — a Meetings.app that
    # some earlier install left owned by root. Handed /dev/tty because under `curl | bash` stdin is
    # the script, and sudo reading a password from that would read this file's own text.
    mv "$APPS/Meetings.app" "$OLD_BUNDLE" 2>/dev/null || {
        say "$APPS/Meetings.app is owned by another user; macOS will ask for your password"
        sudo mv "$APPS/Meetings.app" "$OLD_BUNDLE" < /dev/tty \
            || die "Could not move $APPS/Meetings.app out of the way, so nothing has been changed.
    The app that is installed is still the one that was there."
    }
fi
say "Installing to $APPS"
# `mv` onto an existing directory moves INTO it. So if anything has put a Meetings.app back at the
# destination since the move-aside above — a second install racing this one through the ten seconds
# the quit-and-wait can spend, or a restore from a concurrent run's trap — this rename produces
# $APPS/Meetings.app/Meetings.app, silently, exit 0. That is the worst quiet outcome available here:
# unsealed content inside a signed bundle, so the designated requirement stops validating, and the
# permission grants this whole change exists to preserve are lost with it.
#
# Measured rather than assumed: `mv src/Meetings.app dest/Meetings.app` with the destination present
# nests and reports success. The lock below makes the race unlikely; this makes the outcome
# impossible, which is the half worth having when the failure is invisible.
[ ! -e "$APPS/Meetings.app" ] || die "Something put an app back at $APPS/Meetings.app while this
    install was running — most likely a second install at the same time. Installing now would
    nest one bundle inside the other and break the signature. Nothing has been changed; run this
    again when the other one has finished."
# A failure here is the one the restore trap exists for: it has the old bundle one rename from
# working, and `die` runs it on the way out. Said explicitly, because "exit 1" after a sudo the user
# declined reads like the app is now gone, and the whole point is that it is not.
mv "$STAGED" "$APPS/Meetings.app" 2>/dev/null || {
    say "$APPS needs an administrator; you will be asked for your password"
    sudo mv "$STAGED" "$APPS/Meetings.app" < /dev/tty \
        || die "Could not install into $APPS. The app that was there has been put back, so this Mac
    still has a working Meetings.app. MEETINGS_APPS=$HOME/Applications installs without a
    password if you would rather not give one."
}
# Nothing to commit here. The new bundle is in place, so `cleanup` now reads the destination as a
# working app and sweeps the aside copy on the way out — the same test it uses to decide to put it
# back. Doing it here instead meant this line could fail on a root-owned aside copy and abandon the
# install between the app and the CLI symlink.

# ---------------------------------------------------------------- install the CLI
# No sudo anywhere in here. /usr/local/bin is the conventional place and is writable by the admin
# user on a Mac that has ever had Homebrew — but on one that has not, it does not exist at all, and
# creating it needs root. That single directory was the last thing in this script asking for a
# password, and ~/.local/bin costs one PATH line instead.
CLI="$APPS/Meetings.app/Contents/Helpers/meetings"
if [ -n "${MEETINGS_BIN:-}" ]; then
    BIN="$MEETINGS_BIN"
    mkdir -p "$BIN"
elif [ -w /usr/local/bin ]; then
    BIN=/usr/local/bin
else
    BIN="$HOME/.local/bin"
    mkdir -p "$BIN"
fi
if ln -sfn "$CLI" "$BIN/meetings"; then
    say "Linked $BIN/meetings"
    # A tool in a directory nothing searches is a tool that is not installed, and the app's own
    # Settings pane reports `meetings` as missing when a PATH lookup cannot find it. One line, and it
    # names the file it goes in rather than saying "add it to your PATH".
    case ":$PATH:" in
        *":$BIN:"*) : ;;
        *)
            echo "    $BIN is not on your PATH. To fix that for new shells:"
            printf '      echo '\''export PATH="%s:$PATH"'\'' >> ~/.zprofile\n' "$BIN"
            ;;
    esac
else
    say "Could not write to $BIN — link it yourself with:"
    printf '      ln -sfn "%s" %s/meetings\n' "$CLI" "$BIN"
fi

# ---------------------------------------------------------------- install the agent skill
if "$CLI" skill install >/dev/null 2>&1; then
    say "Installed the agent skill"
fi

# ---------------------------------------------------------------- done
echo
say "Installed."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APPS/Meetings.app/Contents/Info.plist" 2>/dev/null || true)"
echo "    Meetings.app   $APPS/Meetings.app${VERSION:+  (version $VERSION)}"
# The link this run made, not `command -v meetings`: with an older copy still first on PATH that
# lookup answers with the other one, and reported the wrong path back to someone who had just been
# told where the new one went. An `if` rather than `test && echo`, because a failing test as the last
# command of an `&&` list is a non-zero status, and under `set -e` that ends the script one line
# before `open`.
if [ -L "$BIN/meetings" ]; then echo "    meetings       $BIN/meetings"; fi
echo
if [ -z "$INSTALLED_REQ" ]; then
    echo "    Setup will ask for the microphone and for Screen Recording — macOS files"
    echo "    audio-only capture under that name, and Meetings never records your screen."
    echo "    It then downloads about 1 GB of speech models, once."
    echo
elif [ "$INSTALLED_REQ" != "$NEW_REQ" ]; then
    # macOS keys permission grants to the Designated Requirement, so a build signed differently from
    # the one it replaced is a different app to the permission system and the grants do not carry
    # over. Said only when the requirement actually changed, because "you may be asked again" printed
    # on every update is a line people stop reading before the update it is true for.
    #
    # Which event this is turns on what was just INSTALLED, not on what the old requirement looked
    # like. On the default path the pin above has already proved the new signature is the one
    # distribution certificate, so whatever the previous copy was signed with — ad hoc, or the named
    # certificate scripts/make-signing-identity.sh creates, which the old README told people to make —
    # arriving at the release is a permission reset worth explaining rather than a substitution worth
    # warning about.
    # What it must NOT do is promise this is the last time, and the promise is what the first version
    # of this got wrong in the other direction. Neither surface can tell the two ways a previous
    # signature can differ apart: a copy signed with the user's own certificate (the migration) and a
    # copy signed with a PREVIOUS distribution certificate (a rotation) both read here as "not the
    # current pin", because the only fingerprint this script knows is the current one. So "every
    # release from here keeps the grants" was true of the migration and false of a rotation — and the
    # app, which classifies any changed identity on a downloaded copy as a rotation, was meanwhile
    # telling the same user on the same install to check where the build came from. One event, two
    # opposite explanations, which is exactly the shape this note was rewritten to remove.
    #
    # Saying only what is observable fixes it without either surface having to know more: permissions
    # reset, here is why, and here are the two innocent reasons it happens. A reader who recognises
    # neither is the one who should look further, and is not being told there is nothing to see.
    if [ "$FROM_SOURCE" != 1 ]; then
        echo "    This build is signed differently from the one it replaced, and macOS ties"
        echo "    permissions to the signature — so the microphone and Screen & System Audio"
        echo "    Recording will be asked for once more."
        echo
        echo "    That is expected if you built the previous copy yourself, or if it predates a"
        echo "    change of signing certificate. If neither is true, check where that copy came"
        echo "    from before granting anything back."
        echo
    else
        # The case that survives the rule above: the new signature is NOT the pinned certificate,
        # which after the pin's `FROM_SOURCE != 1` gate can only be a build made here. Nothing about
        # it is suspicious and the reassurance would be a lie — a local build's identity is whatever
        # this Mac signs with, so the next release install swings the permissions back again.
        #
        # The old text aimed the suspicion at the wrong bundle: on this path the *replaced* copy is
        # the verified one and the new one is the local build, and a contributor running
        # --from-source over a genuine release was told the release "was not one of the project's
        # releases".
        echo "    This build is signed with your own identity rather than the project's, and"
        echo "    macOS ties permissions to the signature — so the microphone and Screen & System"
        echo "    Audio Recording will be asked for again. That is expected for a build from"
        echo "    source, and installing a release again swings them back the same way."
        echo
        echo "        was signed by  $INSTALLED_REQ"
        echo "        now signed by  $NEW_REQ"
        echo
    fi
fi

[ "${MEETINGS_NO_OPEN:-}" = "1" ] || open "$APPS/Meetings.app"
