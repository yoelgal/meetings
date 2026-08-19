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
SEARCH_LIST=""
SLEEPER=""
cleanup() {
    # The keychain first: it is in the user's search list until it is deleted, and leaving one behind
    # on a developer's Mac is worse litter than a temp directory.
    if [ -n "$KEYCHAIN" ] && [ -f "$KEYCHAIN" ]; then
        security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    fi
    # And the search list put back to what it was, because deleting a keychain is not the same as
    # undoing the `security list-keychains -s` that added it. That command REPLACES the list, so the
    # only way back is to have written the old one down. A run that was killed rather than allowed to
    # exit skipped this entirely and left an entry pointing at a deleted temp file in the operator's
    # real user search list — round 2 found one from its own killed run, and they accumulate silently.
    # `-s` with the saved words rather than the raw string: each entry is a separate argument.
    if [ -n "$SEARCH_LIST" ]; then
        security list-keychains -d user -s $SEARCH_LIST 2>/dev/null || true
    fi
    # Any process this check started to stand in for a running app. It is a `cat` waiting on a pipe,
    # so it would otherwise sit there until its `sleep` ran out.
    if [ -n "$SLEEPER" ]; then
        pkill -f "^$SLEEPER$" 2>/dev/null || true
    fi
    # Writable before removable: the fallback cases deliberately chmod a staging directory to 500 to
    # make it unwritable, and `rm -rf` cannot delete a directory's contents through that. On a failing
    # run the trap fired before those cases restored the mode, so a real failure came with three
    # "Permission denied" lines that looked like part of the defect. Restoring the mode first is the
    # difference between a clear failure and a confusing one.
    if [ -n "$STAGE" ]; then
        chmod -R u+w "$STAGE" 2>/dev/null || true
        rm -rf "$STAGE"
    fi
}
trap cleanup EXIT

# What a killed run could not clean up, swept on the way in: entries naming a keychain this check
# created and then took with it. Matched on the fixed name it always uses, under a temp directory, so
# nothing else can look like one. Done before the list is captured below, or the stale entry would be
# saved and faithfully restored.
stale="$(security list-keychains -d user | tr -d '"' | grep -c 'check\.keychain-db' || true)"
if [ "${stale:-0}" -gt 0 ]; then
    echo "note: dropping $stale stale install-check keychain(s) from the user search list" >&2
    security list-keychains -d user -s \
        $(security list-keychains -d user | tr -d '"' | grep -v 'check\.keychain-db' || true)
fi

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

install_run_piped() { # same, but as `cat install.sh | bash`, which is the shape the README documents
    set +e
    # The difference that matters: with the script on stdin there is no $0 on disk, so install.sh's
    # $SELF is empty and everything it can only do from a checkout is switched off. That is the shape
    # every real user takes and the shape the certificate pin was once accidentally excluded from, so
    # at least one case has to run this way rather than handing bash a path.
    ( cd "$STAGE" && cat "$STAGE/install.sh" | env -i \
        PATH="$NOSWIFT" HOME="$STAGE/home" TMPDIR="$STAGE/tmp" MEETINGS_HOME="$STAGE/store" \
        MEETINGS_ASSET_URL="$ASSET" MEETINGS_APPS="$STAGE/apps" MEETINGS_BIN="$STAGE/bin" \
        MEETINGS_NO_OPEN=1 "$@" \
        /bin/bash ) > "$STAGE/out" 2>&1
    echo $?
    set -e
}

