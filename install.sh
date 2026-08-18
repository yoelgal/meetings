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
# double-clicked would be refused. So the checks Apple would have done are done here instead, on the
# checksum and on the signature, and both happen before anything on disk is touched.
#
# Overrides, all optional:
#   MEETINGS_ASSET_URL=url     download this instead of the GitHub release (file:// works)
#   MEETINGS_ASSET_SHA256=hex  the expected digest, instead of fetching <asset-url>.sha256
#   MEETINGS_VERSION=v0.3.0    install this release rather than the latest
#   MEETINGS_APPS=/path        where the .app goes                (default /Applications)
#   MEETINGS_BIN=/path         where the CLI symlink goes         (default /usr/local/bin)
#   MEETINGS_SRC=/path         where --from-source clones to      (default ./meetings)
#   MEETINGS_NO_OPEN=1         install, do not launch
set -euo pipefail

APPS="${MEETINGS_APPS:-/Applications}"
REPO="https://github.com/yoelgal/meetings.git"
RELEASES="https://github.com/yoelgal/meetings/releases"
ASSET="Meetings-arm64.zip"

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
# So each half is armed by setting its variable and disarmed by clearing it, and "the old bundle is
# committed" is `OLD_BUNDLE=""` rather than uninstalling a handler the other half still needs.
WORK=""
OLD_BUNDLE=""
cleanup() {
    # Anything that went wrong between moving the old app aside and putting the new one in place
    # leaves the old one a single rename from working, so put it back rather than leaving the user
    # with neither.
    if [ -n "$OLD_BUNDLE" ] && [ -d "$OLD_BUNDLE" ] && [ ! -d "$APPS/Meetings.app" ]; then
        mv "$OLD_BUNDLE" "$APPS/Meetings.app" 2>/dev/null \
            || sudo mv "$OLD_BUNDLE" "$APPS/Meetings.app" 2>/dev/null || true
    fi
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
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
    # when this script is piped into bash. So it is asked here, from /dev/tty, and build-app.sh is
    # told not to ask again.
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
                # --yes because the explanation above already asked; the script's own confirmation
                # would be the same question twice. /dev/tty because macOS prompts for the login
                # password.
                bash scripts/make-signing-identity.sh --yes < /dev/tty \
                    || say "Certificate setup did not finish. Continuing with an ad-hoc signature."
                ;;
        esac
    else
        say "No terminal to ask on — signing ad hoc. Run scripts/make-signing-identity.sh later."
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
    curl -fL --retry 3 --progress-bar -o "$WORK/$ASSET" "$URL" \
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
        curl -fsSL --retry 3 -o "$WORK/$ASSET.sha256" "$DIGEST_FROM" \
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
    # Either `certificate leaf` or `certificate root`, and the choice is not ours. Measured on two
    # self-signed certificates whose extensions are byte-identical and whose chains are both one
    # certificate long: the one whose subject is `CN=…` alone generates `certificate leaf`, and the
    # one that also carries `O=Meetings` generates `certificate root`. A self-signed certificate is
    # its own anchor, so both forms name the same certificate and both are equally stable across
    # releases — which is the property that matters here. Matching only `leaf` rejected our own
    # release, so the word is what we do not assert on.
    case "$NEW_REQ" in
        *cdhash*)
            die "The downloaded app is signed ad hoc, not with the distribution certificate:
    $NEW_REQ
    macOS keys permissions to that requirement, so installing this would re-ask for the
    microphone and for Screen Recording after every future update. Refusing." ;;
        *'certificate leaf = H"'*|*'certificate root = H"'*) : ;;
        *)
            die "The downloaded app's signature names no certificate:
    ${NEW_REQ:-(unsigned)}
    A release is signed with the distribution certificate; this is not one. Refusing." ;;
    esac
    # -E because BSD sed has no `\|` alternation in a basic regular expression, and this has to run
    # on a stock Mac with nothing installed.
    LEAF="$(printf '%s\n' "$NEW_REQ" \
        | sed -nE 's/.*certificate (leaf|root) = H"([0-9a-fA-F]*)".*/\2/p' | tr 'A-F' 'a-f')"

    # Pinned against the certificate this repo publishes with, when that file is here to pin against.
    # It is not, under `curl | bash` — there is no checkout then, only this script — and the checks
    # above still hold in that case: what cannot be proved there is *which* certificate, only that
    # there is one.
    CERT_FILE=""
    if [ -n "$SELF" ]; then CERT_FILE="$(dirname "$SELF")/Packaging/distribution-cert.sha1"; fi
    if [ -n "$CERT_FILE" ] && [ -r "$CERT_FILE" ]; then
        WANT="$(tr -d '[:space:]' < "$CERT_FILE" | tr 'A-F' 'a-f')"
        [ "$LEAF" = "$WANT" ] || die "The downloaded app is signed by a certificate this checkout does not know:
    signed by  $LEAF
    expected   $WANT  (Packaging/distribution-cert.sha1)
    Nothing has been installed. Either the asset is not from this project's release pipeline, or
    the signing certificate changed — in which case that file is what has to change with it."
    fi
