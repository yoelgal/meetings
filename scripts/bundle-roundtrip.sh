#!/usr/bin/env bash
#
# Proves the headline claim about the .meetingbundle format: it round-trips exactly.
#
#   scripts/bundle-roundtrip.sh
#
# Builds a meeting with everything in it — two-channel transcript, live notes anchored to specific
# segments, pre-notes, a summary, actions and audio — exports it, imports it into a *different*
# store, exports it again, and diffs the two exports. The only field allowed to differ is the
# manifest's export timestamp, and the second diff normalises that away and must come out empty.
#
# The note anchors are the trap the format is built around: a note points at a transcript segment
# id, ids are AUTOINCREMENT and are reassigned on import, so the bundle carries the note's position
# in the transcript instead. Step 4 checks the anchors still point at the same sentences.
#
# Runs entirely under one mktemp directory with MEETINGS_HOME pointed at it: it never touches the
# real store, never reads a calendar, and leaves nothing behind.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMPROOT%/}/meetings-roundtrip.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail_count=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { fail_count=$((fail_count + 1)); printf '  FAIL  %s\n' "$1"; }
section() { printf '\n=== %s %s\n' "$1" "$(printf '=%.0s' $(seq 1 $((60 - ${#1}))))"; }

# --- the binary ------------------------------------------------------------------------------
#
# The shipped CLI, once the orchestrator has registered the IO subcommands on MeetingsCLI. Until
# then, a shim built from the same command sources with a generated root — same code, same core,
# just a root that knows about export/import/create/backup. The shim disappears from use the moment
# the real binary answers `export --help`.

swift build --product meetings >/dev/null 2>&1
BIN="$REPO/.build/debug/meetings"

