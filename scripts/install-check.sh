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
# published release and no access to the project's signing key — a contributor can run it. The staging
# directory holds its own copy of install.sh and package-release.sh, because both resolve their root
# from their own location.
#
# The certificate pin is exercised for real, in both directions, and the staged install.sh is edited
# to make that possible: install.sh pins the distribution certificate as a literal fingerprint
# (DIST_CERT_SHA1) precisely so the pin runs under `curl | bash`, where there is no checkout to read a
# file from. So the staged copy's literal is rewritten to the throwaway certificate this script mints,
# one case then presents a different valid fingerprint and must be refused, and a third makes the
# literal and Packaging/distribution-cert.sha1 disagree and must be refused too. The rewrite is
# asserted, because a silent no-op there would leave the real fingerprint in place and turn the whole
# section into a test of nothing.
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
# both live in /usr/bin, so the PATH is rebuilt from a directory holding only the tools install.sh
# legitimately needs rather than filtered — and it is the WHOLE PATH. It used to end
# `:/usr/bin:/bin`, which put back the directory the sentence above says the compiler lives in: the
# rehearsal had a working `swift` and `xcrun` on it, and the line claiming otherwise was false.
#
# The list is what install.sh actually reaches for, established by running it under exactly this PATH
# and fixing what it could not find. /usr/libexec/PlistBuddy is called by absolute path and needs no
# entry; `security` and `git` are from-source-only and deliberately absent, so a default-path install
# that quietly grew a dependency on either fails here.
NOSWIFT="$STAGE/nocompiler"
mkdir -p "$NOSWIFT"
for tool in curl shasum ditto codesign mktemp mkdir mv rm ln cat cut tr sed grep printf uname \
            sw_vers dirname basename pgrep pkill sleep seq open chmod cp; do
    if [ -x "/usr/bin/$tool" ]; then ln -sf "/usr/bin/$tool" "$NOSWIFT/$tool"
    elif [ -x "/bin/$tool" ]; then ln -sf "/bin/$tool" "$NOSWIFT/$tool"; fi
done
# Asked the way a shell asks, under the PATH the install will actually run with, because that is the
# only question that means anything. The old form tested `command -v "$NOSWIFT/swift"` — a literal
# path the loop above never creates, so it could not be true for any input and asserted nothing.
# /bin/bash is absolute so bash itself does not have to be on the PATH being tested.
if env -i PATH="$NOSWIFT" /bin/bash -c 'command -v swift || command -v xcrun' >/dev/null 2>&1; then
    die "the no-compiler PATH can still find swift or xcrun, so the check below proves nothing:
$(env -i PATH="$NOSWIFT" /bin/bash -c 'command -v swift; command -v xcrun')"
fi

install_run() { # install_run <extra env assignments...> ; echoes exit code, never fails the script
    set +e
    # MEETINGS_HOME rather than only HOME: it is what Paths.root reads, so the recording probe and
    # `skill install` land in the staging directory even if the app's Application Support default ever
    # changes. A run that touched the developer's real store would be a check with a side effect.
    ( cd "$STAGE" && env -i \
        PATH="$NOSWIFT" HOME="$STAGE/home" TMPDIR="$STAGE/tmp" MEETINGS_HOME="$STAGE/store" \
        MEETINGS_ASSET_URL="$ASSET" MEETINGS_APPS="$STAGE/apps" MEETINGS_BIN="$STAGE/bin" \
        MEETINGS_NO_OPEN=1 "$@" \
        /bin/bash "$STAGE/install.sh" ) > "$STAGE/out" 2>&1
    echo $?
    set -e
}

