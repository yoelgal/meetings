import { FPS } from '../theme';

/**
 * The authored pointer track, and the zoom law derived from it.
 *
 * One list drives three things — where the cursor is drawn, when it punches for a click, and where and
 * how far the camera zooms. That is deliberate: in Screen Studio and Cap the zoom is *computed from*
 * the recorded pointer, never authored beside it, which is why their zooms always land on the thing
 * that was clicked. Authoring the two separately is how you get a demo whose camera pushes in next to
 * the button.
 *
 * Coordinates are fractions of the **window image**, not of the frame, so a point stays on the same
 * control no matter how the shot is framed or how far the camera has pushed in.
 */
export type Pointer = {
  /** Milliseconds from the start of this beat. */
  t: number;
  /** 0..1 across the window image. */
  x: number;
  /** 0..1 down the window image. */
  y: number;
  /** A mouse-down at this keyframe. Drives the click punch and opens a zoom segment. */
  click?: boolean;
  /** A shortcut pressed here, rendered as a floating pill. */
  keys?: string;
};

// MARK: - Cap's zoom law, as measured from its source

/**
 * How far the camera pushes in.
 *
 * Cap ships `DEFAULT_AUTO_ZOOM_AMOUNT = 2.0`, but that figure is relative to a recording that fills the
 * frame — and the number here has to be re-derived every time the card's resting size changes, which is
 * the mistake this constant already caused once.
 *
 * The card is 1832px wide at rest in a 1920px frame. At 1.75 it renders 3206px wide, which is *1:1 with
 * the 2x capture* — the app displayed at its true retina size, showing 54% of a 1600pt window. That looks
 * like a crop of a screenshot, not a camera: the app's 13pt text renders 13px tall and a cross-dissolve
 * between two window states ghosts as two readable layouts on top of each other.
 *
 * 1.42 shows ~68% of the window and renders that text at ~10px — larger than at rest, comfortably
 * readable at 1080p, and still recognisably the same app rather than a detail of it. It also costs less
 * pan velocity on the release, because the offset saturates against the limit that keeps the card
 * covering the frame and the card has to slide to stay covering.
 */
export const ZOOM_AMOUNT = 1.42;
/** A zoom starts before the click that caused it, so the camera is already moving on mouse-down. */
const LEAD_MS = 300;
/** And holds well after, because the result of a click is the thing worth looking at. */
const TAIL_MS = 2500;
/**
 * Two segments closer than this become one hold rather than a zoom out and straight back in.
 *
 * Cap ships 2500ms. With `LEAD_MS` and `TAIL_MS` either side, that merges any two clicks less than 5.3
 * seconds apart — which is right for a recording of real work, where a pump between two nearby clicks is
 * a fault, and wrong for a thirty-second film with six features in it. At Cap's figure every click in
 * this demo merged into a single unbroken hold, and the camera never came back out.
 *
 * It has to come back out, for a reason Cap never faces: this film changes its window's *picture* five
 * times, and the only place a change of picture is invisible is while the camera is pulling back and the
 * whole image is rapidly shrinking. Cap is recording one continuous session and has nothing to hide.
 *
 * 900ms keeps the merge where it earns its keep — clicks within about 3.7s, which is inside one feature —
 * and releases between features.
 */
const MERGE_GAP_MS = 900;

/** A span of time during which the camera is zoomed in. Where it looks is decided by `focusAt`. */
export type ZoomSegment = { startMs: number; endMs: number };

/**
 * Turns clicks into zoom spans, merging any that would otherwise pump.
 *
 * The merge is the important part. Two clicks 1.5s apart, each with a 2.5s tail, would zoom out and
 * straight back in between them — which reads as a camera fault rather than as a camera. Merged, the
 * zoom simply stays in, and the pan between the two targets falls out of the centre spring following the
 * pointer. That is why a segment carries no coordinates: a merged span covers two different targets and
 * could only ever store one of them.
 */
