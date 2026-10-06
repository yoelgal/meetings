import type { Pointer } from './loom/track';
import { FPS } from './theme';

/**
 * The whole demo as data: what the window shows, where the pointer goes, and when the two overlays open.
 *
 * Kept out of `Demo.tsx` and free of JSX on purpose. Every zoom in this film is *derived* from the clicks
 * in `TRACK` (see `loom/track.ts`), which makes the camera an emergent property of this file rather than
 * something authored — and an emergent camera has to be measurable, or "the swap is hidden by the motion"
 * is just a claim. `scripts/audit-camera.mjs` imports this module directly and prints the camera's speed
 * at each swap, which is only possible because there is nothing to render in here.
 */

/**
 * One window state, and when it takes over.
 *
 * The app's poses are applied at launch — `MEETINGS_SCOPE` and friends are read once — and this repo
 * refuses to synthesise the clicks that would navigate a running instance (see `video/README.md`). So a
 * literal single take across six different views is not available, and no amount of wanting it makes it
 * so.
 *
 * What *is* available: change the picture while the camera is moving fastest. A 400ms dissolve between two
 * window states, landing mid-move, is not perceptible as an edit — the eye is tracking the motion, and
 * every frame of the dissolve has the same window chrome in the same place at the same scale. The cut is
 * hidden by the camera rather than smoothed over with a transition.
 *
 * `at` is therefore not a beat boundary. It is a *hiding place*, and picking a bad one — a moment when the
 * camera happens to be still — is what makes a swap show.
 */
export type Shot = {
  /** Milliseconds from the start of the demo at which this shot begins taking over. */
  at: number;
  /** A still or clip under public/. */
  src: string;
  /** Clip-only: where in the source to start, in source frames. */
  trimBefore?: number;
};
/**
 * Where the window's picture changes.
 *
 * Every one of these sits in a *release* — the ~600ms while the camera is pulling back out of a zoom and
 * the whole image is shrinking fast. That is the only place a change of picture is genuinely invisible.
 * Two earlier attempts got this wrong in instructive ways: swapping while the camera was parked showed as
 * a plain dissolve, and swapping mid-pan while zoomed showed as two readable text layouts ghosted over
 * each other, because at that zoom the app is rendered near 1:1.
 *
 * `audit-camera.mjs` measures the cover at each of these and fails the render if it is not there.
 */
export const SHOTS: Shot[] = [
  // The library: a Mac full of meetings, one of them written up.
  { at: 0, src: 'shots/library.png' },

  // Recording, with the transcript arriving line by line. Trimmed a second in, past the app settling.
  { at: 3850, src: 'clips/live.mov', trimBefore: 60 },

  // The write-up landing, swapped in behind the terminal's scrim — the one change of picture that needs no
  // camera cover at all, because the card over it is opaque. The clip's summary lands about three seconds
  // in, which is well after the terminal has gone: the command is seen to run, then its effect arrives.
  { at: 13400, src: 'clips/writeup.mov' },

  // Search. `⌘K` shows 150ms before this, so the dissolve is doing the palette's own open animation.
  { at: 19700, src: 'shots/search.png' },

  // Tomorrow's meeting, prepared.
  { at: 23600, src: 'shots/upcoming.png' },
];

/**
 * One pointer path for the whole demo — and therefore one camera.
 *
 * Click spacing is the only control over how the camera behaves, because the zoom is derived. Two clicks
 * within ~3.7s merge into one held zoom that pans between them; two further apart get a release in
 * between. So the rhythm below is deliberate: clicks are bunched *inside* a feature to hold the zoom on
 * it, and spread *between* features to make the camera come back out — which is both the film's breathing
 * and the only hiding place its shot swaps have.
 *
 * The camera is at rest only twice: for the five seconds the terminal is open in front of the app, because
 * a moving desk behind a static card looks broken, and under the closing card.
 *
 * Coordinates are fractions of the 1600x900pt window: sidebar to x 0.11, meeting list 0.14–0.32, detail
 * pane 0.33–0.66, notes pane 0.67–0.99, transport bar at y 0.97.
 */
export const TRACK: Pointer[] = [
  // --- the library. One click, so the camera holds 1.0s → 3.7s and then releases.
  { t: 0, x: 0.54, y: 0.62 },
  { t: 900, x: 0.24, y: 0.3 },
  { t: 1200, x: 0.24, y: 0.3, click: true },
  { t: 3300, x: 0.3, y: 0.42 },

  // --- recording. Three clicks 2.2s apart, which merge into one 5s hold: down to the transport, then up
  // to the transcript as the lines arrive.
  { t: 4400, x: 0.42, y: 0.92 },
  { t: 5000, x: 0.42, y: 0.92, click: true },
  { t: 6600, x: 0.48, y: 0.17 },
  { t: 7200, x: 0.48, y: 0.17, click: true },
  { t: 9400, x: 0.5, y: 0.21, click: true },

  // --- the terminal is up from 10.2s to 14.0s. The pointer parks low, below the card, and the camera
  // settles to rest on its own because the next click is 5s away.
  { t: 11000, x: 0.5, y: 0.9 },

  // --- the write-up landing. Two clicks, merged, holding across the moment it appears.
  { t: 14300, x: 0.5, y: 0.36 },
  { t: 14800, x: 0.5, y: 0.36, click: true },
  { t: 17000, x: 0.53, y: 0.4, click: true },

  // --- search. `⌘K` at 19.55s, the palette dissolves in at 19.7s while the camera is wide, and the
  // pointer is already on its way down into the results.
  { t: 19550, x: 0.52, y: 0.44, keys: '⌘K' },
  { t: 20500, x: 0.5, y: 0.36 },
  { t: 20900, x: 0.5, y: 0.36, click: true },

  // --- tomorrow's meeting.
  { t: 24300, x: 0.34, y: 0.24 },
  { t: 24800, x: 0.34, y: 0.24, click: true },
  { t: 26200, x: 0.46, y: 0.5 },
  { t: 27400, x: 0.5, y: 0.54 },
];

/** Milliseconds to frames. */
export const ms = (value: number) => Math.round((value / 1000) * FPS);

/**
 * The terminal opens in front of the app, and closes again. The app never leaves.
 *
 * It also does a structural job: the write-up clip is swapped in behind it at 13.4s, under an opaque
 * scrim, so the one shot change the camera cannot cover is covered by the overlay instead.
 */
export const TERMINAL_AT = 10200;
export const TERMINAL_FOR = 3800;

/** The closing card fades up over the running demo rather than cutting to it. */
export const CLOSING_AT = 27000;
export const CLOSING_FOR = 2900;

export const DEMO_FRAMES = ms(CLOSING_AT + CLOSING_FOR);