mkdir -p "$STAGE/home" "$STAGE/tmp" "$STAGE/store"

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
# No Packaging/distribution-cert.sha1 in the stage yet, and none is needed: install.sh pins its
# literal, and this bundle is refused at the ad-hoc arm before any fingerprint is compared. A
# placeholder used to be written here, which read as though it were the thing being tested.
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
security create-keychain -p "$KPASS" "$KEYCHAIN"
security unlock-keychain -p "$KPASS" "$KEYCHAIN"
# -s REPLACES the search list, so the current entries are read back in: a bare -s would evict the
# login keychain and take the rest of this machine's tooling with it.
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

# Two identities come out of here, not one: the release is signed with the first, and the second is
# what the upgrade case installs over so that "the copy being replaced was signed by a *different*
# certificate" is a real state rather than an approximation of one.
mint_identity() { # mint_identity <common name> — prints the new certificate's SHA-1, lower case
    local cn="$1"
    local tag
    tag="$(printf '%s' "$cn" | tr -cd 'A-Za-z0-9')"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -keyout "$STAGE/$tag.key" -out "$STAGE/$tag.crt" -subj "/CN=$cn" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null \
        || die "openssl could not make a certificate for $cn"
    # Two forms, and the fallback is the one that runs on a stock Mac. OpenSSL 3 writes PKCS#12 with
    # encryption macOS cannot read, and `security import` then fails with "MAC verification failed
    # (wrong password?)" — which sends you looking for a password problem that does not exist;
    # `-legacy` is what stops it. But /usr/bin/openssl on macOS is LibreSSL, which has no `-legacy`
    # flag at all: it answers with its usage block, writes no p12, and this step died on any Mac
    # without Homebrew's OpenSSL shadowing the system one. LibreSSL's defaults are already the
    # readable ones, so dropping the flag is exactly right there and wrong on OpenSSL 3 — hence try,
    # then fall back.
    p12_export() {
        openssl pkcs12 -export "$@" -inkey "$STAGE/$tag.key" -in "$STAGE/$tag.crt" \
            -out "$STAGE/$tag.p12" -passout "pass:$KPASS" -name "$cn" 2>/dev/null
    }
    p12_export -legacy || p12_export || die "openssl could not export a p12 with or without -legacy.
                      openssl version: $(openssl version 2>&1 | sed -n 1p)"
    [ -s "$STAGE/$tag.p12" ] || die "openssl reported success and wrote no p12 for $cn"

    # -T /usr/bin/codesign plus the partition list below is the pair that lets codesign use this key
    # without a GUI prompt. No -A: that widens the ACL to every application on the machine, which
    # this needs from nothing.
    security import "$STAGE/$tag.p12" -k "$KEYCHAIN" -P "$KPASS" -T /usr/bin/codesign >/dev/null 2>&1 \
        || die "the throwaway identity $cn would not import"
    # An imported key's partition list is empty, and an empty one makes codesign ask for the keychain
    # password through a GUI. On CI there is nobody to answer and it fails with
    # errSecInternalComponent.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KPASS" "$KEYCHAIN" \
        >/dev/null 2>&1

    local sha
    sha="$(security find-certificate -c "$cn" -Z "$KEYCHAIN" \
        | awk '/SHA-1 hash:/{print $3}' | tr 'A-F' 'a-f')"
    [ -n "$sha" ] || die "could not read $cn's fingerprint"
    printf '%s\n' "$sha"
}

SHA1="$(mint_identity "Meetings Install Check")"
OTHER_SHA1="$(mint_identity "Meetings Install Check Other")"
[ "$SHA1" != "$OTHER_SHA1" ] || die "the two throwaway certificates came out identical"

