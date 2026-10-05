// Is every change of picture actually hidden by camera motion?
//
//   bun run audit
//
// The demo claims to be one continuous take. It is not literally one: the app's window states are posed at
// launch, so six separate captures are dissolved into one unbroken window rect (see `src/plan.ts`). The
// claim only holds if each dissolve lands while the camera is moving — a swap during a still moment is a
// cut with a fade on it, which is exactly what this demo is trying not to be.
//
// So rather than eyeballing frames, this solves the same camera the film does, from the same data, and
// prints how fast it was travelling through each swap. Speed is reported in frame pixels per frame, which
// is the unit that matters: it is how far the picture moved between the two frames a viewer sees either
// side of the swap's midpoint.
//
// The threshold is 6 px/frame. Below that the picture is effectively parked and the dissolve is visible as
// a dissolve; the two hand-checked bad swaps in this film's history both measured under 2. The one
// deliberate exception is the write-up, which is swapped behind the terminal's opaque scrim and needs no
// motion at all — it is invisible for a different reason, and the audit says so rather than failing.

import { CAMERA_SPRING, simulate } from '../src/loom/spring.ts';
import { pointerAt, zoomSegments, zoomTargetAt } from '../src/loom/track.ts';
import { CLOSING_AT, CLOSING_FOR, SHOTS, TERMINAL_AT, TERMINAL_FOR, TRACK } from '../src/plan.ts';
import { FPS } from '../src/theme.ts';

const FRAMES = Math.round(((CLOSING_AT + CLOSING_FOR) / 1000) * FPS);
const DURATION_MS = (FRAMES / FPS) * 1000;

// The card's geometry, mirrored from LoomStage. Kept as literals rather than exported, because the audit
// wanting them is not a reason for the renderer to widen its API.
const CARD_W = 1920 - 44 * 2;
const CARD_H = CARD_W * (900 / 1600);

const segments = zoomSegments(TRACK, DURATION_MS);
const common = { frames: FRAMES, fps: FPS, config: CAMERA_SPRING };
const amount = simulate({ ...common, target: (s) => zoomTargetAt(segments, s * 1000), initial: 1 });
const focusX = simulate({ ...common, target: (s) => pointerAt(TRACK, s * 1000).x });
const focusY = simulate({ ...common, target: (s) => pointerAt(TRACK, s * 1000).y });

const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

/** The window's rect at a frame, exactly as the stage computes it. */
const rect = (f) => {
  const a = amount[Math.min(f, FRAMES - 1)];
  const w = CARD_W * a;
  const h = CARD_H * a;
  const ox = clamp((0.5 - focusX[Math.min(f, FRAMES - 1)]) * w, -Math.max(0, (w - 1920) / 2), Math.max(0, (w - 1920) / 2));
  const oy = clamp((0.5 - focusY[Math.min(f, FRAMES - 1)]) * h, -Math.max(0, (h - 1080) / 2), Math.max(0, (h - 1080) / 2));
  return { w, h, left: 960 + ox - w / 2, top: 540 + oy - h / 2 };
};

/**
 * How far the picture moves between two consecutive frames, at the point of it the viewer is looking at.
 *
 * Both the pan and the zoom move pixels, and either alone is enough cover, so they are added rather than
 * reported separately: the pan as the movement of the window's top-left, the zoom as the movement of its
 * edge relative to that corner.
 */
const speedAt = (f) => {
  const a = rect(Math.max(0, f - 1));
  const b = rect(Math.min(FRAMES - 1, f + 1));
  const pan = Math.hypot(b.left - a.left, b.top - a.top) / 2;
  const zoom = (Math.abs(b.w - a.w) + Math.abs(b.h - a.h)) / 4;
  return { pan, zoom, total: pan + zoom };
};

const FLOOR = 6;
const terminalCovers = (t) => t >= TERMINAL_AT + 400 && t <= TERMINAL_AT + TERMINAL_FOR - 400;

let failed = 0;
console.log(`camera audit — ${FRAMES} frames, ${(FRAMES / FPS).toFixed(2)}s, ${SHOTS.length} shots\n`);
console.log('    at        shot                    pan      zoom     total   cover');

for (const shot of SHOTS) {
  if (shot.at === 0) continue;
  const f = Math.round((shot.at / 1000) * FPS);
  const { pan, zoom, total } = speedAt(f);
  const covered = terminalCovers(shot.at);
  const ok = covered || total >= FLOOR;
  if (!ok) failed++;
  console.log(
    `  ${(shot.at / 1000).toFixed(2)}s   ${shot.src.padEnd(20)}  ${pan.toFixed(1).padStart(6)}  ${zoom
      .toFixed(1)
      .padStart(6)}  ${total.toFixed(1).padStart(6)}   ${covered ? 'scrim' : ok ? 'motion' : 'NONE'}`,
  );
}

// The zoom law is derived, so how many distinct camera moves the film ends up with is an output, not a
// setting. Printing it is how a change to click spacing gets noticed: merging two moves into one, or
// accidentally splitting one into two, is the difference between a take and a slideshow.
const merged = segments.map((s) => `${(s.startMs / 1000).toFixed(2)}–${(s.endMs / 1000).toFixed(2)}s`);
console.log(`\n  camera moves: ${merged.length} — ${merged.join(', ')}`);

const stills = amount.filter((a) => a < 1.001).length;
console.log(`  at rest for ${(stills / FPS).toFixed(1)}s of ${(FRAMES / FPS).toFixed(1)}s`);

if (failed > 0) {
  console.error(`\n  ${failed} swap(s) land with the camera parked — they will read as cuts.`);
  process.exit(1);
}
console.log('\n  every swap is covered.');
