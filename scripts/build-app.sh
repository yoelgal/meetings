#!/usr/bin/env bash
#
# Assembles dist/Meetings.app from the SwiftPM release build.
#
#   scripts/build-app.sh              # release
#   scripts/build-app.sh debug        # faster, for iterating on the UI
#
# Idempotent: the .app is torn down and rebuilt from scratch every run. Every step is checked, so a
# missing binary or a resource that did not land fails here rather than shipping a half-app that
# traps at launch on someone else's machine.
set -euo pipefail

CONF="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"   # swift build resolves the package from the CWD, not from the script's location

APP="$ROOT/dist/Meetings.app"
CONTENTS="$APP/Contents"
# Overridable so scripts/dev.sh can build a bundle that is a genuinely separate app. The identifier
# is the key to the NSUserDefaults domain, so a dev copy sharing it also shares the window frame,
# the split positions, the panel state and every setting — a dev launch then resizes the *installed*
# app's window, which is how this override came to exist. Distinct identifier, distinct prefs.
BUNDLE_ID="${MEETINGS_BUNDLE_ID:-com.yoelgal.Meetings}"
# Must match BundleResources.bundleName — the app looks for the resources here and nowhere else.
RESOURCE_BUNDLE="Meetings_MeetingsCore.bundle"
# The certificate scripts/make-signing-identity.sh creates. Matched by name so an unrelated
# Developer ID or Apple Development identity in the keychain is never picked up by accident.
LOCAL_IDENTITY="Meetings Local Signing"

die() { echo "build-app: $*" >&2; exit 1; }

[ -f "$ROOT/Packaging/Info.plist" ] || die "Packaging/Info.plist is missing"
# Both halves of the icon. AppIcon.car is the layered macOS 26 icon and the one the system actually
# draws here; AppIcon.icns is the flat fallback. Missing either is a build error rather than a silent
# downgrade to a generic document icon in the Dock.
for icon in AppIcon.car AppIcon.icns; do
    [ -f "$ROOT/Packaging/$icon" ] \
        || die "Packaging/$icon is missing — run: swift scripts/make-icon.swift"
done

# The toolchain, checked here rather than only in install.sh, because this is the one door every
# build path goes through — install.sh, scripts/dev.sh, scripts/verify.sh, and the README's own
# `./scripts/build-app.sh`. A stranger following the README never runs install.sh at all.
#
# The requirement is the macOS SDK's version and nothing else: Package.swift targets macOS 26, and an
# older SDK cannot compile that. Not Xcode — the Command Line Tools build this app, which is why
# nothing here uses an Xcode-only macro (see FocusedValues in MarkdownEditorChrome.swift, and the
# check for it in verify.sh). Not the host's macOS version either: this cross-builds fine on an older
# Mac, and refusing one that cannot *run* the result is install.sh's job.
#
# One second here instead of half an hour: without it, a toolchain too old to build this fetched the
# whole package graph first and then failed in the compiler.
#
# `|| true`: a failing command substitution in an assignment takes the script down under `set -e`.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
case "${SDK_VERSION%%.*}" in
    ''|*[!0-9]*) die "no macOS SDK here — xcrun could not name one. Run ./install.sh, which offers
                      to install the Command Line Tools for you." ;;
    *) [ "${SDK_VERSION%%.*}" -ge 26 ] || die "the macOS SDK here is $SDK_VERSION and Package.swift
                      targets macOS 26. Update the Command Line Tools in Software Update, or Xcode
                      in the App Store. ./install.sh explains this too." ;;
esac

echo "==> swift build -c $CONF"
swift build -c "$CONF"
BIN="$(swift build -c "$CONF" --show-bin-path)"
[ -x "$BIN/MeetingsApp" ] || die "no MeetingsApp executable in $BIN"
[ -x "$BIN/meetings" ] || die "no meetings executable in $BIN"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources"

# CFBundleExecutable must equal the filename in MacOS/, and SwiftPM names the binary after the
# target. Rename on the way in rather than shipping an app called MeetingsApp.
cp "$BIN/MeetingsApp" "$CONTENTS/MacOS/Meetings"
# The CLI rides along inside the bundle; Settings symlinks it to /usr/local/bin, so there is
# exactly one copy and it updates with the app. It CANNOT sit in Contents/MacOS: this volume is
# case-insensitive, so `meetings` there silently overwrites `Meetings` and you ship an app whose
# executable is the CLI.
cp "$BIN/meetings" "$CONTENTS/Helpers/meetings"