# The staged install.sh is pinned to this throwaway certificate instead of the real one, and the
# staged Packaging file is written to agree with it. Both, because install.sh cross-checks them
# against each other and a disagreement is itself a refusal — which is what the third case below
# exercises on purpose.
pin_stage() { # pin_stage <40-hex> — rewrites the staged install.sh's pinned fingerprint
    sed "s/^DIST_CERT_SHA1=.*/DIST_CERT_SHA1=\"$1\"/" "$ROOT/install.sh" > "$STAGE/install.sh"
    # Asserted every time, because the rewrite is the whole basis of this section: rename the constant
    # in install.sh and this sed becomes a silent no-op, leaving the real fingerprint in place. Every
    # case after that would refuse the throwaway certificate, which reads as install.sh being broken
    # rather than as this script having stopped testing anything.
    grep -q "^DIST_CERT_SHA1=\"$1\"\$" "$STAGE/install.sh" \
        || die "could not rewrite DIST_CERT_SHA1 in the staged install.sh — has the constant been
                      renamed? Nothing below this line would be testing the certificate pin."
}
printf '%s\n' "$SHA1" > "$STAGE/Packaging/distribution-cert.sha1"
pin_stage "$SHA1"

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

# ---------------------------------------------------------------- a wrong certificate is refused
# The pin's whole job, and the actor it exists for: someone who can write a release asset but cannot
# reach the signing key — a leaked `contents: write` token, a compromised account. They can sign a
# bundle with a certificate they minted themselves and publish it with a matching checksum, and every
# check before this one passes. The fingerprint is the only thing that says no.
#
# Presented as a *valid-shaped* fingerprint rather than a malformed one, because a 40-hex value that
# simply is not ours is the shape of the real attack.
#
# Both sides are moved together so that only the pin can be what refuses: leave
# Packaging/distribution-cert.sha1 on the throwaway fingerprint and the cross-check below refuses the
# disagreement instead, which is a different check passing for a different reason and would let the
# pin be deleted without this case noticing.
WRONG="0123456789abcdef0123456789abcdef01234567"
echo "==> a release signed by a certificate that is not the pinned one is refused"
pin_stage "$WRONG"
printf '%s\n' "$WRONG" > "$STAGE/Packaging/distribution-cert.sha1"
rc="$(install_run)"
[ "$rc" != 0 ] || die "install.sh installed a release signed by a certificate it does not pin"
grep -q "not signed by the distribution certificate" "$STAGE/out" \
    || die "install.sh refused, but not at the certificate pin:
$(cat "$STAGE/out")"
[ ! -e "$STAGE/apps/Meetings.app" ] || die "install.sh refused a wrong certificate and installed anyway"
pass "a certificate that is not the pinned one is refused, nothing installed"

# ---------------------------------------------------------------- a forged designated requirement
# The attack that got through, and the reason the pin no longer parses codesign's output at all.
#
# A designated requirement is not a fact about the signer. It is a string the signer chooses, and
# `codesign -r` sets it. So an attacker signs with their own certificate and names OURS as an
# alternative in their own requirement:
#
#     designated => certificate leaf = H"<theirs>" or certificate leaf = H"<ours>"
#
# Their signature satisfies that (the left branch is true of it), so `codesign --verify --strict`
# passes. The requirement names certificates, so the ad-hoc arm is not hit. And the previous pin
# extracted the hash with a greedy `.*certificate (leaf|root) = H"([0-9a-f]*)"`, which captured the
# LAST one — ours — out of their app. It installed with exit 0 and no warning.
#
# The fix was to stop reading their string and start asking codesign whether the code satisfies
# OURS (`--verify -R`), which no clause they add can widen. This case is what keeps it that way: it
# is the only assertion here that fails if anyone reintroduces string parsing.
echo "==> a bundle whose own requirement names our fingerprint after an 'or' is refused"
FORGER_SHA1="$(mint_identity "Meetings Install Check Forger")"
[ "$FORGER_SHA1" != "$SHA1" ] || die "the forger certificate came out identical to the pinned one"
printf 'designated => certificate leaf = H"%s" or certificate leaf = H"%s"\n' "$FORGER_SHA1" "$SHA1" \
    > "$STAGE/forged.rq"