# `meetings export --help` exits 0 even when `export` is not a subcommand — ArgumentParser answers
# --help with the root help. Ask the subcommand list instead.
if ! "$BIN" --help 2>&1 | awk '{print $1}' | grep -qx export; then
    printf 'note: the meetings binary has no `export` subcommand yet — building the IO shim.\n' >&2
    SHIM="$REPO/.build/io-shim"
    mkdir -p "$SHIM/Sources/meetings"
    cat >"$SHIM/Package.swift" <<PACKAGE
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "meetings-io-shim",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "$REPO"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    ],
    targets: [
        .executableTarget(
            name: "meetingsio",
            dependencies: [
                .product(name: "MeetingsCore", package: "meetings-thing"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/meetings"
        )
    ]
)
PACKAGE
    rm -f "$SHIM/Sources/meetings"/*.swift
    for file in "$REPO"/Sources/meetings/*.swift; do
        cp "$file" "$SHIM/Sources/meetings/$(basename "$file")"
    done
    # Same root, plus the four commands this unit owns.
    perl -0pi -e 's/(\n\s+SkillCommand\.self,)/$1\n            ExportCommand.self,\n            ImportCommand.self,\n            CreateCommand.self,\n            BackupCommand.self,/' \
        "$SHIM/Sources/meetings/MeetingsCLI.swift"
    (cd "$SHIM" && swift build --product meetingsio) >"$WORK/shim-build.log" 2>&1 \
        || { echo "shim build failed:" >&2; tail -30 "$WORK/shim-build.log" >&2; exit 1; }
    BIN="$SHIM/.build/debug/meetingsio"
fi
printf 'CLI: %s\n' "$BIN"

export MEETINGS_HOME="$WORK/store-a"
mkdir -p "$WORK/in"

# --- 1. a meeting with everything in it ------------------------------------------------------

section "1. seed a meeting with transcript, notes, pre-notes, summary, actions and audio"

cat >"$WORK/in/transcript.json" <<'JSON'
[
  {"channel": "mic",    "startMs": 0,     "endMs": 4000,  "text": "morning — shall we start with the ptychography run"},
  {"channel": "system", "startMs": 4500,  "endMs": 9000,  "text": "yes, the numbers came back better than Tuesday"},
  {"channel": "mic",    "startMs": 9500,  "endMs": 14000, "text": "then we ship Torch0 on Friday"},
  {"channel": "system", "startMs": 14500, "endMs": 19000, "text": "Sofia will send the figures over tonight"}
]
JSON

cat >"$WORK/in/prenotes.md" <<'MD'
- ask about the ptychography run
- confirm the Friday ship date
MD

cat >"$WORK/in/summary.md" <<'MD'
# Decisions

Torch0 ships on Friday. The ptychography numbers came back better than Tuesday's.
MD

cat >"$WORK/in/actions.json" <<'JSON'
[
  {"text": "Send the ptychography figures", "owner": "Sofia", "due": "tonight", "done": false},
  {"text": "Book the Friday ship review", "done": true}
]
JSON

REF="$("$BIN" create \
    --title "Ma'agan Michael / Torch0 sync" \
    --date "2026-02-02T09:00Z" \
    --duration 45m \
    --folder "Torch0" \
    --attendees "Will Smith,Sofia Nunes <sofia@example.com>" \
    --transcript-file "$WORK/in/transcript.json" \
    --prenotes-file "$WORK/in/prenotes.md" \
    --summary-file "$WORK/in/summary.md" 2>"$WORK/create.err")"
printf '$ meetings create … --transcript-file … --prenotes-file … --summary-file …\n'
sed 's/^/  /' "$WORK/create.err"
printf '  ref: %s\n' "$REF"
[ -n "$REF" ] || { echo "create failed — nothing to round-trip" >&2; exit 1; }

"$BIN" note add "$REF" "starting late again" --at 0:00 >/dev/null
"$BIN" note add "$REF" "better than Tuesday — get the exact figure" --at 0:06 >/dev/null
"$BIN" note add "$REF" "Friday ship confirmed" --at 0:12 >/dev/null
"$BIN" actions set "$REF" --file "$WORK/in/actions.json" >/dev/null
printf '$ meetings note add … x3, meetings actions set …\n'

# Real speech, rendered silently to a file — `say -o` never reaches the speakers.
AUDIO_DIR="$MEETINGS_HOME/audio/$REF"
mkdir -p "$AUDIO_DIR"
say -o "$AUDIO_DIR/mic.wav" --data-format=LEI16@16000 "morning, shall we start with the ptychography run" 2>/dev/null
say -o "$AUDIO_DIR/system.wav" --data-format=LEI16@16000 "yes, the numbers came back better than Tuesday" 2>/dev/null
printf '$ say -o mic.wav / system.wav  (silent render, 16 kHz LEI16)\n'
ls -l "$AUDIO_DIR" | sed 's/^/  /'

"$BIN" show "$REF" --json >"$WORK/before.json"
python3 - "$WORK/before.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
m = d["meeting"]
print(f"  state={m['state']} folder={m['folder']} attendees={len(m['attendees'])} "
      f"actions={len(d.get('actions') or [])} prenotes={'yes' if d.get('preNotes') else 'no'} "
      f"summary={'yes' if d.get('summary') else 'no'}")
PY

# --- 2. export ---------------------------------------------------------------------------------

section "2. export the bundle, with audio"

printf '$ meetings export %s --with-audio --out %s\n' "$REF" "$WORK/out1"
"$BIN" export "$REF" --with-audio --out "$WORK/out1" | sed 's/^/  /'
BUNDLE1="$(find "$WORK/out1" -maxdepth 1 -name '*.meetingbundle' | head -1)"
find "$BUNDLE1" -type f | sed "s|$BUNDLE1/|  |" | sort

# --- 3. import into a different store -----------------------------------------------------------

section "3. import into a second, empty store"

printf '$ MEETINGS_HOME=%s meetings import %s\n' "$WORK/store-b" "$(basename "$BUNDLE1")"
MEETINGS_HOME="$WORK/store-b" "$BIN" import "$BUNDLE1" | sed 's/^/  /'
REF2="$(MEETINGS_HOME="$WORK/store-b" "$BIN" list --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["meetings"][0]["ref"])')"

# --- 4. the anchors ------------------------------------------------------------------------------

section "4. note anchors still point at the same sentences after re-id"

MEETINGS_HOME="$WORK/store-b" "$BIN" show "$REF2" --notes --transcript --json >"$WORK/after.json"
"$BIN" show "$REF" --notes --transcript --json >"$WORK/before-full.json"
python3 - "$WORK/before-full.json" "$WORK/after.json" <<'PY'
import json, sys

def anchored(path):
    d = json.load(open(path))
    by_id = {s["id"]: s["text"] for s in d["transcript"]}
    return [(n["text"], by_id.get(n["anchorSegmentId"])) for n in d["notes"]], \
           {s["id"] for s in d["transcript"]}

before, before_ids = anchored(sys.argv[1])
after, after_ids = anchored(sys.argv[2])
for (note, text) in after:
    print(f"  {note!r:48} -> {text!r}")
print(f"  segment ids before={sorted(before_ids)} after={sorted(after_ids)} "
      f"(a fresh store hands out the same ids; step 8 is where they are forced to differ)")
sys.exit(0 if before == after and all(t for _, t in after) else 1)
PY
if [ $? -eq 0 ]; then ok "every note anchors to the same sentence it did before the round trip"
else bad "note anchors moved across the round trip"; fi

# --- 5. export again -----------------------------------------------------------------------------

section "5. export the imported meeting again"

printf '$ MEETINGS_HOME=%s meetings export %s --with-audio --out %s\n' "$WORK/store-b" "$REF2" "$WORK/out2"
MEETINGS_HOME="$WORK/store-b" "$BIN" export "$REF2" --with-audio --out "$WORK/out2" | sed 's/^/  /'
BUNDLE2="$(find "$WORK/out2" -maxdepth 1 -name '*.meetingbundle' | head -1)"

[ "$(basename "$BUNDLE1")" = "$(basename "$BUNDLE2")" ] \
    && ok "same bundle name: $(basename "$BUNDLE1")" \
    || bad "bundle names differ: $(basename "$BUNDLE1") vs $(basename "$BUNDLE2")"

# --- 6. the diff ----------------------------------------------------------------------------------

section "6. diff the two exports, raw"

printf '$ diff -r out1/*.meetingbundle out2/*.meetingbundle\n'
if diff -r "$BUNDLE1" "$BUNDLE2" >"$WORK/raw.diff" 2>&1; then
    printf '  (no differences at all)\n'
else
    sed 's/^/  /' "$WORK/raw.diff"
fi

section "7. diff again with the export timestamp and the row id normalised"

# The two fields legitimately allowed to differ: when the export ran, and the row id if the
# import had to mint a new one. Everything else must be byte-identical.
cp -R "$BUNDLE1" "$WORK/cmp-a"
cp -R "$BUNDLE2" "$WORK/cmp-b"
for side in "$WORK/cmp-a" "$WORK/cmp-b"; do
    perl -pi -e 's/("exportedAt" : ").*?"/$1<TIMESTAMP>"/' "$side/manifest.json"
    perl -pi -e 's/("id" : ").*?"/$1<ID>"/' "$side/meeting.json"
done
printf '$ diff -r cmp-a cmp-b\n'
if diff -r "$WORK/cmp-a" "$WORK/cmp-b" >"$WORK/norm.diff" 2>&1; then
    printf '  (empty — every byte of every file matches)\n'
    ok "export -> import -> export is byte-identical"
else
    sed 's/^/  /' "$WORK/norm.diff"
    bad "the two exports differ"
fi

printf '\n$ shasum of every file in both bundles\n'
(cd "$WORK/cmp-a" && find . -type f | sort | xargs shasum) | sed 's/^/  a  /'
(cd "$WORK/cmp-b" && find . -type f | sort | xargs shasum) | sed 's/^/  b  /'

# --- 8. importing twice ------------------------------------------------------------------------------

section "8. import the same bundle a second time — two meetings, first untouched"

printf '$ MEETINGS_HOME=%s meetings import %s --json\n' "$WORK/store-b" "$(basename "$BUNDLE1")"
MEETINGS_HOME="$WORK/store-b" "$BIN" import "$BUNDLE1" --json | tee "$WORK/second-import.json" | sed 's/^/  /'
python3 - "$WORK/second-import.json" "$REF2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ref"] != sys.argv[2], "the second import reused the first meeting's id"
assert d["idCollision"] is True, "the collision was not reported"
assert d["importedFrom"], "imported_from was not recorded"
PY
[ $? -eq 0 ] && ok "second import made a new id and recorded imported_from" || bad "second import misbehaved"

MEETINGS_HOME="$WORK/store-b" "$BIN" list --json >"$WORK/list-b.json"
python3 - "$WORK/list-b.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  meetings in store-b: {len(d['meetings'])}")
for m in d["meetings"]:
    print(f"    {m['ref']}  {m['state']:12} {m['source']:9} {m['title']}")
sys.exit(0 if len(d["meetings"]) == 2 else 1)
PY
[ $? -eq 0 ] && ok "two independent meetings" || bad "expected two meetings after two imports"

# The re-id case, in the script rather than only in the unit tests: the second import's segments
# got fresh ids, so its notes had to be rebuilt against them.
REF3="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ref"])' "$WORK/second-import.json")"
MEETINGS_HOME="$WORK/store-b" "$BIN" show "$REF3" --notes --transcript --json >"$WORK/reid.json"
python3 - "$WORK/after.json" "$WORK/reid.json" <<'PY'
import json, sys

def anchored(path):
    d = json.load(open(path))
    by_id = {s["id"]: s["text"] for s in d["transcript"]}
    return [(n["text"], by_id.get(n["anchorSegmentId"])) for n in d["notes"]], {s["id"] for s in d["transcript"]}

first, first_ids = anchored(sys.argv[1])
reid, reid_ids = anchored(sys.argv[2])
print(f"  segment ids: first import {sorted(first_ids)}, second import {sorted(reid_ids)} "
      f"(disjoint: {first_ids.isdisjoint(reid_ids)})")
for note, text in reid:
    print(f"  {note!r:48} -> {text!r}")
sys.exit(0 if first == reid and first_ids.isdisjoint(reid_ids) else 1)
PY
[ $? -eq 0 ] && ok "the re-id'd copy's notes anchor to the same sentences" || bad "anchors did not survive re-id"

MEETINGS_HOME="$WORK/store-b" "$BIN" show "$REF2" --json >"$WORK/first-after.json"
if python3 -c '
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(0 if a["meeting"]==b["meeting"] and a.get("summary")==b.get("summary") else 1)
' "$WORK/after.json" "$WORK/first-after.json" 2>/dev/null; then
    ok "the first import is byte-for-byte the meeting it was before the second"
else
    # `show --notes --transcript` and plain `show` differ in shape; compare the meeting object only.
    python3 - "$WORK/after.json" "$WORK/first-after.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))["meeting"]
b = json.load(open(sys.argv[2]))["meeting"]
print("  first meeting unchanged:" if a == b else "  CHANGED:", {k: (a[k], b[k]) for k in a if a[k] != b[k]} or "identical")
sys.exit(0 if a == b else 1)
PY
    [ $? -eq 0 ] && ok "the first import was not touched by the second" || bad "the second import changed the first"
fi

# --- result ---------------------------------------------------------------------------------------

printf '\n'
if [ "$fail_count" -eq 0 ]; then
    echo "BUNDLE ROUNDTRIP OK"
else
    echo "BUNDLE ROUNDTRIP FAILED — $fail_count check(s)"
fi
exit "$fail_count"
