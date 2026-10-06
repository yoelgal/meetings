#!/usr/bin/env bash
#
# Turn a screen recording into the few frames worth looking at.
#
#   scripts/vidkeys.sh <video> [outdir] [fps] [sensitivity]
#
# A 46-second 240fps recording is ~11,000 frames, of which maybe twenty differ in any way a person
# would call a change. Reading them all is impossible, and sampling blind misses the one-frame flash
# that is usually the whole point. Two passes fix that:
#
#   1. Decimate in TIME - resample to `fps` (default 10). Nothing a UI does needs 240Hz to describe.
#   2. Decimate in CONTENT - drop every frame that looks like the last one KEPT, so a window sitting
#      still for eight seconds costs one frame instead of eighty.
#
# Out comes a directory of stills named by the timestamp they happened at, plus a manifest giving each
# one's duration - how long the screen actually held that state. The durations are why the timestamps
# are worth keeping: the same picture held for 3s is the app working and held for 0.1s is a flash, and
# those two need telling apart.
#
# The content pass is `vidkeys-dedupe.swift` rather than ffmpeg's `mpdecimate`, because mpdecimate
# keeps a frame whenever any single 8x8 block differs a lot - so a moving cursor or a ticking clock
# defeats it completely. Measured on a real 46s recording: mpdecimate kept 221 of 221 frames.
#
# `sensitivity` sets how much of the screen must move to count as a change:
#   low   - only big events (a window opening, a Space switch)
#   mid   - the default; catches panel and content changes
#   high  - subtle repaints, e.g. a titlebar changing shade. Use when hunting a rendering defect.
set -euo pipefail

VIDEO="${1:?usage: vidkeys.sh <video> [outdir] [fps] [sensitivity: low|mid|high]}"
OUT="${2:-/tmp/vidkeys}"
FPS="${3:-10}"
SENS="${4:-mid}"

command -v ffmpeg >/dev/null || { echo "vidkeys: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }
[ -f "$VIDEO" ] || { echo "vidkeys: no such file: $VIDEO" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# blockDelta = how much a block's brightness must move to count as changed
# minFraction = what share of blocks must have moved for the frame to be worth keeping
case "$SENS" in
  low)  TUNE="0.06 0.020" ;;
  mid)  TUNE="0.03 0.006" ;;
  high) TUNE="0.01 0.002" ;;
  *) echo "vidkeys: sensitivity must be low, mid or high (got '$SENS')" >&2; exit 1 ;;
esac

# Only ever a directory this script made: an existing one must be empty or carry its manifest.
# `vidkeys.sh take.mov .` used to delete the current directory, whatever was in it.
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT")" ] && [ ! -f "$OUT/manifest.txt" ]; then
    echo "vidkeys: $OUT is not empty and is not a previous vidkeys output; refusing to clear it" >&2
    exit 1
fi
rm -rf "$OUT"; mkdir -p "$OUT/all"

# Scale to 1512 wide: a 2x retina capture carries no extra information for this and halves the work.
ffmpeg -loglevel error -i "$VIDEO" -vf "fps=$FPS,scale=1512:-1" -f image2 "$OUT/all/%05d.png" -y

SAMPLED=$(find "$OUT/all" -name '*.png' | wc -l | tr -d ' ')
[ "$SAMPLED" -gt 0 ] || { echo "vidkeys: no frames extracted" >&2; exit 1; }

# Cache the compiled comparator, keyed by the source's checksum so an edit rebuilds it and an
# unchanged one costs nothing on the next run.
SUM=$(shasum -a 256 "$HERE/vidkeys-dedupe.swift" | cut -c1-12)
BIN="${TMPDIR:-/tmp}/vidkeys-dedupe-$SUM"
[ -x "$BIN" ] || swiftc -O "$HERE/vidkeys-dedupe.swift" -o "$BIN" 2>/dev/null || {
  echo "vidkeys: could not build $HERE/vidkeys-dedupe.swift" >&2; exit 1; }

# skipTop=0.03 drops the menu bar from the comparison: its clock ticks every second and would
# otherwise register as a change on a recording where nothing else moved.
# shellcheck disable=SC2086
"$BIN" $TUNE 0.03 "$OUT/all"/*.png > "$OUT/.keep"

MANIFEST="$OUT/manifest.txt"
: > "$MANIFEST"
awk -v fps="$FPS" -v out="$OUT" -v total="$SAMPLED" '
  { keep[NR] = $1 }
  END {
    for (i = 1; i <= NR; i++) {
      t = (keep[i] - 1) / fps
      nextIdx = (i < NR) ? keep[i+1] : total + 1
      held = (nextIdx - keep[i]) / fps
      printf "k%02d  t=%7.3fs  held %6.3fs  %s/k%02d_t%07.3f.png\n", i, t, held, out, i, t
      # Index unpadded on purpose: bash printf reads a leading-zero "08" as octal and errors.
      printf "%05d %d %.3f\n", keep[i], i, t > (out "/.rename")
    }
  }' "$OUT/.keep" >> "$MANIFEST"

while read -r src idx t; do
  mv "$OUT/all/$src.png" "$(printf '%s/k%02d_t%07.3f.png' "$OUT" "$idx" "$t")"
done < "$OUT/.rename"
rm -rf "$OUT/all" "$OUT/.keep" "$OUT/.rename"

KEPT=$(find "$OUT" -name 'k*.png' | wc -l | tr -d ' ')
DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$VIDEO" 2>/dev/null || echo 0)
echo "vidkeys: $(basename "$VIDEO")"
printf "  %.2fs -> %s frames at %sfps -> %s kept (sensitivity: %s, %d%% reduction)\n" \
  "$DUR" "$SAMPLED" "$FPS" "$KEPT" "$SENS" "$(( 100 - (KEPT * 100 / SAMPLED) ))"
echo "  manifest: $MANIFEST"
echo
sed -n '1,45p' "$MANIFEST"
[ "$KEPT" -gt 45 ] && echo "  ... $((KEPT - 45)) more in $MANIFEST"
exit 0
