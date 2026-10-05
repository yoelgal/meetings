import { useMemo } from 'react';
import { AbsoluteFill, interpolate, Sequence, useCurrentFrame } from 'remotion';
import type { Shot } from '../plan';
import { AppWindow } from '../components/AppWindow';
import { FPS, sec } from '../theme';
import { Cursor } from './Cursor';
import { KeyPill } from './KeyPill';
import { CAMERA_SPRING, CURSOR_SPRING, simulate } from './spring';
import {
  clickScaleAt,
  msAt,
  pointerAt,
  smoothstep,
  zoomSegments,
  zoomTargetAt,
  type Pointer,
} from './track';

/**
 * The whole demo's stage: one window card on the backdrop, one camera, one drawn cursor — running
 * unbroken from the first frame to the last.
 *
 * This used to be a per-beat component, seven of them cut together. It is one now, and that is the
 * single biggest change in the demo. The reference it is built against is one continuous take: a
 * scene-change detector finds nothing at all across its forty seconds. Cutting between beats — even
 * cross-dissolving between them — kept reading as a slideshow, because every beat reset the camera to
 * rest, so the motion stopped seven times.
 *
 * Here the camera is solved *once* over the full duration. It never returns to rest between beats, and
 * the window's *contents* change underneath it while it is moving. See `Shot` for why that is enough to
 * pass for a single take even though the app cannot actually be driven through seven states in one
 * recording.
 *
 * Everything below shares one coordinate system: pointer keyframes are fractions of the *window image*,
 * so the cursor, the click punch and the zoom focus cannot drift apart from each other or from the UI,
 * at any zoom level.
 */

/**
 * The card at rest: 44px of padding on every side, which is a *sliver* rather than a margin.
 *
 * Measured off the reference rather than chosen. An earlier cut used a 1312px card in a 1920px frame —
 * 300px of backdrop down each side — and next to the reference it looked like a screenshot pasted onto a
 * slide. The reference's window is ~96% of frame width. Capturing at 1600x900 rather than 1440x900 is
 * what makes that sit evenly: 16:9 matches the frame, so the padding is the same on all four sides.
 */
const PADDING = 44;
const CARD_W = 1920 - PADDING * 2;
const CARD_H = CARD_W * (900 / 1600);

/**
 * How long one window state dissolves into the next, and how hard the picture blurs while it does.
 *
 * 300ms rather than Cap's 400: at 400 the halfway frame of a swap held two readable layouts on top of
 * each other for long enough to see. Rendering those midpoints out and looking at them is what settled
 * this — the fast zoom-out covering the swap is necessary but, on its own, was not sufficient.
 *
 * The blur is what makes it sufficient. It ramps 0 → 11px → 0 across the dissolve, so at the midpoint —
 * exactly where both layers are at half opacity — neither is legible as text, and what the eye gets is a
 * smear during a fast camera move. That is also the honest artefact: the camera is collapsing the picture
 * by 30-40px per frame through these moments, and a real lens would blur.
 */
const SWAP = sec(0.3);
const SWAP_BLUR = 11;