codesign --force --sign "$FORGER_SHA1" --keychain "$KEYCHAIN" --timestamp=none \
    -r "$STAGE/forged.rq" --entitlements "$ROOT/Packaging/Meetings.entitlements" \
    "$STAGE/dist/Meetings.app" 2>/dev/null \
    || die "could not sign the staged bundle with the forger certificate and a forged requirement"
# Proof the forgery is a real one before it is used as evidence, because a case built on a bundle
# codesign already rejects would pass for the wrong reason forever. Two properties: their requirement
# must actually name our fingerprint, and the bundle must actually verify.
codesign -d -r- "$STAGE/dist/Meetings.app" 2>/dev/null | grep -q "$SHA1" \
    || die "the forged requirement does not name the pinned fingerprint, so this case proves nothing"
codesign --verify --strict "$STAGE/dist/Meetings.app" >/dev/null 2>&1 \
    || die "the forged bundle does not pass codesign --verify, so this case proves nothing"
( cd "$STAGE" && bash scripts/package-release.sh >/dev/null ) || die "packaging the forged bundle failed"
pin_stage "$SHA1"
printf '%s\n' "$SHA1" > "$STAGE/Packaging/distribution-cert.sha1"
rc="$(install_run)"
[ "$rc" != 0 ] || die "install.sh ACCEPTED a bundle signed by a stranger whose own requirement named
                      our fingerprint. That is the forged-requirement hole, reopened."
grep -q "not signed by the distribution certificate" "$STAGE/out" \
    || die "install.sh refused the forgery, but not at the certificate check:
$(cat "$STAGE/out")"
[ ! -e "$STAGE/apps/Meetings.app" ] || die "install.sh refused the forgery and installed it anyway"
pass "a forged requirement naming our fingerprint is refused, nothing installed"
# Back to a genuinely signed bundle for everything below.
codesign --force --sign "$SHA1" --keychain "$KEYCHAIN" --timestamp=none \
    --entitlements "$ROOT/Packaging/Meetings.entitlements" "$STAGE/dist/Meetings.app" 2>/dev/null \
    || die "could not re-sign the staged bundle after the forgery case"
( cd "$STAGE" && bash scripts/package-release.sh >/dev/null ) || die "repackaging after the forgery case failed"

# ---------------------------------------------------------------- install.sh and the repo disagreeing
# The cross-check the pin is paired with. Rotating the certificate means editing two places, and the
# failure mode of editing one is silent in the worst direction: the release workflow signs with
# Packaging/distribution-cert.sha1 while install.sh pins its own literal, so a half-done rotation
# either refuses every genuine release or has CI sign with a certificate the installer rejects. Both
# read as a mysterious bad download unless something says "these two disagree".
# The pin itself passes here — the literal is the certificate the bundle really is signed with — so
# the only thing that can refuse is the two fingerprints not matching each other.
echo "==> install.sh and Packaging/distribution-cert.sha1 disagreeing is refused"
pin_stage "$SHA1"
printf '%s\n' "$WRONG" > "$STAGE/Packaging/distribution-cert.sha1"
rc="$(install_run)"
[ "$rc" != 0 ] || die "install.sh installed with its pin and the repo's fingerprint disagreeing"
grep -q "disagrees with itself about the signing certificate" "$STAGE/out" \
    || die "install.sh refused, but not at the cross-check:
$(cat "$STAGE/out")"
[ ! -e "$STAGE/apps/Meetings.app" ] || die "install.sh refused a disagreement and installed anyway"
pass "a stale fingerprint on either side is refused, nothing installed"
printf '%s\n' "$SHA1" > "$STAGE/Packaging/distribution-cert.sha1"

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
# `status` rather than `--help`: ArgumentParser answers --help before any of the app's own code runs,
# so a binary that cannot open a store passes it. `status` opens the store and reports it, which is
# the thing a linked CLI has to be able to do. MEETINGS_HOME keeps it inside the staging directory —
# without it this line would create a store in the developer's Application Support.
MEETINGS_HOME="$STAGE/store" "$STAGE/bin/meetings" status >/dev/null 2>&1 \
    || die "the installed CLI cannot open a store:
