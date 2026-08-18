#!/usr/bin/env bash
#
# Proves the install path a user actually takes: download a prebuilt release and run it, on a Mac
# that cannot compile anything.
#
#   scripts/install-check.sh
#
# Run as the last step of scripts/verify.sh, after the bundle has been assembled.
#
# Everything happens in a staging directory served over `file://`, so this needs no network, no
# published release and no access to the project's signing key — a contributor can run it. The
# staging directory holds its own copy of install.sh, package-release.sh and
# Packaging/distribution-cert.sha1, because both scripts resolve their root from their own location:
# that is what lets the certificate pin be exercised for real against a throwaway certificate rather
# than switched off for the test.
#
# What this is defending, and why each refusal below is worth a whole check: the app is not notarized.
# Gatekeeper never inspects it, because a `curl` download carries no quarantine attribute. So the
# checksum and the signature checks in install.sh are not one layer of several — they are the only
# thing standing between a user and whatever the network handed them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STAGE=""
KEYCHAIN=""
cleanup() {
    # The keychain first: it is in the user's search list until it is deleted, and leaving one behind
    # on a developer's Mac is worse litter than a temp directory.
    if [ -n "$KEYCHAIN" ] && [ -f "$KEYCHAIN" ]; then
        security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    fi
    if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi
}
trap cleanup EXIT

die()  { echo "install-check: $*" >&2; exit 1; }
pass() { echo "    ok    $*"; }

# ---------------------------------------------------------------- a release-shaped bundle
# Rebuilt rather than reusing the bundle verify.sh already assembled, because MEETINGS_RELEASE=1 is
# half of what is being checked: it suppresses the MeetingsSourceRoot stamp, and a bundle that kept
# it hands every user `cd /Users/runner/work/... && git pull && ./install.sh`. The Swift suite covers
# the other half — what AppInfo.updateCommand returns when that key is absent. Cheap after the build
# verify.sh has already paid for; the compile is warm.
echo "==> assembling a release-shaped bundle"
MEETINGS_RELEASE=1 MEETINGS_SIGN_ADHOC=1 bash scripts/build-app.sh release >/dev/null \
    || die "scripts/build-app.sh failed"

/usr/libexec/PlistBuddy -c 'Print :MeetingsSourceRoot' dist/Meetings.app/Contents/Info.plist \
    >/dev/null 2>&1 \
    && die "a MEETINGS_RELEASE=1 build still carries MeetingsSourceRoot, so the app would tell every
                      user to cd into a directory from the build machine"
pass "MEETINGS_RELEASE=1 leaves no MeetingsSourceRoot in the bundle"

# ---------------------------------------------------------------- the staging directory
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/dist" "$STAGE/scripts" "$STAGE/Packaging" "$STAGE/apps" "$STAGE/bin"
cp -R dist/Meetings.app "$STAGE/dist/Meetings.app"
cp scripts/package-release.sh "$STAGE/scripts/"
cp install.sh "$STAGE/install.sh"

ASSET="file://$STAGE/dist/Meetings-arm64.zip"
# A PATH with no compiler on it, which is the machine this whole path exists for. `swift` and `xcrun`
# both live in /usr/bin on a Mac with the developer tools, so the PATH is rebuilt from a directory
# holding only the handful of tools install.sh legitimately needs rather than filtered.
NOSWIFT="$STAGE/nocompiler"
mkdir -p "$NOSWIFT"
for tool in curl shasum ditto codesign mktemp mkdir mv rm ln cat cut tr sed grep printf uname \
            sw_vers dirname basename pgrep pkill sleep seq open chmod cp; do
    if [ -x "/usr/bin/$tool" ]; then ln -sf "/usr/bin/$tool" "$NOSWIFT/$tool"
    elif [ -x "/bin/$tool" ]; then ln -sf "/bin/$tool" "$NOSWIFT/$tool"; fi
done
ln -sf /usr/libexec/PlistBuddy "$NOSWIFT/PlistBuddy" 2>/dev/null || true
command -v "$NOSWIFT/swift" >/dev/null 2>&1 && die "the no-compiler PATH has a swift on it"