export const zoomSegments = (track: Pointer[], durationMs: number): ZoomSegment[] => {
  const segments: ZoomSegment[] = [];

  for (const click of track.filter((p) => p.click)) {
    const start = Math.max(1, click.t - LEAD_MS);
    // Cap clamps the end 800ms before the recording finishes, so a zoom is never still running when
    // the picture stops.
    const end = Math.min(click.t + TAIL_MS, durationMs - 800);
    if (end <= start) continue;

    const previous = segments[segments.length - 1];
    if (previous && start - previous.endMs <= MERGE_GAP_MS) {
      previous.endMs = Math.max(previous.endMs, end);
      continue;
    }
    segments.push({ startMs: start, endMs: end });
  }
  return segments;
};

/** The zoom factor the camera is being asked for at a given moment: 1 when idle, 2 inside a segment. */
export const zoomTargetAt = (segments: ZoomSegment[], ms: number): number =>
  segments.some((s) => ms >= s.startMs && ms <= s.endMs) ? ZOOM_AMOUNT : 1;

/**
 * The pointer's position between keyframes, eased rather than linear.
 *
 * This is the spring's *target*, and the easing matters even though a spring follows it. A linear path
 * has a velocity discontinuity at every keyframe: the target is stationary, then instantly moving at
 * full speed, then instantly stationary again. A critically damped spring answers each of those with a
 * small jerk, and a track with six keyframes therefore had six of them — which is most of what read as
 * jitter in the camera. Smoothstep makes the target's velocity zero at both ends of every leg, so there
 * is nothing sudden left for the spring to answer, and the pointer accelerates and decelerates the way a
 * hand does.
 *
 * There is no separate camera path: the camera springs after this same function, with a much slower
 * spring, which is why the two never disagree about where the interesting thing is.
 */
export const pointerAt = (track: Pointer[], ms: number): { x: number; y: number } => {
  if (track.length === 0) return { x: 0.5, y: 0.5 };
  if (ms <= track[0].t) return { x: track[0].x, y: track[0].y };
  const last = track[track.length - 1];
  if (ms >= last.t) return { x: last.x, y: last.y };

  for (let i = 1; i < track.length; i++) {
    const a = track[i - 1];
    const b = track[i];
    if (ms <= b.t) {
      const span = b.t - a.t;
      const k = span === 0 ? 1 : smoothstep((ms - a.t) / span);
      return { x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k };
    }
  }
  return { x: last.x, y: last.y };
};

/**
 * How hard the cursor is pressed at a given moment, 1 = at rest, 0.8 = fully down.
 *
 * Cap has no expanding ripple on click — that is a Keynote affectation. What it has is a scale punch:
 * the cursor shrinks to 0.8 over the 130 ms *before* the button goes down, holds, and comes back over
 * the 130 ms after. Because it anticipates, the press reads as intentional rather than as a reaction.
 */
const CLICK_MS = 130;
const CLICK_SCALE = 0.8;

export const clickScaleAt = (track: Pointer[], ms: number): number => {
  let scale = 1;
  for (const point of track) {
    if (!point.click) continue;
    const delta = ms - point.t;
    if (delta >= -CLICK_MS && delta < 0) {
      // Squeezing down. smoothstep, so it does not start or stop abruptly.
      scale = Math.min(scale, 1 - (1 - CLICK_SCALE) * smoothstep(1 + delta / CLICK_MS));
    } else if (delta >= 0 && delta <= CLICK_MS) {
      scale = Math.min(scale, CLICK_SCALE + (1 - CLICK_SCALE) * smoothstep(delta / CLICK_MS));
    }
  }
  return scale;
};

export const smoothstep = (t: number): number => {
  const k = Math.max(0, Math.min(1, t));
  return k * k * (3 - 2 * k);
};

/** Frames → milliseconds, for talking to a track from inside a component. */
export const msAt = (frame: number): number => (frame / FPS) * 1000;