install_run_flag() { # install_run_flag <install.sh flag> [env assignments...]
    # A separate runner because install_run's arguments are env assignments handed to `env`, so a flag
    # passed there becomes a command name and the run dies with "env: --from-source: No such file or
    # directory" rather than exercising anything.
    flag="$1"
    shift
    set +e
    ( cd "$STAGE" && env -i \
        PATH="$NOSWIFT" HOME="$STAGE/home" TMPDIR="$STAGE/tmp" MEETINGS_HOME="$STAGE/store" \
        MEETINGS_ASSET_URL="$ASSET" MEETINGS_APPS="$STAGE/apps" MEETINGS_BIN="$STAGE/bin" \
        MEETINGS_NO_OPEN=1 "$@" \
        /bin/bash "$STAGE/install.sh" "$flag" ) > "$STAGE/out" 2>&1
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
# login keychain and take the rest of this machine's tooling with it. Written down first, because
# putting the list back is the only way to undo this and `security delete-keychain` does not do it.
SEARCH_LIST="$(security list-keychains -d user | tr -d '"')"
security list-keychains -d user -s "$KEYCHAIN" $SEARCH_LIST

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

# ---------------------------------------------------------------- a broken signature is refused
# The checksum and the signature are not the same check, and this is the input that tells them apart:
# a zip whose digest is exactly what it claims and whose bundle does not verify. That is not a
# contrived shape — it is the `ditto`-vs-`zip` damage package-release.sh exists to avoid, an archiver
# that flattens a symlink or drops a resource fork, and it arrives with a perfectly good checksum
# because the checksum is taken of the damaged archive.
#
# Until this existed the `codesign --verify --strict` line in install.sh could be replaced with `true`
# and every case still passed: every staged bundle was validly signed, and the one corrupted download
# failed at the checksum before the signature was ever looked at.
echo "==> a download whose checksum matches but whose signature does not is refused"
BROKEN="$STAGE/broken"
mkdir -p "$BROKEN"
ditto -x -k "$STAGE/good.zip" "$BROKEN/unpacked" || die "could not unpack the good zip to damage it"
# One byte onto a sealed file inside the bundle. `codesign --verify --strict` reports it as
# "In subcomponent: .../Contents/Helpers/meetings" — measured — so the seal genuinely covers this.
printf 'x' >> "$BROKEN/unpacked/Meetings.app/Contents/Helpers/meetings"
( cd "$BROKEN/unpacked" && ditto -c -k --sequesterRsrc --keepParent Meetings.app \
    "$STAGE/dist/Meetings-arm64.zip" ) || die "could not repack the damaged bundle"
# Re-hashed, so the checksum step passes and the signature step is the only thing left to refuse.
# Handed in through MEETINGS_ASSET_SHA256 rather than rewritten beside the asset, because that also
# rehearses the override a user pinning a digest by hand would use.
BROKEN_SHA="$(shasum -a 256 "$STAGE/dist/Meetings-arm64.zip" | cut -d' ' -f1)"
rc="$(install_run MEETINGS_ASSET_SHA256="$BROKEN_SHA")"
[ "$rc" != 0 ] || die "install.sh installed a bundle whose signature does not verify"
grep -q "code signature does not verify" "$STAGE/out" \
    || die "install.sh refused a damaged bundle, but not at the signature:
$(cat "$STAGE/out")"
[ ! -e "$STAGE/apps/Meetings.app" ] || die "install.sh refused a damaged bundle and installed it"
pass "a matching checksum over a broken signature is refused, nothing installed"
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

# ---------------------------------------------------------------- the shape the README documents
# Everything above hands bash a path, so install.sh's $SELF is a real file on every one of them. The
# command every user actually runs does not: `curl … | bash` puts the script on stdin, $0 is `bash`,
# and $SELF is empty. That difference is not cosmetic — it is exactly where the certificate pin used
# to be switched off, because the pin was gated on a checkout being present, and no case here would
# have noticed. One case runs the real shape, with the wrong certificate, and asserts the pin still
# refuses.
echo "==> piped into bash, a wrong certificate is still refused"
pin_stage "$WRONG"
printf '%s\n' "$WRONG" > "$STAGE/Packaging/distribution-cert.sha1"
rc="$(install_run_piped)"
[ "$rc" != 0 ] || die "piped into bash, install.sh installed a release it does not pin. That is the
                      curl | bash path, which is every real install."
grep -q "not signed by the distribution certificate" "$STAGE/out" \
    || die "piped into bash, install.sh refused but not at the certificate pin:
$(cat "$STAGE/out")"
[ ! -e "$STAGE/apps/Meetings.app" ] || die "piped into bash, install.sh refused and installed anyway"
pass "the pin holds when the script arrives on stdin"
pin_stage "$SHA1"
printf '%s\n' "$SHA1" > "$STAGE/Packaging/distribution-cert.sha1"

# ---------------------------------------------------------------- http is not a download scheme
# The scheme pin, and it needs no network: curl refuses a disabled protocol before it opens a socket.
# `-L` without `--proto-redir '=https'` follows a redirect into any protocol curl was built with, and
# the release URL IS a redirect to a CDN — so the one hop this really makes is exactly the hop that
# could be answered with a downgrade. A checksum is no defence there, because the checksum comes down
# the same wire.
echo "==> an http asset URL is refused before anything is fetched"
rc="$(install_run MEETINGS_ASSET_URL="http://example.invalid/Meetings-arm64.zip")"
[ "$rc" != 0 ] || die "install.sh downloaded over http"
# curl's own words for a protocol it was told not to use, and nothing weaker: "could not download" also
# matches a DNS failure, so accepting that would let the scheme pin be deleted and still pass — the
# host in the URL does not exist either.
grep -qi 'protocol "\{0,1\}http"\{0,1\} disabled' "$STAGE/out" \
    || die "install.sh refused an http URL, but not because the scheme is disabled:
$(cat "$STAGE/out")"
[ ! -e "$STAGE/apps/Meetings.app" ] || die "an http URL installed something anyway"
pass "http is refused by the scheme pin, with no network involved"

# ---------------------------------------------------------------- one fetch over https
# Every case above is served over `file://`, which keeps this runnable with no network and no
# published release — and leaves the entire https half unexercised: the releases/latest/download URL,
# MEETINGS_VERSION, the sibling .sha256 fetch, and `--proto '=https' --proto-redir '=https'`, which
# could be deleted without a single assertion noticing. A release asset is a redirect to a CDN, so the
# scheme pinning is guarding the one hop this really makes.
#
# A refusal is enough and needs no published release: a tag that does not exist makes curl fail, and
# what has to be true is that the run ends without installing anything. Skipped with a printed reason
# when GitHub is unreachable, so a contributor offline still gets a green gate while CI gets the
# coverage — a check that cannot run is worth saying out loud, and worth more than one that quietly
# passes.
if curl -fsS --proto '=https' --max-time 10 -o /dev/null \
    https://github.com/yoelgal/meetings/releases 2>/dev/null; then
    echo "==> a fetch over https, with a tag that does not exist"
    rc="$(install_run MEETINGS_ASSET_URL="" MEETINGS_VERSION=v0.0.0-install-check)"
    [ "$rc" != 0 ] || die "install.sh reported success for a release tag that does not exist"
    grep -q "Could not download https://github.com/yoelgal/meetings/releases/download/v0.0.0-install-check/Meetings-arm64.zip" \
        "$STAGE/out" \
        || die "the https URL install.sh built is not the release-download URL:
$(cat "$STAGE/out")"
    [ ! -e "$STAGE/apps/Meetings.app" ] || die "a failed https download installed something anyway"
    pass "https is reachable, the release URL is built correctly, and a missing tag installs nothing"
else
    echo "    skip  github.com is unreachable, so the one https case did not run"
fi

# ---------------------------------------------------------------- the one line nothing here defends
# `--proto-redir '=https'` has no case, and this says so out loud rather than leaving the gap to be
# rediscovered. The case above proves `--proto '=https'` bites, because curl refuses a typed http URL
# before it opens a socket. The redirect half cannot be proved the same way: the downgrade it guards
# against arrives as a `Location:` header on an **https** response, so rehearsing it needs a local
# origin curl will complete a TLS handshake with — a trusted certificate, not a self-signed one, since
# passing `--insecure` would change the very invocation under test. `nc` can serve the 302 but not the
# TLS, and `openssl s_server` only gets as far as a certificate curl rejects.
#
# So it stays undefended, deliberately and visibly. What holds the line meanwhile is that both flags
# are set together on both fetches, and the `--proto` half has a case that fails without it — someone
# deleting the pair breaks that case, and someone deleting only `--proto-redir` does not. If this ever
# needs closing properly, the shape is a local origin with a certificate in the system trust store.
echo "    gap   --proto-redir '=https' has no case: proving it needs a local https origin curl trusts"

# ---------------------------------------------------------------- two installs at once
# Held by somebody else, so this run must stop rather than race. The lock is a directory holding the
# holder's pid, and a pid with no process behind it is stale and reclaimed — so the live case needs a
# process that really exists. `$$` is this script, which is alive by definition and outlives the run.
echo "==> a second install refuses while another holds the lock"
# Under $HOME rather than TMPDIR, which is where install.sh moved it: /tmp is world-writable and
# sticky, so a lock pre-seeded there by any local process could neither be trusted nor reclaimed.
HELD="$STAGE/home/Library/Caches/com.yoelgal.Meetings/install.lock"
mkdir -p "$HELD"
printf '%s\n' "$$" > "$HELD/pid"
rc="$(install_run)"
[ "$rc" != 0 ] || die "install.sh installed while another install held the lock"
grep -q "Another Meetings install is running" "$STAGE/out" \
    || die "install.sh refused while the lock was held, but not because of the lock:
$(cat "$STAGE/out")"
[ ! -e "$STAGE/apps/Meetings.app" ] || die "a locked-out install installed something anyway"
pass "a held lock refuses the second install, nothing installed"
# And a lock whose holder is gone must not wedge every future install. Four pid files, because
# `kill -0` answers yes to more than "this process exists": 0 and -1 both mean "signal a process
# group", and 1 is launchd, which is always alive and is never this installer. Each of these used to
# make the lock permanent — never stale, so never reclaimed, so every later install died on a
# directory nobody would think to look for. An empty file and a non-numeric one are the killed-run
# and corrupted cases.
for held_pid in 999999 0 -1 1 "" "not-a-pid"; do
    printf '%s\n' "$held_pid" > "$HELD/pid"
    rc="$(install_run)"
    [ "$rc" = 0 ] || die "a lock holding pid '$held_pid' blocked the install instead of being
                      reclaimed as stale:
$(cat "$STAGE/out")"
    rm -rf "$STAGE/apps/Meetings.app" 2>/dev/null || true
    mkdir -p "$HELD"
done
pass "a lock with no believable live holder is reclaimed, not permanent"
rm -rf "$STAGE/apps/Meetings.app" "$HELD" 2>/dev/null || true

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

# And the CLI can reach its resource bundles — which is a structural claim on purpose, because no
# behavioural test on this machine can make it.
#
# `Bundle.module` is SwiftPM-generated: it looks beside the running binary, then at the absolute
# .build path of whatever machine compiled the binary. The app reaches resources through
# BundleResources, so Contents/Resources suffices for it; the CLI at Contents/Helpers looked in
# Contents/Helpers, found nothing, and fell through to the build path. That path EXISTS on the machine
# that built it and is /Users/runner/work/... on everybody else's — so every published release shipped
# a CLI that fatally errored on any command needing bundled resources, while every local run passed.
# Measured against the published v0.4.0-rc1: `meetings skill install` exited 133 with
# "Fatal error: could not load resource bundle".
#
# That is why this is a file check and not a command. Running the command here proves nothing: this
# machine, and the CI runner, both satisfy the fallback the defect relies on. Only a machine that did
# not compile the binary can tell the difference, and neither of the machines that run this check
# qualifies. So the invariant is asserted directly — every resource bundle beside the app's binary is
# also reachable beside the CLI — and it fails the moment the link that provides it goes missing.
for rb in "$APP/Contents/Resources"/*.bundle; do
    [ -e "$rb" ] || continue
    sibling="$APP/Contents/Helpers/$(basename "$rb")"
    [ -d "$sibling" ] || die "the CLI cannot reach $(basename "$rb"): there is nothing at
                      Contents/Helpers/$(basename "$rb"), so Bundle.module falls through to the build
                      machine's own path — which resolves here and on CI, and does not exist on any
                      Mac that did not compile this binary. That is the shipped-broken-CLI defect."
done
pass "every resource bundle the app has is reachable from the CLI beside it"

# The behavioural half, kept even though it cannot fail here for the reason above: it costs nothing and
# it is the assertion that would catch a regression in the step itself rather than in the layout.
grep -q "Trace/BPT trap" "$STAGE/out" \
    && die "something in the install was killed or trapped on its first execution:
$(cat "$STAGE/out")"
grep -q "Installed the agent skill" "$STAGE/out" \
    || die "'meetings skill install' did not report success, so the agent skill was not installed.
                      The install tolerates that failure silently, which is why it is asserted here:
$(cat "$STAGE/out")"
pass "the agent skill installs, and nothing trapped on a first execution"

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
# The two innocent reasons, which is what the note now offers instead of promising this is the last
# time. It cannot promise that: a previous copy signed with the user's own certificate and one signed
# with an EARLIER distribution certificate both read as "not the current pin" here, and only the second
# is a rotation. Asserting the reasons rather than the promise is asserting what the installer can know.
grep -q "expected if you built the previous copy yourself" "$STAGE/out" \
    || die "the permission note lost the sentence that explains why the reset is expected:
$(cat "$STAGE/out")"
pass "the migration is announced once, as the migration"

# ---------------------------------------------------------------- the banner, and who it is for
# The up-front explanation somebody compiling their own copy gets: the mechanism changed, this
# replaces what they built, their meetings survive, permissions are asked once. It fires on
# MeetingsSourceRoot in the OLD bundle — the key build-app.sh writes only for a build assembled from a
# checkout on this Mac — which is what keeps it off a certificate rotation, where the copy being
# replaced is a release and carries no such key.
#
# Both directions, because a banner that shows for everyone is noise and a banner that shows for
# nobody is nothing. The negative case is the same install with the key absent.
echo "==> a compiled-here copy is told the mechanism changed, before anything is downloaded"
rm -rf "$STAGE/apps/Meetings.app"
cp -R "$ROOT/dist/Meetings.app" "$STAGE/apps/Meetings.app"
/usr/libexec/PlistBuddy -c "Add :MeetingsSourceRoot string /Users/someone/meetings" \
    "$STAGE/apps/Meetings.app/Contents/Info.plist" >/dev/null 2>&1 \
    || die "could not stamp MeetingsSourceRoot on the planted copy, so this case proves nothing"
rc="$(install_run)"
[ "$rc" = 0 ] || die "the install failed for a copy compiled here:
$(cat "$STAGE/out")"
grep -q "Meetings updates differently from now on" "$STAGE/out" \
    || die "somebody who compiled their own copy was not told the mechanism changed:
$(cat "$STAGE/out")"
grep -q "kept exactly as they are" "$STAGE/out" \
    || die "the banner did not say their meetings survive, which is the question it exists to answer:
$(cat "$STAGE/out")"
# Before the download, not after: an explanation that arrives once the app has already been replaced
# is a report, not a warning. The banner's first line must precede the first download line.
# `Downloading` unanchored: say() wraps its prefix in ANSI bold, so the line does not begin with the
# literal `==>` and an anchored match silently never fires — which made this assertion fail for a
# reason that had nothing to do with ordering.
awk '/Meetings updates differently from now on/{b=NR} /Downloading/{d=NR} END{exit !(b && d && b < d)}' \
    "$STAGE/out" \
    || die "the banner printed after the download started, so it explains a change already underway:
$(cat "$STAGE/out")"
pass "a compiled-here copy is told what changes, before anything is fetched"

echo "==> and a downloaded copy is not told it compiled anything"
rm -rf "$STAGE/apps/Meetings.app"
cp -R "$ROOT/dist/Meetings.app" "$STAGE/apps/Meetings.app"
rc="$(install_run)"
[ "$rc" = 0 ] || die "the install failed replacing a downloaded copy:
$(cat "$STAGE/out")"
grep -q "Meetings updates differently from now on" "$STAGE/out" \
    && die "a copy that was never compiled here was told it was, which is the banner firing on a
                      certificate rotation:
$(cat "$STAGE/out")"
pass "the banner stays off for a copy that was downloaded, not built"
rm -rf "$STAGE/apps/Meetings.app"

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
# The case that used to be classified as a substitution and is in fact the commonest migration there
# is. Anyone who followed the old README ran scripts/make-signing-identity.sh, so their installed copy
# is signed by a real named certificate rather than ad hoc — and installing the release over it is the
# same one-time event as installing over an ad-hoc build.
#
# Which is why install.sh classifies by what was just INSTALLED and not by the shape of the previous
# requirement: the pin has already proved the new signature is the one distribution certificate, so
# every later release keeps the grants. Deciding by the previous
# requirement told exactly those users their app might have been substituted, while the app itself
# showed them the routine migration notice on the same install — one event explained two contradictory
# ways, and the terminal's version was the wrong one.
#
# Signed with the second throwaway certificate, so the previous requirement genuinely names a
# different certificate rather than a cdhash.
echo "==> replacing a copy signed by a different certificate"
rm -rf "$STAGE/apps/Meetings.app"
cp -R "$ROOT/dist/Meetings.app" "$STAGE/apps/Meetings.app"
codesign --force --sign "$OTHER_SHA1" --keychain "$KEYCHAIN" --timestamp=none \
    --entitlements Packaging/Meetings.entitlements "$STAGE/apps/Meetings.app" 2>/dev/null \
    || die "could not plant a copy signed with the second throwaway certificate"
OLD_REQ="$(codesign -d -r- "$STAGE/apps/Meetings.app" 2>/dev/null | sed -n 's/^# *//; s/^designated => //p')"
case "$OLD_REQ" in
    *cdhash*) die "the planted copy is ad-hoc, so this would test the same input as the case above: $OLD_REQ" ;;
    *"H\"$OTHER_SHA1\""*) ;;
    *) die "the planted copy is not signed by the second certificate: $OLD_REQ" ;;
