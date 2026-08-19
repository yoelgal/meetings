#!/usr/bin/env bash
#
# Packages an already-assembled dist/Meetings.app into the two files a GitHub release carries.
#
#   scripts/build-app.sh && MEETINGS_RELEASE=1 scripts/package-release.sh
#
# Writes dist/Meetings-arm64.zip and dist/Meetings-arm64.zip.sha256, and prints the zip's absolute
# path as its last line of stdout so a workflow step can capture it without parsing anything.
#
# It assembles nothing and builds nothing: build-app.sh owns the bundle, including the version stamp
# and the signature, and this reads both back out rather than deciding either. Two jobs doing the
# stamping is how a release ends up with a zip whose name and whose Info.plist disagree.
#
# The asset names carry no version on purpose. GitHub serves
# releases/latest/download/<asset-name> as a redirect to the newest release's asset of that exact
# name, so a version-less name gives install.sh one stable URL with no API call, no JSON to parse in
# bash and no rate limit to hit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Meetings.app"
ZIP="$ROOT/dist/Meetings-arm64.zip"
# arm64 is the only architecture there is a build for: Package.swift targets macOS 26 and the speech
# models are CoreML on Apple Silicon. The name says so rather than leaving a future Intel asset to be
# told apart from this one by its release date.
DIGEST="$ZIP.sha256"

die() { echo "package-release: $*" >&2; exit 1; }

[ -d "$APP" ] || die "there is no $APP to package. Run scripts/build-app.sh first."

# The version is read from the bundle, never from git: this script can run in a job that never had
# the tag, and a release whose zip and whose Info.plist disagree about the version is a release the
# in-app update check reports wrongly forever.
#
# An empty one is fatal rather than cosmetic. UpdateCheck parses CFBundleShortVersionString as a
# dotted version to compare against the latest release, and a build it cannot parse silently believes
# it is current — so an unversioned release is one that never offers itself as an update.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$VERSION" ] || die "$APP has no CFBundleShortVersionString. build-app.sh stamps it; a bundle
                      without it cannot be compared against a release, so the update check would
                      never fire for anyone who installed this."

echo "==> packaging $VERSION"
rm -f "$ZIP" "$DIGEST"
# ditto, not zip. An .app is a tree of symlinks (Contents/Resources bundles) and sealed resource
# forks, and `zip` flattens the symlinks and drops the forks — the archive still extracts, and the
# extracted bundle fails codesign, which is a failure that only shows up on the user's Mac at launch.
# --sequesterRsrc keeps the metadata where Archive Utility puts it, and --keepParent puts
# Meetings.app itself inside the zip rather than spilling Contents/ into the download directory.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP" || die "ditto could not archive $APP"

# The bare filename, not the path. install.sh verifies by cd'ing into the download directory and
# running `shasum -a 256 -c`, which resolves whatever name the file names relative to the working
# directory — a path from this machine in there makes every verification fail with "no such file".
( cd "$(dirname "$ZIP")" && shasum -a 256 "$(basename "$ZIP")" ) > "$DIGEST"

# The round trip, before this says it worked. The archive tool is exactly where a signature breaks,
# and it breaks silently: the zip is well-formed, the upload succeeds, the release looks finished, and
# the app refuses to launch on every Mac that installs it. Extracting and verifying here costs two
# seconds and is the only place that defect is catchable before a user finds it.
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ZIP" "$CHECK" || die "the zip just written does not extract"
[ -d "$CHECK/Meetings.app" ] || die "the zip does not contain Meetings.app at its root — --keepParent
                      is what puts it there"
codesign --verify --strict "$CHECK/Meetings.app" \
    || die "the extracted bundle fails codesign, so archiving broke the signature. Do not ship this."

echo "    version   $VERSION"
echo "    digest    $(cut -d' ' -f1 "$DIGEST")"
echo "$ZIP"
