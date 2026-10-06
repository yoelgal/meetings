#!/usr/bin/env bash
#
# Render the launch film, put its soundtrack and poster in, and prove the result is in sync.
#
#   video/brag/finish.sh
#
# The audio is muxed here from the soundtrack WAV with ffmpeg's own AAC encoder rather than taken
# from Remotion's render: re-muxing that one with `-c:a copy` dropped the encoder-priming edit, and
# the film's audio played 42.67 ms (2048 samples) late — two and a half frames, measured by
# `soundtrack.py --verify`. ffmpeg writes the edit list, so decoders trim the priming themselves.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B="$ROOT/video/brag"

# Picture first, silent: the soundtrack places each fade's sound on the frame it becomes visible,
# measured from this render. The picture does not depend on the audio, so the order is free.
( cd "$ROOT/video/film" && npx remotion render Launch "$B/work-render.mp4" --codec=h264 --crf=17 \
    --color-space=bt709 --muted --timeout=120000 --log=error )
python3 "$B/soundtrack.py" --picture "$B/work-render.mp4"
# The poster is the reveal, settled: it says what the product does in one frame. Baked in as
# frame 0 (replacing it, not adding one) so every platform's idle thumbnail is that frame — a
# deliberate trade: playback opens with that one frame (16.7 ms) before the black hook, which is
# the price of the thumbnail being the reveal on platforms that ignore cover art.
ffmpeg -loglevel error -y -ss 9.6 -i "$B/work-render.mp4" -frames:v 1 "$B/work-poster.png"
ffmpeg -loglevel error -y -i "$B/work-poster.png" -q:v 2 "$B/brag.jpg"
ffmpeg -loglevel error -y -i "$B/work-render.mp4" -i "$B/work-poster.png" \
    -i "$ROOT/video/film/public/launch/soundtrack.wav" \
    -filter_complex "[0:v][1:v]overlay=enable='eq(n,0)'[v]" -map "[v]" -map 2:a \
    -c:v libx264 -crf 17 -preset slow -pix_fmt yuv420p -c:a aac -b:a 256k -shortest \
    -movflags +faststart "$B/brag.mp4"
node "$ROOT/video/film/scripts/tag-colour.mjs" "$B/brag.mp4"
python3 "$B/soundtrack.py" --picture "$B/work-render.mp4" --verify "$B/brag.mp4" | tee "$B/soundtrack-report.txt"
exit "${PIPESTATUS[0]}"