esac

rc="$(install_run)"
[ "$rc" = 0 ] || die "installing over a differently-signed copy failed (exit $rc):
$(cat "$STAGE/out")"
grep -q "signed differently from the one it replaced" "$STAGE/out" \
    || die "replacing a differently-signed copy said nothing about the signature change:
$(cat "$STAGE/out")"
grep -q "expected if you built the previous copy yourself" "$STAGE/out" \
    || die "a release install over a differently-signed copy did not explain the reset the way the
                      migration does, so the installer and the app say different things about one install:
$(cat "$STAGE/out")"
# The sentence that used to be printed here, and must not be again: it told users who had followed the
# old README's advice to wonder where their own app came from.
grep -q "was not one of the project's releases" "$STAGE/out" \
    && die "a release install over a self-signed copy still accuses it of not being a release:
$(cat "$STAGE/out")"
pass "a release over any differently-signed copy is the migration, and says so once"

# ---------------------------------------------------------------- --from-source over a release
# The other half of that branch, and the only path where the newly installed signature is NOT the
# pinned certificate. A contributor building from source over a release must be told the truth about
# it — their own identity, permissions asked again, expected — and must not be told the release they
# just replaced was suspicious, which is what the old wording did to the one bundle here that is
# actually verified.
#
# The build is stubbed. What is under test is install.sh's from-source branch, not build-app.sh, and a
# real build in here would double the run time to re-prove something verify.sh has already proved. The
# stub signs ad hoc, which is what a build with no identity in the keychain produces — and `security`
# is deliberately not on the farm PATH, so install.sh finds no local identity and reaches the offer.
#
# That offer is the other thing this case pins down. It runs make-signing-identity.sh — the one step
# in this file that spends the user's login password and adds a trusted certificate — and it used to
# run it on a FAILED read from /dev/tty, because `[ -r /dev/tty ]` is true with no controlling
# terminal and an empty $reply fell into the yes arm. There is no terminal here, so the marker below
# must not exist afterwards.
echo "==> --from-source over a release explains itself and asks for nothing"
touch "$STAGE/Package.swift"
cat > "$STAGE/scripts/make-signing-identity.sh" <<'STUB'
#!/bin/bash
# Stands in for the real thing, which would take a password. Leaves evidence instead.
printf 'ran\n' > "$(dirname "$0")/../make-signing-identity.ran"
STUB
cat > "$STAGE/scripts/build-app.sh" <<'STUB'
#!/bin/bash
# Stands in for the real build: the staged release bundle, re-signed ad hoc, which is what a build
# from source with no identity in the keychain produces.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/Meetings.app"
ditto "$ROOT/apps/Meetings.app" "$ROOT/dist/Meetings.app"
codesign --force --sign - --timestamp=none "$ROOT/dist/Meetings.app" 2>/dev/null
STUB
chmod +x "$STAGE/scripts/make-signing-identity.sh" "$STAGE/scripts/build-app.sh"
# The installed copy is the genuine release from the case above, so this is a from-source build landing
# on top of a verified one — the exact situation the old text got backwards.
#
# This is the one case that runs WITH the compiler on PATH, because building from source is the one
# path that legitimately needs one: install.sh's toolchain gate asks xcode-select, xcrun and swift for
# the SDK version and refuses without them. The no-compiler PATH is a claim about the default path
# only.
#
# And `security` is stubbed to find nothing, which is the state the signing offer exists for: a Mac
# that has not made a local certificate yet. Without the stub this machine's own "Meetings Local
# Signing" identity is found, the offer never appears, and the assertions below about what it does
# with no terminal would pass while testing nothing.
SEC_SHIM="$STAGE/nosecurity"
mkdir -p "$SEC_SHIM"
printf '#!/bin/bash\nexit 1\n' > "$SEC_SHIM/security"
chmod +x "$SEC_SHIM/security"
rc="$(install_run_flag --from-source PATH="$SEC_SHIM:$NOSWIFT:/usr/bin:/bin")"
[ "$rc" = 0 ] || die "--from-source over a release failed (exit $rc):
$(cat "$STAGE/out")"
[ ! -e "$STAGE/make-signing-identity.ran" ] \
    || die "the signing offer ran make-signing-identity.sh with no terminal to answer it. That is the
                      one step here that spends the user's login password, answered on silence."