install_run() { # install_run <extra env assignments...> ; echoes exit code, never fails the script
    set +e
    ( cd "$STAGE" && env -i \
        PATH="$NOSWIFT:/usr/bin:/bin" HOME="$STAGE/home" TMPDIR="$STAGE/tmp" \
        MEETINGS_ASSET_URL="$ASSET" MEETINGS_APPS="$STAGE/apps" MEETINGS_BIN="$STAGE/bin" \
        MEETINGS_NO_OPEN=1 "$@" \
        /bin/bash "$STAGE/install.sh" ) > "$STAGE/out" 2>&1
    echo $?
    set -e
}

mkdir -p "$STAGE/home" "$STAGE/tmp"

# ---------------------------------------------------------------- an ad-hoc release is refused
# The bundle is ad-hoc right now, which is what a build with no identity in the keychain produces.
# Installing one would work and would look completely normal — and would silently re-ask for the
# microphone and Screen Recording after every future update, because an ad-hoc requirement is the
# hash of that one build. It is the most expensive thing that can go wrong here and the least
# visible, so it is the first thing checked.
echo "==> an ad-hoc-signed release is refused"
# Re-signed ad hoc here rather than asking build-app.sh for one, because MEETINGS_SIGN_ADHOC=1 does
# not mean "sign ad hoc" — it only suppresses the offer to create a certificate. build-app.sh still
# picks up a "Meetings Local Signing" identity if the keychain has one, so on a developer's Mac this
# step was testing a certificate-signed bundle and on CI an ad-hoc one: the same check with two
# different meanings, which is worse than no check. `--sign -` is unambiguous on both.
codesign --force --sign - --timestamp=none \
    --entitlements Packaging/Meetings.entitlements "$STAGE/dist/Meetings.app" 2>/dev/null \
    || die "could not ad-hoc sign the staged bundle"
case "$(codesign -d -r- "$STAGE/dist/Meetings.app" 2>/dev/null | sed -n 's/^# *//; s/^designated => //p')" in
    *cdhash*) ;;
    *) die "the staged bundle is still not ad-hoc after --sign -, so this check would prove nothing" ;;
esac
( cd "$STAGE" && bash scripts/package-release.sh >/dev/null ) || die "packaging the ad-hoc bundle failed"
printf 'placeholder\n' > "$STAGE/Packaging/distribution-cert.sha1"
rc="$(install_run)"
[ "$rc" != 0 ] || die "install.sh accepted an ad-hoc-signed release"
grep -q "signed ad hoc" "$STAGE/out" \
    || die "install.sh refused an ad-hoc release, but not at the signature check:
$(cat "$STAGE/out")"
[ ! -e "$STAGE/apps/Meetings.app" ] || die "install.sh refused and installed anyway"
pass "ad-hoc refused, nothing installed"

# ---------------------------------------------------------------- a certificate to sign with
# Throwaway and self-signed, so this check needs nothing from the real release pipeline. Signed by
# SHA-1 rather than by name because the certificate is deliberately never trusted for code signing:
# `codesign --sign <name>` only resolves a name macOS already considers a valid identity, and adding
# trust has no non-interactive form. Signing by hash sidesteps that entirely — the same reason the
# release workflow does it.
echo "==> signing it with a throwaway certificate"
KEYCHAIN="$STAGE/check.keychain-db"
KPASS="install-check"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$STAGE/k.pem" -out "$STAGE/c.pem" -subj "/CN=Meetings Install Check" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null \
    || die "openssl could not make a certificate"
# -legacy is not optional: OpenSSL 3 writes PKCS#12 with encryption macOS cannot read, and `security
# import` then fails with "MAC verification failed (wrong password?)" — which sends you looking for a
# password problem that does not exist.
openssl pkcs12 -export -legacy -inkey "$STAGE/k.pem" -in "$STAGE/c.pem" \
    -out "$STAGE/id.p12" -passout "pass:$KPASS" -name "Meetings Install Check" 2>/dev/null \
    || die "openssl could not export a p12"

security create-keychain -p "$KPASS" "$KEYCHAIN"
security unlock-keychain -p "$KPASS" "$KEYCHAIN"
security import "$STAGE/id.p12" -k "$KEYCHAIN" -P "$KPASS" -T /usr/bin/codesign -A >/dev/null 2>&1 \
    || die "the throwaway identity would not import"