$(MEETINGS_HOME="$STAGE/store" "$STAGE/bin/meetings" status 2>&1)"
pass "the CLI is linked and answers 'meetings status'"

# ---------------------------------------------------------------- upgrading over an existing install
# Contract criterion 5, and until this existed nothing in the check reached any of it: the move-aside,
# the restore trap, the quit-and-wait, the two sudo fallbacks and the re-grant notice were all
# downstream of an `$APPS` that was empty on every run that got as far as installing.
#
# The pre-existing copy is planted rather than installed, and planted ad-hoc signed on purpose. That
# is the real migration this release performs — every existing user is running a locally built,
# ad-hoc-signed app — and it cannot be produced by running install.sh, which now refuses ad-hoc
# releases. The marker file is the store: an upgrade that lost somebody's meetings while replacing the
# app would be the worst thing this script could fail to notice.
echo "==> upgrading over an existing install"
rm -rf "$STAGE/apps/Meetings.app"
cp -R "$ROOT/dist/Meetings.app" "$STAGE/apps/Meetings.app"
codesign --force --sign - --timestamp=none \
    --entitlements Packaging/Meetings.entitlements "$STAGE/apps/Meetings.app" 2>/dev/null \
    || die "could not plant an ad-hoc-signed copy to upgrade over"
OLD_REQ="$(codesign -d -r- "$STAGE/apps/Meetings.app" 2>/dev/null | sed -n 's/^# *//; s/^designated => //p')"
case "$OLD_REQ" in
    *cdhash*) ;;
    *) die "the planted copy is not ad-hoc, so the migration case would not be one: $OLD_REQ" ;;
esac
mkdir -p "$STAGE/store"
printf 'do not lose me\n' > "$STAGE/store/marker"

rc="$(install_run)"
[ "$rc" = 0 ] || die "upgrading over an existing install failed (exit $rc):
$(cat "$STAGE/out")"
REQ="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^# *//; s/^designated => //p')"
case "$REQ" in
    *"H\"$SHA1\""*) ;;
    *) die "the old bundle is still there after an upgrade: $REQ" ;;
esac
pass "the existing bundle was replaced, not left in place"

# The aside copy is named Meetings.app.replaced-<pid> and is meant to be swept on the way out. One
# left behind is a silent 90 MB per upgrade, and the name is one nobody would recognise as theirs.
leftovers="$(ls -d "$STAGE/apps/"Meetings.app.replaced-* 2>/dev/null || true)"
[ -z "$leftovers" ] || die "the upgrade left the previous bundle behind:
$leftovers"
pass "no Meetings.app.replaced-* left behind"

[ -L "$STAGE/bin/meetings" ] || die "the upgrade left no meetings symlink"
MEETINGS_HOME="$STAGE/store" "$STAGE/bin/meetings" status >/dev/null 2>&1 \
    || die "the CLI does not resolve after an upgrade"
[ "$(cat "$STAGE/store/marker")" = "do not lose me" ] \
    || die "the upgrade did not leave the store alone"
pass "the CLI still resolves and the store is untouched"

# The one-time permission note. It is the only warning a user gets that macOS is about to ask for the
# microphone again, and it has to appear exactly on the install where the signature changes — with the
# migration's wording, because the copy being replaced was ad-hoc signed. Both halves are asserted:
# the sentence, and the reassurance that is only true of the migration.
grep -q "signed differently from the one it replaced" "$STAGE/out" \
    || die "upgrading from an ad-hoc copy printed no permission note:
$(cat "$STAGE/out")"
grep -q "Only this once" "$STAGE/out" \
    || die "the migration note lost the sentence that says it will not happen again:
$(cat "$STAGE/out")"
pass "the migration is announced once, as the migration"