grep -q "no terminal to ask on" "$STAGE/out" \
    || die "the signing offer did not report that it had nobody to ask:
$(cat "$STAGE/out")"
grep -q "signed with your own identity rather than the project's" "$STAGE/out" \
    || die "--from-source did not explain its own signature:
$(cat "$STAGE/out")"
grep -q "was not one of the project's releases" "$STAGE/out" \
    && die "--from-source accused the genuine release it replaced of not being one:
$(cat "$STAGE/out")"
grep -q "expected if you built the previous copy yourself" "$STAGE/out" \
    && die "--from-source used the release path's explanation, which does not apply to a local build:
$(cat "$STAGE/out")"
pass "--from-source names its own certificate, accuses nothing, and asks for no password"
rm -f "$STAGE/Package.swift" "$STAGE/scripts/build-app.sh" "$STAGE/scripts/make-signing-identity.sh"

# ---------------------------------------------------------------- a running app is not replaced blindly
# The recording guard and the quit-and-wait, neither of which had a failing input: no case here ever
# had a process running, so `elif [ "$RUNNING" = 1 ]` could be `elif false` and `pkill` could be `:`
# and this file still printed OK. What they protect is the worst thing an upgrade can do — end a
# meeting somebody is recording, mid-sentence, and take the store's open handles with it.
#
# The stand-in process is a three-line binary compiled here, blocking in `pause()`, copied to the
# bundle's Contents/MacOS/Meetings so its argv[0] is exactly the path install.sh anchors its
# `pgrep -f "^…$"` on. It costs no CPU and it is not the app: launching the real Meetings.app in a
# check would open windows and ask for the microphone.
#
# Compiled rather than symlinked to a system tool that already blocks, which is what this was first.
# A symlink to /bin/cat made the planted directory an APPLE-SIGNED bundle: `codesign -dv` on it
# answers `Identifier=com.apple.cat`, and macOS then SIGKILLs anything else executed inside that
# bundle — including the stub CLI helper these cases probe through (measured, Killed: 9, while
# `/bin/bash <the same script>` ran it fine). A copy of a system binary is no good either: macOS kills
# a copied platform binary even re-signed ad hoc (measured, exit 137). A binary of our own leaves the
# bundle unsigned, which is what a hand-planted bundle should look like.
printf '#include <unistd.h>\nint main(void){for(;;)pause();return 0;}\n' > "$STAGE/sleeper.c"
clang -o "$STAGE/sleeper" "$STAGE/sleeper.c" 2>/dev/null \
    || die "clang could not build the stand-in process for the running-app cases"