# An imported key's partition list is empty, and an empty one makes codesign ask for the keychain
# password through a GUI. On CI there is nobody to answer and it fails with errSecInternalComponent.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KPASS" "$KEYCHAIN" >/dev/null 2>&1
# -s REPLACES the search list, so the current entries are read back in: a bare -s would evict the
# login keychain and take the rest of this machine's tooling with it.
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

SHA1="$(security find-certificate -c "Meetings Install Check" -Z "$KEYCHAIN" \
    | awk '/SHA-1 hash:/{print $3}' | tr 'A-F' 'a-f')"
[ -n "$SHA1" ] || die "could not read the throwaway certificate's fingerprint"
printf '%s\n' "$SHA1" > "$STAGE/Packaging/distribution-cert.sha1"

codesign --force --sign "$SHA1" --keychain "$KEYCHAIN" --timestamp=none \
    --entitlements Packaging/Meetings.entitlements "$STAGE/dist/Meetings.app" 2>/dev/null \
    || die "could not sign the staged bundle with the throwaway certificate"
( cd "$STAGE" && bash scripts/package-release.sh >/dev/null ) || die "packaging the signed bundle failed"

# ---------------------------------------------------------------- a corrupted download is refused
echo "==> a download that does not match its checksum is refused"
cp "$STAGE/dist/Meetings-arm64.zip" "$STAGE/good.zip"
printf 'tampered' >> "$STAGE/dist/Meetings-arm64.zip"
rc="$(install_run)"
[ "$rc" != 0 ] || die "install.sh accepted a download that failed its checksum"
grep -q "does not match the checksum" "$STAGE/out" \
    || die "install.sh refused a corrupted download, but not at the checksum:
$(cat "$STAGE/out")"
[ ! -e "$STAGE/apps/Meetings.app" ] || die "install.sh refused a corrupted download and installed it"
pass "checksum mismatch refused, nothing installed"
cp "$STAGE/good.zip" "$STAGE/dist/Meetings-arm64.zip"

# ---------------------------------------------------------------- the install itself
echo "==> installing it with no compiler on PATH"
START="$(date +%s)"
rc="$(install_run)"
ELAPSED=$(( $(date +%s) - START ))
[ "$rc" = 0 ] || die "the install failed (exit $rc):
$(cat "$STAGE/out")"

APP="$STAGE/apps/Meetings.app"
[ -d "$APP" ] || die "the install reported success and there is no app at $APP"
pass "installed in ${ELAPSED}s with no swift and no xcrun on PATH"

# Sixty seconds is not a performance target, it is the difference in kind this change exists to make:
# the path this replaces took about half an hour. A check that passed at four minutes would mean
# something had quietly gone back to compiling.
[ "$ELAPSED" -lt 60 ] || die "the install took ${ELAPSED}s; it downloads a zip and should be seconds"

codesign --verify --strict "$APP" || die "the installed bundle does not pass codesign"
pass "the installed bundle's signature verifies"

# The whole design rests on this being empty. Quarantine is written by the application that downloads
# a file, and curl does not write it — which is why an unnotarized app installs here with no
# Gatekeeper dialog at all. If Apple ever changes that, this line is where it surfaces, rather than in
# a user's report that the app says it is damaged.
if xattr -r "$APP" 2>/dev/null | grep -q com.apple.quarantine; then
    die "the installed bundle carries com.apple.quarantine. Gatekeeper will now block it on a Mac
                      that did not build it, and the download path needs rethinking — this is the
                      assumption the whole install rests on."
fi
pass "nothing carries com.apple.quarantine"

REQ="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^# *//; s/^designated => //p')"
case "$REQ" in
    *cdhash*) die "the installed bundle's requirement names a cdhash: $REQ" ;;
    *"certificate leaf = H\"$SHA1\""*|*"certificate root = H\"$SHA1\""*) ;;
    *) die "the installed bundle is not keyed to the certificate it was signed with:
$REQ" ;;
esac
pass "permissions key to the certificate, not to this build ($REQ)"

[ -L "$STAGE/bin/meetings" ] || die "no meetings symlink in $STAGE/bin"
"$STAGE/bin/meetings" --help >/dev/null 2>&1 || die "the installed CLI does not run"
pass "the CLI is linked and runs"

echo "install-check OK"
