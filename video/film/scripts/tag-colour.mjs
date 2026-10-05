// Writes full BT.709 colour signalling into a finished render, without re-encoding.
//
//   node scripts/tag-colour.mjs                        # out/meetings.mp4
//   node scripts/tag-colour.mjs out/meetings-master.mov
//
// `remotion render --color-space=bt709` sets the **matrix coefficients** and nothing else, so ffprobe
// reports `color_space=bt709` alongside `color_transfer=unknown` and `color_primaries=unknown`. A file
// tagged that way is at the mercy of whoever opens it: QuickTime assumes 709 and browsers have been
// known to assume an sRGB transfer, and the same near-black backdrop then reads lifted in one and
// crushed in the other. Three tags cost nothing and remove the guess.
//
// The mechanism differs by container, because that is where each format keeps the information:
//
//   H.264/mp4  the VUI inside the SPS, rewritten by the `h264_metadata` bitstream filter
//   ProRes/mov the `colr` atom, written by ffmpeg's own output colour options
//
// Both run under `-c copy`, so not a frame is decoded and nothing is re-compressed. The mp4 also gets
// `+faststart`, which moves the moov atom to the front so the film starts playing before it has
// finished downloading.
import { spawnSync } from 'node:child_process';
import { renameSync, existsSync, statSync } from 'node:fs';
import { dirname, extname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const target = resolve(root, process.argv[2] ?? 'out/meetings.mp4');
if (!existsSync(target)) {
  console.error(`tag-colour: ${target} does not exist — render it first`);
  process.exit(1);
}

const extension = extname(target);
// 1 is BT.709 for primaries, transfer and matrix alike, per ITU-T H.273 — the table AVC's VUI indexes.
const args =
  extension === '.mov'
    ? ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709']
    : [
        '-bsf:v',
        'h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1',
        '-movflags',
        '+faststart',
      ];

const temp = `${target}.tagged${extension}`;
const result = spawnSync('ffmpeg', ['-v', 'error', '-y', '-i', target, '-c', 'copy', ...args, temp], {
  stdio: 'inherit',
});
if (result.status !== 0) process.exit(result.status ?? 1);

renameSync(temp, target);
const megabytes = (statSync(target).size / 1e6).toFixed(1);
console.log(`tag-colour: ${target} tagged bt709 (primaries, transfer, matrix), ${megabytes} MB`);