plant_running_app() { # plant_running_app <apps dir> [helper script] — a fresh bundle, live process
    RUN_APPS="$1"
    helper="${2:-}"
    rm -rf "$RUN_APPS"
    mkdir -p "$RUN_APPS/Meetings.app/Contents/MacOS" "$RUN_APPS/Meetings.app/Contents/Helpers"
    # The CLI helper goes in BEFORE the executable, and that order is not a preference. The moment
    # Contents/MacOS/Meetings is a real Mach-O the directory IS an app bundle, and macOS's App
    # Management protection refuses writes inside one: creating the helper afterwards fails with
    # "Operation not permitted" (measured) even in a temp directory this script owns.
    if [ -n "$helper" ]; then
        cp "$helper" "$RUN_APPS/Meetings.app/Contents/Helpers/meetings"
        chmod +x "$RUN_APPS/Meetings.app/Contents/Helpers/meetings"
    fi
    cp "$STAGE/sleeper" "$RUN_APPS/Meetings.app/Contents/MacOS/Meetings"
    SLEEPER="$RUN_APPS/Meetings.app/Contents/MacOS/Meetings"
    # Started in a subshell so bash never reports it as a job: killing it otherwise prints
    # "Terminated: 15" into the middle of this script's output. Every descriptor goes to /dev/null —
    # its stderr is otherwise this script's stderr, and anything reading our output through a pipe
    # then blocks on the process instead of seeing the run finish.
    ( "$SLEEPER" >/dev/null 2>&1 </dev/null & )
    # Waited for rather than assumed: a case that silently had no process would pass every assertion
    # below for the wrong reason.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if pgrep -f "^$SLEEPER$" >/dev/null 2>&1; then return 0; fi
        sleep 0.2
    done
    die "could not start a stand-in process at $SLEEPER, so the running-app cases prove nothing"
}