fi

# ---------------------------------------------------------------- is anything being recorded?
# The one thing an upgrade can destroy that no rename puts back. Replacing the bundle kills the
# running app, and the app is what is holding the microphone and the ScreenCaptureKit stream open, so
# a meeting somebody is in the middle of recording ends here, mid-sentence, with whatever audio has
# been written so far.
#
# Probed through the *installed* CLI, which reads the same store the running app writes. No installed
# app, or no CLI inside it, means there is nothing to lose and nothing to say.
#
# `list --state recording` is the probe, and its stdout is the whole answer: matching rows go to
# stdout and "No meetings match." goes to stderr (Out.note), so empty stdout means nothing is
# recording and there is no JSON to parse to find that out. Non-zero exit means the question was not
# answered — which is a different thing from "no" and is treated as one below.
INSTALLED_REQ=""
if [ -d "$APPS/Meetings.app" ]; then
    # Captured now because the swap below destroys it, and the permission note at the end needs to
    # compare it against the new one.
    INSTALLED_REQ="$(designated_requirement "$APPS/Meetings.app")"
fi
EXEC_PATH="$APPS/Meetings.app/Contents/MacOS/Meetings"
INSTALLED_CLI="$APPS/Meetings.app/Contents/Helpers/meetings"
if [ -x "$INSTALLED_CLI" ]; then
    RUNNING=0
    if pgrep -f "^$EXEC_PATH$" >/dev/null 2>&1; then RUNNING=1; fi
    if RECORDING="$("$INSTALLED_CLI" list --state recording 2>/dev/null)"; then
        # A `recording` row with no process behind it is an interrupted recording, not a live one:
        # RecordingRecovery closes those out the next time the app launches. Refusing on one would
        # mean an install nobody can complete without first launching the app they are replacing.
        if [ -n "$RECORDING" ] && [ "$RUNNING" = 1 ]; then
            die "Meetings is recording right now, and installing over it would end that recording:

$RECORDING

    Stop the recording in the app, then run this again."
        fi
    elif [ "$RUNNING" = 1 ]; then
        # The probe could not answer — an older CLI, a store it cannot open — and the app is running,
        # so this cannot tell a live meeting from an idle window. Asked with the default the other way
        # round from every other prompt here: `ask` answers yes to silence because its questions are
        # all "shall I fix this for you", and the cost of a wrong yes here is somebody's meeting.
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
# An unwritable /Applications used to mean a sudo prompt, and this script no longer has a reason to
# ask for a password: nothing it does needs root except writing there. ~/Applications is a real
# application directory that Spotlight, Launchpad and `open` all know, so the fallback costs the user
# nothing but a path.
#
# Only when they did not name a directory themselves. An explicit MEETINGS_APPS is an instruction,
# and installing somewhere else because that one was awkward is ignoring it.
if [ -z "${MEETINGS_APPS:-}" ] && [ ! -w "$APPS" ]; then
    APPS="$HOME/Applications"
    mkdir -p "$APPS"
    say "/Applications needs an administrator and this installer never asks for your password, so
    the app is going to $APPS instead."
fi

# A directory the caller named and has not created yet is created for them: naming it is the whole
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
# Committed. The old one goes now, and the restore half of the trap with it — clearing the variable
# rather than removing the handler, which still owns the download directory.
if [ -n "$OLD_BUNDLE" ]; then
    rm -rf "$OLD_BUNDLE" 2>/dev/null || sudo rm -rf "$OLD_BUNDLE" < /dev/tty
    OLD_BUNDLE=""
fi

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
    # The one update this happens on. macOS keys permission grants to the Designated Requirement, so
    # a build signed by a different certificate is a different app to the permission system and its
    # grants do not carry over. Said only when the requirement actually changed, because "you may be
    # asked again" printed on every update is a line people stop reading before the update it is
    # true for — which is this one, the switch from a locally built app to the signed release.
    echo "    This build is signed differently from the one it replaced, and macOS ties"
    echo "    permissions to the signature — so the microphone and Screen & System Audio"
    echo "    Recording will be asked for once more. Only this once: every release from"
    echo "    here is signed with the same certificate, so future updates keep the grants."
    echo
fi

[ "${MEETINGS_NO_OPEN:-}" = "1" ] || open "$APPS/Meetings.app"