rc="$(install_run)"
[ "$rc" = 0 ] || die "re-running the install over its own output failed (exit $rc):
$(cat "$STAGE/out")"
# Matched on the phrase both arms of that branch share rather than on the migration's own sentence.
# Grepping the migration wording let a mutation that printed the *rotation* note on every upgrade pass
# this check: the assertion is "no permission note at all", so it has to be blind to which one.
# "Screen & System Audio" appears in both notes and in neither the fresh-install text nor anything
# else install.sh prints.
grep -q "Screen & System Audio" "$STAGE/out" \
    && die "a same-certificate upgrade printed a permission note, which is the one thing that
                      teaches users to ignore them:
$(cat "$STAGE/out")"
leftovers="$(ls -d "$STAGE/apps/"Meetings.app.replaced-* 2>/dev/null || true)"
[ -z "$leftovers" ] || die "the second upgrade left the previous bundle behind:
$leftovers"
pass "a same-signature upgrade is silent about permissions and leaves nothing behind"

# ---------------------------------------------------------------- replacing a differently-signed copy
# The other arm of the same branch, and the reason it exists. Once the migration release has shipped,
# every user's installed copy is signed by a certificate — so "the requirement changed" stops meaning
# "you built the old one yourself". A copy signed by somebody else's certificate is either a build the
# user made with their own signing identity, or a build that was substituted for a release, and macOS
# re-asking for the microphone is the only outward sign either happened. The migration's reassurance —
# "Only this once: every release from here is signed with the same certificate" — is false in that
# case and explains away the one signal there is, which is why the two arms say different things.
#
# Signed with the second throwaway certificate, so the previous requirement genuinely names a
# different certificate rather than a cdhash. install.sh cannot refuse this and should not: the copy
# it replaces is what is unproven, the swap has already happened by the time it is reported, and the
# signer of what was just installed is pinned. Reporting both requirements is the whole job.
echo "==> replacing a copy signed by a different certificate"
rm -rf "$STAGE/apps/Meetings.app"
cp -R "$ROOT/dist/Meetings.app" "$STAGE/apps/Meetings.app"
codesign --force --sign "$OTHER_SHA1" --keychain "$KEYCHAIN" --timestamp=none \
    --entitlements Packaging/Meetings.entitlements "$STAGE/apps/Meetings.app" 2>/dev/null \
    || die "could not plant a copy signed with the second throwaway certificate"
OLD_REQ="$(codesign -d -r- "$STAGE/apps/Meetings.app" 2>/dev/null | sed -n 's/^# *//; s/^designated => //p')"
case "$OLD_REQ" in
    *cdhash*) die "the planted copy is ad-hoc, so this would test the migration arm again: $OLD_REQ" ;;
    *"H\"$OTHER_SHA1\""*) ;;
    *) die "the planted copy is not signed by the second certificate: $OLD_REQ" ;;
esac

rc="$(install_run)"
[ "$rc" = 0 ] || die "installing over a differently-signed copy failed (exit $rc):
$(cat "$STAGE/out")"
grep -q "was signed by a different certificate" "$STAGE/out" \
    || die "replacing a differently-signed copy said nothing about the signature change:
$(cat "$STAGE/out")"
grep -q "Only this once" "$STAGE/out" \
    && die "a substituted or self-signed previous copy was explained away as the one-time migration,
                      which is the sentence that makes a signer substitution invisible"
# Both requirements, so the user can see which certificate they had and which they now have. Without
# them the message names a problem and gives nothing to act on.
grep -q "was signed by  .*$OTHER_SHA1" "$STAGE/out" \
    || die "the note does not report the previous requirement:
$(cat "$STAGE/out")"
grep -q "now signed by  .*$SHA1" "$STAGE/out" \
    || die "the note does not report the new requirement:
$(cat "$STAGE/out")"
pass "a differently-signed previous copy is reported, not reassured about"

echo "install-check OK"