# Each arm plants at its own directory rather than reusing one. A path that has held a validly signed
# bundle is not a clean slate for a hand-made one — and the arms would otherwise interfere anyway,
# since the third one installs for real over what the first two left.
echo "==> a recording in progress refuses the install"
# A stub helper, because what is under test is install.sh's reaction to the probe's answer. The real
# CLI's answer is a separate fact, asserted by the `meetings status` cases above.
printf '#!/bin/bash\necho "m-abc  today  12:04  recording  -  Board review"\n' \
    > "$STAGE/helper-recording.sh"
plant_running_app "$STAGE/running-recording" "$STAGE/helper-recording.sh"
rc="$(install_run MEETINGS_APPS="$RUN_APPS")"
[ "$rc" != 0 ] || die "install.sh replaced the app while a meeting was being recorded"
grep -q "recording right now" "$STAGE/out" \
    || die "install.sh refused, but not because of the recording:
$(cat "$STAGE/out")"
grep -q "Board review" "$STAGE/out" \
    || die "the refusal does not name what would have been lost:
$(cat "$STAGE/out")"
pgrep -f "^$SLEEPER$" >/dev/null 2>&1 \
    || die "install.sh refused and killed the running app anyway, which is the loss it refused to cause"
pkill -f "^$SLEEPER$" 2>/dev/null || true
pass "a live recording refuses the install and the running app is left alone"

echo "==> a running app the probe cannot ask about refuses with no terminal"
# No helper at all: the question cannot be asked, which is not the same as an answer of no. Gating the
# whole guard on the helper's presence — which it was — sent this case straight into the `pkill` with
# no prompt at all.
plant_running_app "$STAGE/running-unanswerable"
rc="$(install_run MEETINGS_APPS="$RUN_APPS")"
[ "$rc" != 0 ] || die "install.sh replaced a running app it could not ask about, without asking"
grep -q "could not check whether it is recording" "$STAGE/out" \
    || die "install.sh refused, but not at the unanswered-probe prompt:
$(cat "$STAGE/out")"
pgrep -f "^$SLEEPER$" >/dev/null 2>&1 || die "install.sh refused and killed the running app anyway"
pkill -f "^$SLEEPER$" 2>/dev/null || true
pass "an unanswerable probe with no terminal is a refusal, not a yes"

echo "==> a running app that is not recording is waited for, not raced"
# The quit-and-wait. `pkill` mutated to `:` left every case green; here the process must be gone by the
# time the install finishes, and the install must succeed.
printf '#!/bin/bash\nexit 0\n' > "$STAGE/helper-idle.sh"
plant_running_app "$STAGE/running-idle" "$STAGE/helper-idle.sh"
rc="$(install_run MEETINGS_APPS="$RUN_APPS")"
[ "$rc" = 0 ] || die "install.sh could not replace a running app that was not recording (exit $rc):
$(cat "$STAGE/out")"
grep -q "Waiting for the running app to finish and quit" "$STAGE/out" \
    || die "install.sh replaced a running app without waiting for it:
$(cat "$STAGE/out")"
pgrep -f "^$SLEEPER$" >/dev/null 2>&1 \
    && die "install.sh reported success with the old process still running, which is how a stale
                      process writes over a migration the new build has already recorded as done"
[ -d "$RUN_APPS/Meetings.app/Contents/Resources" ] \
    || die "the planted bundle was not actually replaced by the real one"
SLEEPER=""
pass "a running app is quit and waited for before the swap"

# ---------------------------------------------------------------- a bundle is never nested in a bundle
# The guard behind the lock, and the reason it exists even though the lock makes the race unlikely:
# `mv src/Meetings.app dest/Meetings.app` with the destination present moves INTO it, silently and
# with exit 0, producing dest/Meetings.app/Meetings.app. That is unsealed content inside a signed
# bundle, so the designated requirement stops validating and the permission grants this whole change
# exists to preserve go with it — and nothing says a word.
#
# Staged by shimming the move-aside so it copies instead of moving: the destination is still occupied
# when the commit rename happens, which is exactly the state a second install racing this one through
# the quit-and-wait would leave. Reusing the shim mechanism the failed-swap case below already proves.
echo "==> an occupied destination is refused, not nested into"
NEST="$STAGE/nestshim"
mkdir -p "$NEST"
cat > "$NEST/mv" <<'STUB'
#!/bin/bash
# The move-aside becomes a copy, so the destination stays occupied. Everything else is a real mv.
case "${2:-}" in
    */Meetings.app.replaced-*) exec /bin/cp -R "$1" "$2" ;;
