#!/usr/bin/env bash
#
# Tight screenshot of one window, without disturbing it.
#
#   scripts/shot.sh com.yoelgal.Meetings /tmp/meetings.png
#   scripts/shot.sh 41234 /tmp/meetings.png            # by pid
#   scripts/shot.sh dist/Meetings.app /tmp/x.png       # by .app path (reads its bundle id)
#
# It does not launch, raise, focus, move, resize or close anything, and it makes no sound. Launch the
# app yourself with `open -g` first — the operator is using this Mac and nothing here may take focus.
#
# screencapture -l reads the window server's backing store, so an unfocused, occluded or fully
# backgrounded window captures fine.
set -euo pipefail

TARGET="${1:?usage: shot.sh <bundle-id | pid | /path/App.app> <out.png> [timeout-secs]}"
OUT="${2:?usage: shot.sh <bundle-id | pid | /path/App.app> <out.png> [timeout-secs]}"
TIMEOUT="${3:-20}"

if [[ "$TARGET" == *.app ]]; then
    TARGET="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist")"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${CAFF:-}" ] && kill "$CAFF" 2>/dev/null; true' EXIT

cat > "$WORK/winpick.swift" <<'SWIFT'
// Prints "<windowID>\t<width>x<height>" for the largest normal window owned by a bundle id or pid.
// Read-only: it never activates the app or touches the window.
import AppKit
import CoreGraphics

let target = CommandLine.arguments[1]
let pids: Set<pid_t>
if let pid = pid_t(target) {
    pids = [pid]
} else {
    pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: target)
        .map(\.processIdentifier))
}
guard !pids.isEmpty else { exit(1) }

// .optionAll rather than .optionOnScreenOnly: a backgrounded or occluded window drops off the
// on-screen list but is still in the window list and still capturable.
let infos = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
var best: (id: Int, w: Int, h: Int)?
for win in infos {
    guard let pid = win[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
          (win[kCGWindowLayer as String] as? Int) == 0,   // layer 0 == a normal window, not a panel
          let id = win[kCGWindowNumber as String] as? Int,
          let bounds = win[kCGWindowBounds as String] as? [String: Double],
          let w = bounds["Width"], let h = bounds["Height"], w >= 200, h >= 200 else { continue }
    if best == nil || Int(w * h) > best!.w * best!.h { best = (id, Int(w), Int(h)) }
}
guard let b = best else { exit(2) }
print("\(b.id)\t\(b.w)x\(b.h)")
SWIFT

# Compiled, not interpreted: `swift winpick.swift` costs about a second of startup per poll, which
# would make the timeout argument mean roughly half what it says.
swiftc -O -o "$WORK/winpick" "$WORK/winpick.swift"

# A slept display has no window backing stores and screencapture -l fails with "could not create
# image from window". -u wakes the display only; it takes no focus and makes no sound.
caffeinate -u -t 60 &
CAFF=$!

INFO=""
for _ in $(seq 1 "$TIMEOUT"); do
    if INFO="$("$WORK/winpick" "$TARGET" 2>/dev/null)"; then break; fi
    INFO=""
    sleep 1
done
[ -n "$INFO" ] || { echo "shot.sh: no capturable window for $TARGET after ${TIMEOUT}s" >&2; exit 1; }

WID="${INFO%%$'\t'*}"
SIZE="${INFO##*$'\t'}"
mkdir -p "$(dirname "$OUT")"
# -x silent (no shutter) · -o no drop shadow, so the crop is tight · -l just this window
screencapture -x -o -t png -l "$WID" "$OUT"
echo "$OUT  ($TARGET  window $WID  ${SIZE}pt)"