# SwiftPM leaves resource bundles beside the binaries. They must go under Contents/Resources —
# codesign refuses to seal loose content at the bundle root, and that root is the only place
# Bundle.module knows to look, which is why BundleResources exists.
shopt -s nullglob
bundles=("$BIN"/*.bundle)
shopt -u nullglob
[ ${#bundles[@]} -gt 0 ] || die "no resource bundles in $BIN"
for b in "${bundles[@]}"; do
    cp -R "$b" "$CONTENTS/Resources/"
done

cp "$ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Packaging/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
# Assets.car is the filename CoreUI looks for, and it must sit at the root of Contents/Resources —
# Info.plist's CFBundleIconName names the icon *inside* the catalog, not the catalog itself.
cp "$ROOT/Packaging/AppIcon.car" "$CONTENTS/Resources/Assets.car"

# CFBundleIconName is what switches macOS 26 from the flat AppIcon.icns to the layered icon in
# Assets.car, and it is not optional: measured on this machine, an otherwise identical bundle
# *without* this key renders the .icns wrapped in the system's legacy compatibility plate — a
# squircle inside a squircle — and gets none of the Dark, Clear or Tinted appearances. With it, the
# layered icon draws full-bleed. (Proof: w3-icon/icon-pickup-proof.png, the same bundle built both
# ways, photographed through NSWorkspace — the call Finder and the Dock make.)
#
# It is written here rather than into Packaging/Info.plist because it is generated-icon metadata:
# `actool` emits exactly this key in its --output-partial-info-plist, and Xcode merges that partial
# at assembly time. Folding it into Packaging/Info.plist by hand would work identically — do that if
# you would rather the plist be complete at rest than assembled.
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string AppIcon' "$CONTENTS/Info.plist" >/dev/null

# The version comes from the git tag, not from Packaging/Info.plist, so it cannot drift from what
# was actually released. The in-app update check compares this string against GitHub's latest
# release: a hardcoded plist value would go stale the moment a tag was cut and quietly stop
# reporting updates, or report one forever.
#
# An untagged tree stamps 0.0.0, which reads as "older than every release". That is the honest
# answer for a build off a branch, and a visible one: the alternative is a build that silently
# believes it is current.
#
# `--match` is not optional. A bare `git describe --tags` returns the nearest tag of *any* shape, and
# this repo carries tags that are not versions: the first build after adding this stamped
# CFBundleShortVersionString as "pre-scrub-backup", which is not a version, does not parse as one,
# and silently disables the update check for that build. The pattern is checked again below, because
# a glob is not a grammar and `v1.x` matches it.
#
# `|| true` because `git describe` exits non-zero when nothing matches, and under `set -e` a failing
# command substitution in an assignment takes the whole script down. Before no repository had a
# version tag, so the very first build after this landed would have aborted mid-assembly.
VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)"
case "$VERSION" in
    [0-9]*.[0-9]*) : ;;
    *) VERSION="0.0.0" ;;
esac
# CFBundleVersion has to increase monotonically and is never shown to anyone, so the commit count is
# exactly the right shape for it. CFBundleShortVersionString is the one people read.
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$CONTENTS/Info.plist"

# What the menu bar, the Dock and the app switcher call this build. scripts/dev.sh sets it to
# `meetings-dev`, because a dev copy running beside the installed one is otherwise two identical
# "Meetings" and the only way to tell which you are looking at is which one you just broke.
#
# Written here rather than into Packaging/Info.plist so it lands *before* codesigning — PlistBuddy
# after the seal would invalidate the signature, and re-signing to rename an app is a lot of moving
# parts for a cosmetic string. CFBundleExecutable is deliberately untouched: it must equal the
# filename in Contents/MacOS, which stays Meetings.
#
APP_NAME="${MEETINGS_APP_NAME:-Meetings}"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$CONTENTS/Info.plist"

# And the identifier, for the same reason and in the same place — before the seal. TCC and
# NSUserDefaults both key on this, so overriding it costs the dev build a one-time microphone and
# screen-recording prompt and buys it a preferences domain of its own. That is the right trade:
# permissions are re-grantable in a dialog, but a dev build writing an off-screen window frame into
# the app you actually use is only discoverable by wondering why your window will not resize.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS/Info.plist"

# Where this build came from, so the app can tell you how to update it.
#
# Without this the update notice could only link to the release page, and a release page says what
# changed, not what to type. The answer is `cd <this directory> && git pull && ./install.sh`, and
# this is the only place that directory is known. Legitimate to record because the app is only ever
# built from source on the machine it runs on: there is no build server whose path this could be.
/usr/libexec/PlistBuddy -c "Add :MeetingsSourceRoot string $ROOT" "$CONTENTS/Info.plist" >/dev/null
echo "    version $VERSION (build $BUILD)"

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> checking the assembled bundle"
# The exact path BundleResources.locate() resolves to. If this is wrong the app launches and then
# traps the first time it reads SKILL.md, which is a much worse place to find out.
SKILL="$CONTENTS/Resources/$RESOURCE_BUNDLE/Resources/SKILL.md"
[ -f "$SKILL" ] || die "SKILL.md did not land at $SKILL"
# Both binaries, and genuinely different ones — see the case-insensitivity note above.
[ -x "$CONTENTS/MacOS/Meetings" ] || die "the app executable is missing"
[ -x "$CONTENTS/Helpers/meetings" ] || die "the CLI is missing"
cmp -s "$CONTENTS/MacOS/Meetings" "$CONTENTS/Helpers/meetings" \
    && die "the app executable and the CLI are the same file"
plutil -lint "$CONTENTS/Info.plist" >/dev/null || die "Info.plist is malformed"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$CONTENTS/Info.plist")" = "Meetings" ] \
    || die "CFBundleExecutable does not match Contents/MacOS/Meetings"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CONTENTS/Info.plist")" = "$BUNDLE_ID" ] \
    || die "CFBundleIdentifier is not $BUNDLE_ID"

# Identity, in order: an explicit override, the self-signed identity the user opted into with
# scripts/make-signing-identity.sh, else ad-hoc. Ad-hoc's identity IS the cdhash, so every rebuild
# looks like a different app to the permission system and microphone and screen recording are
# re-prompted; a named identity is stable and the grants survive.
SIGN_IDENTITY="${MEETINGS_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$LOCAL_IDENTITY"; then
        SIGN_IDENTITY="$LOCAL_IDENTITY"
    else
        SIGN_IDENTITY="-"
    fi
fi

# Offer the stable identity rather than only mentioning it. Re-granting the microphone and screen
# recording after every `git pull && ./scripts/build-app.sh` is the single worst thing about updating
# this app, the fix is one script, and a line of build output nobody reads is not how someone finds
# out. Asked once: after the identity exists, this branch is never reached again.
#
# Only when someone is actually watching. A prompt in CI, in verify.sh or in an agent's build hangs
# forever waiting for a keystroke that is not coming, so a non-TTY stdin keeps the old behaviour, and
# MEETINGS_SIGN_ADHOC=1 forces it for anyone who wants ad-hoc on purpose.
if [ "$SIGN_IDENTITY" = "-" ] && [ -t 0 ] && [ "${MEETINGS_SIGN_ADHOC:-0}" != "1" ]; then
    echo
    echo "This build will be signed ad hoc, which means its identity is a hash of its own code."
    echo "macOS treats every rebuild as a different app, so you will re-grant the microphone and"
    echo "screen recording permissions after this build, and after every future update."
    echo
    echo "scripts/make-signing-identity.sh creates a self-signed certificate that stays the same"
    echo "across builds, so the grants stick. It explains itself before touching your keychain, and"
    echo "macOS will ask for your login password once."
    echo
    printf "Set that up now? [y/N] "
    read -r reply
    case "$reply" in
        [yY]*)
            "$ROOT/scripts/make-signing-identity.sh"
            # Re-read rather than assume: the script can be declined at its own confirmation, and
            # signing with an identity that was never created would fail the build for the person
            # who just changed their mind.
            if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$LOCAL_IDENTITY"; then
                SIGN_IDENTITY="$LOCAL_IDENTITY"
            fi
            ;;
    esac
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "==> codesigning (ad-hoc — macOS will re-ask for microphone and screen recording after"
    echo "    every rebuild; run scripts/make-signing-identity.sh once to stop that)"
else
    echo "==> codesigning ($SIGN_IDENTITY)"
fi
# No --deep: it is deprecated and signs inside-out. There is no nested code here, so one top-level
# sign seals everything. --options runtime is deliberately off until there is a real Developer ID —
# a local signature gains nothing from hardening and the runtime blocks debugging you may want.
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    --entitlements "$ROOT/Packaging/Meetings.entitlements" "$APP"
codesign --verify --deep --strict "$APP" || die "codesign verification failed"

echo "OK: $APP"