esac
exec /bin/mv "$@"
STUB
chmod +x "$NEST/mv"
rm -rf "$STAGE/apps/Meetings.app"
cp -R "$ROOT/dist/Meetings.app" "$STAGE/apps/Meetings.app"
codesign --force --sign "$SHA1" --keychain "$KEYCHAIN" --timestamp=none \
    --entitlements Packaging/Meetings.entitlements "$STAGE/apps/Meetings.app" 2>/dev/null \
    || die "could not plant the copy the nesting guard is supposed to protect"
rc="$(install_run PATH="$NEST:$NOSWIFT")"
[ "$rc" != 0 ] || die "install.sh installed into an occupied destination"
[ ! -e "$STAGE/apps/Meetings.app/Meetings.app" ] \
    || die "install.sh nested a bundle inside the installed one, which breaks its signature silently"
codesign --verify --strict "$STAGE/apps/Meetings.app" >/dev/null 2>&1 \
    || die "the installed bundle no longer verifies after the refusal, so something was written into it"
pass "an occupied destination refuses rather than nesting one bundle inside another"
rm -rf "$STAGE/apps/"Meetings.app.replaced-* 2>/dev/null || true

# ---------------------------------------------------------------- the undo, when the swap fails
# The restore path had no failing input either: every refusal above happens BEFORE the move-aside, so
# the trap's restore could be deleted outright and this file still printed OK. It is the one thing
# standing between a failed upgrade and a Mac with no Meetings.app at all.
#
# The failure is injected where it can really happen — between the two renames — by shadowing `mv` for
# exactly the commit call. The `sudo` fallback then fails too (no terminal), which is the "refused
# password" case the code names, and the trap has to put the old bundle back.
echo "==> a failed swap puts the previous version back"
SHIM="$STAGE/shim"
mkdir -p "$SHIM"
cat > "$SHIM/mv" <<'STUB'
#!/bin/bash
# Fails only the commit rename of the freshly unpacked bundle. The move-aside and the restore both go
# through, so what is under test is the undo and not `mv` in general.
case "${1:-}" in
    */unpacked/Meetings.app) echo "mv: injected failure" >&2; exit 1 ;;
esac
exec /bin/mv "$@"
STUB
chmod +x "$SHIM/mv"
# A known-good installed copy to lose: the genuine release, planted directly.
rm -rf "$STAGE/apps/Meetings.app"
cp -R "$ROOT/dist/Meetings.app" "$STAGE/apps/Meetings.app"
codesign --force --sign "$SHA1" --keychain "$KEYCHAIN" --timestamp=none \
    --entitlements Packaging/Meetings.entitlements "$STAGE/apps/Meetings.app" 2>/dev/null \
    || die "could not plant the copy the failed swap is supposed to give back"
rc="$(install_run PATH="$SHIM:$NOSWIFT")"
[ "$rc" != 0 ] || die "install.sh reported success after the commit rename failed"
[ -d "$STAGE/apps/Meetings.app" ] \
    || die "the swap failed and the previous version was NOT put back: this Mac now has no
                      Meetings.app, from a command the README calls safe to re-run"
codesign --verify --strict "$STAGE/apps/Meetings.app" >/dev/null 2>&1 \
    || die "the previous version was put back damaged, so the restore is not a restore"
leftovers="$(ls -d "$STAGE/apps/"Meetings.app.replaced-* 2>/dev/null || true)"
[ -z "$leftovers" ] || die "the restore left the aside copy behind as well:
$leftovers"
grep -q "has been put back" "$STAGE/out" \
    || die "the failure did not tell the user their app is still there:
$(cat "$STAGE/out")"
pass "a failed swap restores the previous version, intact, and says so"

# ---------------------------------------------------------------- the ~/Applications fallback
# The only path a non-admin account can take, and until this existed nothing here went near it: the
# fallback fires when MEETINGS_APPS is unset AND /Applications is unwritable, so covering it looks like
# it would mean installing into the real /Applications.
#
# It does not. The staged install.sh is already rewritten for the certificate pin, so the same
# mechanism moves its hardcoded default to a directory made unwritable on purpose. With MEETINGS_APPS
# unset the resolution then falls back to $HOME/Applications, and $HOME is inside the staging
# directory — which is a real rehearsal of the path, not a claim about the source text.
#
# What the defect did: $EXEC_PATH, $INSTALLED_CLI and $INSTALLED_REQ were all built from the
# pre-fallback $APPS, so the recording guard probed a bundle nobody was replacing, `pkill` matched a
# path nothing was running from, and $INSTALLED_REQ stayed empty — a live app kept running through
# "Installed." and an upgrade printed the fresh-install text. Both arms below are those two outcomes.
NOAPPS="$STAGE/unwritable-applications"
mkdir -p "$NOAPPS"
chmod 500 "$NOAPPS"
[ ! -w "$NOAPPS" ] || die "$NOAPPS is still writable, so the fallback would never fire and both arms
                      below would be testing the ordinary path"
pin_stage "$SHA1"
# The one substitution: the default only, leaving MEETINGS_APPS's precedence exactly as shipped.
sed -i '' "s|^APPS=\"\${MEETINGS_APPS:-/Applications}\"\$|APPS=\"\${MEETINGS_APPS:-$NOAPPS}\"|" \
    "$STAGE/install.sh"
grep -q "^APPS=\"\${MEETINGS_APPS:-$NOAPPS}\"\$" "$STAGE/install.sh" \
    || die "could not point the staged install.sh's default app directory at $NOAPPS — has that line
                      changed shape? Neither arm below would be exercising the fallback."

