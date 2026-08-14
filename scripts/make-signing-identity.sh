#!/usr/bin/env bash
#
# OPTIONAL. Creates a self-signed code-signing certificate in your login keychain so that rebuilt
# copies of Meetings.app keep the microphone and screen-recording permissions you already granted.
#
#   scripts/make-signing-identity.sh              # explains itself, then asks before doing anything
#   scripts/make-signing-identity.sh --dry-run    # print the plan and stop
#   scripts/make-signing-identity.sh --yes        # skip the confirmation
#
# Nothing in the build ever runs this. It touches your keychain, which is your decision to make.
#
# Why it exists: build-app.sh signs ad-hoc by default, and an ad-hoc signature's identity is the
# hash of the binary itself. Change one line of Swift, rebuild, and macOS sees an app it has never
# met — so it asks for the microphone and for screen recording again. Signing with a certificate
# that stays the same across rebuilds makes those grants stick.
set -euo pipefail

NAME="Meetings Local Signing"
# Where the identity lands. Overridable so this script can be exercised against a throwaway
# keychain instead of the real one; leave it unset and it uses your login keychain.
KEYCHAIN="${MEETINGS_SIGN_KEYCHAIN:-$(security login-keychain | tr -d ' "')}"
DAYS=3650

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y)  ASSUME_YES=1 ;;
        -h|--help) sed -n '2,16p' "$0" | cut -c 3-; exit 0 ;;
        *) echo "make-signing-identity: unknown argument: $arg" >&2; exit 64 ;;
    esac
done

die() { echo "make-signing-identity: $*" >&2; exit 1; }

undo_instructions() {
    cat <<EOF

To undo all of this later, one command:

    security delete-identity -c "$NAME" -t

That removes the certificate, its private key and its trust setting. Builds go back to ad-hoc
signing on their own — nothing else to change.
EOF
}

# Already valid for signing? Then there is nothing to do, and saying so is the whole job. Running
# this script twice must not leave two certificates behind.
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$NAME"; then
    echo "\"$NAME\" is already in $KEYCHAIN and valid for code signing."
    echo "scripts/build-app.sh will use it automatically. Nothing to do."
    undo_instructions
    exit 0
fi

# The half-finished case: the certificate is there but was never trusted, so codesign will not
# accept it. That is the trust step below and only the trust step, so do not make a second key.
EXISTING_UNTRUSTED=0
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    EXISTING_UNTRUSTED=1
fi

cat <<EOF
This will, in your own login keychain and nowhere else:

  1. Generate a 2048-bit RSA key and a self-signed certificate called "$NAME",
     valid for $DAYS days and marked for code signing only. The key is created in a temporary
     directory that is deleted before this script exits — the keychain gets the only copy.
  2. Import the key and certificate into $KEYCHAIN
     and allow /usr/bin/codesign to use the key without asking every time.
  3. Mark that certificate as trusted for code signing, for your user account only.
     macOS will ask for your login password at this step. That dialog is the system's, not this
     script's: changing your own trust settings requires it, and there is no way around it.
  4. Test-sign a throwaway app bundle to prove the identity actually works, then delete it.

It does not touch the system trust store, other users, or anything you have already signed. It
grants no permission and installs nothing outside the keychain. The certificate is only ever
trusted by you, on this Mac — it is not a Developer ID and it will not make the app trusted
anywhere else.
EOF
[ "$EXISTING_UNTRUSTED" -eq 1 ] && echo "
Note: a certificate called \"$NAME\" already exists here but is not trusted for code signing yet.
Steps 1 and 2 are skipped; only the trust step runs."

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "--dry-run: nothing was done."
    undo_instructions
    exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
    echo
    read -r -p 'Go ahead? Type yes to continue: ' reply
    [ "$reply" = "yes" ] || { echo "Nothing was done."; exit 1; }
fi

WORK="$(umask 077; mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ "$EXISTING_UNTRUSTED" -eq 0 ]; then
    echo
    echo "==> generating the certificate"
    # /usr/bin/openssl, explicitly: it is LibreSSL and always present. A Homebrew openssl earlier on
    # PATH is a different program with different defaults and this has to work on a stock Mac.
    # Extensions come from a config file rather than -addext, which LibreSSL does not have.
    cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $NAME
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
        -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null \
        || die "openssl could not generate the certificate"

    echo "==> importing it into $KEYCHAIN"
    /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -name "$NAME" -passout pass:transient -out "$WORK/identity.p12" \
        || die "openssl could not package the certificate"
    # -A rather than -T alone: the key is usable by any tool without a keychain prompt per signature.
    # This key signs nothing but your own local builds, so a prompt per build buys you nothing.
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P transient -T /usr/bin/codesign -A \
        || die "the certificate could not be imported into $KEYCHAIN"
else
    # Recover the certificate from the keychain so add-trusted-cert has a file to work from.
    security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$WORK/cert.pem" \
        || die "could not read the existing certificate out of $KEYCHAIN"
fi

echo "==> marking it trusted for code signing (macOS will ask for your login password)"
# User trust domain only — no -d, which would be the admin store and would need sudo. -p codeSign
# keeps the trust narrow: this certificate is trusted to sign code and for nothing else, so it can
# never vouch for a website or an email.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" \
    || die "the certificate was not trusted — it is in the keychain but codesign will refuse it.
       Re-run this script to retry just that step, or set it by hand in Keychain Access:
       double-click \"$NAME\" > Trust > Code Signing > Always Trust."

echo "==> checking that codesign accepts it"
security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$NAME" \
    || die "the identity still is not valid for code signing"

# A signature that codesign then rejects is worse than no certificate, because the failure would
# turn up in the middle of someone's build. Prove it end to end on a bundle nobody cares about.
PROBE="$WORK/Probe.app"
mkdir -p "$PROBE/Contents/MacOS"
cat > "$PROBE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleExecutable</key><string>Probe</string>
	<key>CFBundleIdentifier</key><string>com.yoelgal.Meetings.signing-probe</string>
	<key>CFBundleName</key><string>Probe</string>
	<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
printf '#!/bin/sh\nexit 0\n' > "$PROBE/Contents/MacOS/Probe"
chmod +x "$PROBE/Contents/MacOS/Probe"
codesign --force --sign "$NAME" --keychain "$KEYCHAIN" --timestamp=none "$PROBE" \
    || die "codesign refused the new identity"
codesign --verify --strict "$PROBE" || die "the test signature did not verify"

echo
echo "Done. \"$NAME\" is ready."
echo "scripts/build-app.sh picks it up on its own from now on — it prints which identity it used."
echo "Rebuild once and re-grant microphone and screen recording one last time; after that they stick."
undo_instructions