export const LoomStage: React.FC<{
  shots: Shot[];
  /** Pointer keyframes for the whole demo, in milliseconds from its first frame. */
  track: Pointer[];
  durationInFrames: number;
}> = ({ shots, track, durationInFrames }) => {
  const frame = useCurrentFrame();
  const durationMs = (durationInFrames / FPS) * 1000;

  // Simulated once for the whole demo and cached, not per frame and not per beat. The timeline is solved
  // from t=0 so the result is identical no matter which frame a given render process happens to draw
  // first — Remotion renders out of order and across processes, and a spring advanced statefully per
  // frame would give a different answer in the export than in the preview.
  const motion = useMemo(() => {
    const segments = zoomSegments(track, durationMs);
    const common = { frames: durationInFrames, fps: FPS };
    return {
      amount: simulate({
        ...common,
        config: CAMERA_SPRING,
        target: (s) => zoomTargetAt(segments, s * 1000),
        initial: 1,
      }),
      focusX: simulate({ ...common, config: CAMERA_SPRING, target: (s) => pointerAt(track, s * 1000).x }),
      focusY: simulate({ ...common, config: CAMERA_SPRING, target: (s) => pointerAt(track, s * 1000).y }),
      cursorX: simulate({ ...common, config: CURSOR_SPRING, target: (s) => pointerAt(track, s * 1000).x }),
      cursorY: simulate({ ...common, config: CURSOR_SPRING, target: (s) => pointerAt(track, s * 1000).y }),
    };
  }, [track, durationInFrames, durationMs]);

  const index = Math.min(frame, durationInFrames - 1);
  const amount = motion.amount[index];
  const w = CARD_W * amount;
  const h = CARD_H * amount;

  // Where the camera looks, as an offset from frame centre.
  //
  // The offset is limited to exactly how far the card can move before an edge of it would come inside
  // the frame — `(w - 1920) / 2`, which is zero while the card is narrower than the frame and grows
  // continuously from there. That limit *is* the framing logic, and expressing it this way removes two
  // problems an earlier cut had.
  //
  // It was previously a branch: clamp to the cover range if the card covered that axis, otherwise pin to
  // centre. The card is 1.78:1 in a 1.778:1 frame now, so both axes cross together — but when it was
  // 1.6:1 it covered vertically at 1.32x and horizontally only at 1.46x, and in between the vertical was
  // focus-tracked while the horizontal was pinned. That showed a full-height card with a lit sliver of
  // backdrop down one side, and crossing the second threshold snapped the vertical by up to 60px in a
  // single frame. Both read as jitter. The continuous form cannot do either, at any aspect.
  const offsetX = clamp((0.5 - motion.focusX[index]) * w, -Math.max(0, (w - 1920) / 2), Math.max(0, (w - 1920) / 2));
  const offsetY = clamp((0.5 - motion.focusY[index]) * h, -Math.max(0, (h - 1080) / 2), Math.max(0, (h - 1080) / 2));
  const left = 960 + offsetX - w / 2;
  const top = 540 + offsetY - h / 2;

  const ms = msAt(frame);
  const cursor = {
    x: left + motion.cursorX[index] * w,
    y: top + motion.cursorY[index] * h,
  };
  const key = activeKey(track, ms);
  // A half-sine across each dissolve: nothing at its edges, everything at its midpoint. `max` rather than
  // a sum because two swaps never overlap, and taking the max means adding one that did could not stack
  // into a blur nobody asked for.
  const blur =
    SWAP_BLUR *
    shots.reduce((peak, shot) => {
      if (shot.at === 0) return peak;
      const t = (frame - Math.round((shot.at / 1000) * FPS)) / SWAP;
      return t <= 0 || t >= 1 ? peak : Math.max(peak, Math.sin(Math.PI * t));
    }, 0);


  return (
    <AbsoluteFill>
      {/* A soft pool of light under the card, tracking its rect. The reference sits its window on a bright
          wallpaper, and what sells "on a desk" rather than "pasted on" is that the surround is lit *by*
          the window's position. Drawn behind, inset negatively so it reads as spill rather than a border. */}
      <div
        style={{
          position: 'absolute',
          left: left - 90,
          top: top - 90,
          width: w + 180,
          height: h + 180,
          borderRadius: 60,
          background: 'radial-gradient(ellipse at 50% 50%, rgba(255,255,255,0.30), rgba(255,255,255,0) 72%)',
          filter: 'blur(38px)',
          pointerEvents: 'none',
        }}
      />

      {/* The window, scaled and slid by the camera. `left`/`top` rather than a transform so the cursor can
          be positioned against exactly the same numbers.

          Every shot lives in this one rect, so a swap changes only which picture is inside it — the chrome
          stays exactly where it was, at exactly the scale it was, which is what lets the dissolve hide. */}
      <div
        style={{
          position: 'absolute',
          left,
          top,
          width: w,
          height: h,
          filter: blur > 0.05 ? `blur(${blur.toFixed(2)}px)` : undefined,
          willChange: 'filter',
        }}
      >
        {shots.map((shot, i) => {
          const from = Math.round((shot.at / 1000) * FPS);
          const next = shots[i + 1];
          // Held until the *next* shot has finished fading up, then unmounted. Clips are mounted inside
          // their own Sequence so their playback clock starts when they appear rather than at frame 0 of
          // the demo — a 12s clip mounted for the whole 30s would be long finished by the time it showed.
          const until = next ? Math.round((next.at / 1000) * FPS) + SWAP : durationInFrames;
          return (
            <Sequence
              key={`${shot.src}-${shot.at}`}
              from={from}
              durationInFrames={Math.max(1, until - from)}
              layout="none"
            >
              <Swap fade={i === 0 ? 0 : SWAP}>
                <AppWindow src={shot.src} width={w} trimBefore={shot.trimBefore} />
              </Swap>
            </Sequence>
          );
        })}
      </div>

      <Cursor
        x={cursor.x}
        y={cursor.y}
        // Grows with the zoom, so it stays the same size relative to the UI it points at. 58px is about
        // 2.1x the macOS arrow as rendered at this card size — Screen Studio and Cap both enlarge the
        // cursor, because a 1:1 pointer is nearly invisible in a downscaled recording, but Cap's 60px
        // assumes a full-frame capture and past roughly this the arrow starts covering its own target.
        height={58 * amount}
        scale={clickScaleAt(track, ms)}
      />

      {key ? <KeyPill keys={key.keys} progress={key.progress} leaving={key.leaving} /> : null}
    </AbsoluteFill>
  );
};

/**
 * One window state fading up over the one before it.
 *
 * Later shots render later in the tree, so they are already on top: fading the newcomer in *is* the
 * dissolve, and the outgoing shot needs no exit animation of its own.
 */
const Swap: React.FC<{ fade: number; children: React.ReactNode }> = ({ fade, children }) => {
  const frame = useCurrentFrame();
  const opacity = fade === 0 ? 1 : interpolate(frame, [0, fade], [0, 1], {
    easing: smoothstep,
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  return <div style={{ position: 'absolute', inset: 0, opacity }}>{children}</div>;
};

const clamp = (value: number, lo: number, hi: number) => Math.min(Math.max(value, lo), hi);

/** Cap's 150ms in/out; held for 900ms between, which is long enough to read `⌘K` and no longer. */
const KEY_FADE_MS = 150;
const KEY_HOLD_MS = 900;

const activeKey = (track: Pointer[], ms: number) => {
  for (const point of track) {
    if (!point.keys) continue;
    const since = ms - point.t;
    if (since < 0 || since > KEY_FADE_MS + KEY_HOLD_MS + KEY_FADE_MS) continue;
    if (since < KEY_FADE_MS) {
      return { keys: point.keys, progress: smoothstep(since / KEY_FADE_MS), leaving: false };
    }
    if (since < KEY_FADE_MS + KEY_HOLD_MS) return { keys: point.keys, progress: 1, leaving: false };
    return {
      keys: point.keys,
      progress: smoothstep(1 - (since - KEY_FADE_MS - KEY_HOLD_MS) / KEY_FADE_MS),
      leaving: true,
    };
  }
  return null;
};