echo "==> the fallback location's running app is seen, not sailed past"
printf '#!/bin/bash\necho "m-xyz  today  09:00  recording  -  Investor call"\n' > "$STAGE/helper-fallback.sh"
FALLBACK_HOME="$STAGE/home-fallback"
mkdir -p "$FALLBACK_HOME"
plant_running_app "$FALLBACK_HOME/Applications" "$STAGE/helper-fallback.sh"
# MEETINGS_APPS empty rather than absent: install.sh tests `[ -z "${MEETINGS_APPS:-}" ]` and expands
# `${MEETINGS_APPS:-…}`, so an empty value takes the same branch an unset one does, and `env -i` has no
# way to unset what install_run sets.
rc="$(install_run MEETINGS_APPS="" HOME="$FALLBACK_HOME")"
[ "$rc" != 0 ] || die "installing into the fallback location replaced a recording app without a word.
                      That is every non-admin account, and the recording guard did not run at all."
grep -q "the app is going to $FALLBACK_HOME/Applications" "$STAGE/out" \
    || die "install.sh did not fall back to ~/Applications, so this arm tested the ordinary path:
$(cat "$STAGE/out")"
grep -q "Investor call" "$STAGE/out" \
    || die "the fallback path's refusal does not name the recording it protected:
$(cat "$STAGE/out")"
pgrep -f "^$SLEEPER$" >/dev/null 2>&1 \
    || die "the fallback path killed the running app it had just refused to disturb"
pkill -f "^$SLEEPER$" 2>/dev/null || true
SLEEPER=""
pass "the recording guard reads the fallback location, not the one it fell back from"

echo "==> an upgrade in the fallback location is told about its permissions"
# The other half: with $INSTALLED_REQ built from the wrong directory it was always empty, so an upgrade
# in the fallback location printed the first-install text and never mentioned that macOS was about to
# ask for the microphone again.
NOTE_HOME="$STAGE/home-fallback-note"
mkdir -p "$NOTE_HOME/Applications"
cp -R "$ROOT/dist/Meetings.app" "$NOTE_HOME/Applications/Meetings.app"
codesign --force --sign - --timestamp=none \
    --entitlements Packaging/Meetings.entitlements "$NOTE_HOME/Applications/Meetings.app" 2>/dev/null \
    || die "could not plant an ad-hoc-signed copy in the fallback location"
rc="$(install_run MEETINGS_APPS="" HOME="$NOTE_HOME")"
[ "$rc" = 0 ] || die "upgrading in the fallback location failed (exit $rc):
$(cat "$STAGE/out")"
[ -d "$NOTE_HOME/Applications/Meetings.app" ] || die "the fallback install went somewhere else entirely"
grep -q "Screen & System Audio" "$STAGE/out" \
    || die "an upgrade in the fallback location said nothing about permissions, which means
                      \$INSTALLED_REQ was read from the wrong directory again:
$(cat "$STAGE/out")"
grep -q "Setup will ask for the microphone" "$STAGE/out" \
    && die "an upgrade in the fallback location was described as a first install:
$(cat "$STAGE/out")"
pass "an upgrade in the fallback location is recognised as an upgrade"

# ---------------------------------------------------------------- an install it cannot replace
# The case that reaches every existing non-admin user, and the one where the first fix was worse than
# the defect. The old installer wrote /Applications with `sudo mv`, so this population exists: an
# account that cannot write /Applications but has Meetings sitting in it.
#
# Falling back on "not writable" alone gave them a SECOND copy in ~/Applications, the previous one left
# where it was, /usr/local/bin/meetings still pointing into it, and the fresh-install text over an
# upgrade. Measured: two copies. But refusing instead — insisting on the in-place upgrade and its
# password — strands exactly the same people, because /Applications is drwxrwxr-x root:admin, so an
# unwritable one means the account is outside group admin, which is the same group sudo is granted to.
# Measured too: nothing installed, non-zero exit, after two messages promising a password would work.
# Worse than two copies, because at least those left a running app.
#
# So: preferred, not mandatory. `can_replace` decides, and when it says no the run falls back and NAMES
# what it left behind. That is what this asserts — a working app installed, the old one untouched, and
# the user told where it is and how to remove it. There is no terminal here and this account is not
# being asked for a password, so `can_replace` takes its no branch.
echo "==> an install it cannot replace is left alone, and named"
mkdir -p "$STAGE/home-second/Applications"
chmod u+w "$NOAPPS"
cp -R "$ROOT/dist/Meetings.app" "$NOAPPS/Meetings.app"
chmod 500 "$NOAPPS"
# MEETINGS_APPS empty, for the reason the arm above records: install_run always sets it, and an empty
# value takes the same branch an unset one does. Without this the fallback logic is never reached and
# the case passes on the ordinary path.
rc="$(install_run MEETINGS_APPS="" HOME="$STAGE/home-second")"
[ "$rc" = 0 ] || die "install.sh refused rather than falling back, which strands an account that
                      cannot write the existing location and cannot sudo either:
$(cat "$STAGE/out")"
[ -x "$STAGE/home-second/Applications/Meetings.app/Contents/MacOS/Meetings" ] \
    || die "install.sh reported success without leaving a usable app in the fallback location"
chmod u+w "$NOAPPS"
[ -d "$NOAPPS/Meetings.app" ] || die "the existing install was removed rather than left alone"
grep -q "An older Meetings is still at $NOAPPS/Meetings.app" "$STAGE/out" \
    || die "install.sh left a copy behind without naming it, which is the silent two-copies outcome
                      wearing a different exit code:
$(cat "$STAGE/out")"
grep -q "sudo rm -rf" "$STAGE/out" \
    || die "install.sh named the copy it left behind without saying how to remove it:
$(cat "$STAGE/out")"
pass "an unreplaceable install is left alone, named, and never silently duplicated"
chmod u+w "$NOAPPS"
rm -rf "$NOAPPS/Meetings.app" "$STAGE/home-second"
chmod 500 "$NOAPPS"
pin_stage "$SHA1"

echo "install-check OK"
