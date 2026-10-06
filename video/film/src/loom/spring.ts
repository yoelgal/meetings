/**
 * A damped-harmonic-oscillator that can be **retargeted mid-flight**, carrying its velocity across
 * each retarget.
 *
 * This is the whole difference between the Apple language in `easing.ts` and the Loom/Screen Studio
 * language. A bezier is a curve over a *known* duration between two *known* endpoints: fine for a
 * title that fades in, useless for a camera that is chasing a cursor which has just changed its mind.
 * Screen Studio and Cap both model the camera and the cursor as springs pulled toward a moving
 * target, which is why their motion feels like it is following something rather than playing back.
 *
 * `remotion`'s own `spring()` cannot do this — verified: it animates a single 0→1 with
 * `{damping: 10, mass: 1, stiffness: 100}` and has no notion of a target that moves — so the solver
 * is here.
 *
 * It is the closed-form solution of `m·x'' + c·x' + k·(x - T) = 0`, not a numerical integrator. Two
 * reasons. It is exact at any step size, so the result does not drift with frame rate. And it is
 * cheap enough to evaluate the entire timeline from t=0 on demand, which is what makes the render
 * deterministic: Remotion renders frames out of order and across several browser processes, and a
 * stateful integrator advanced per frame would give a different answer depending on which frames a
 * given process happened to draw. Seek-identical output is not a nicety here, it is the difference
 * between the preview and the export matching.
 *
 * Parameters are quoted as `stiffness / mass / damping`, matching how Cap's presets are written.
 */

export type SpringConfig = {
  stiffness: number;
  mass: number;
  damping: number;
};

/**
 * A spring specified the way it is actually chosen: how fast it settles, and whether it overshoots.
 *
 * Cap publishes its presets as stiffness/mass/damping, which is the physics but not the intent — you
 * cannot read "settles in half a second, never overshoots" off three numbers like that, and tuning one
 * of them silently changes both properties. Here ω₀ sets the speed and ζ sets the character, and the
 * stiffness and damping fall out.
 *
 * For a critically damped spring (ζ = 1) a step is ~95% done at 4.7/ω₀ seconds, so ω₀ = 15 rad/s
 * settles in about 300ms and ω₀ = 9.4 in about 500ms.
 */
const spring = ({ omega, mass, zeta }: { omega: number; mass: number; zeta: number }): SpringConfig => ({
  stiffness: omega * omega * mass,
  mass,
  damping: zeta * 2 * omega * mass,
});

/**
 * Cursor smoothing: quick, and critically damped.
 *
 * Cap ships ζ ≈ 0.93, which overshoots slightly. On a *recorded* cursor that reads as human, because a
 * real hand does sail past a target and settle back. On a synthesised one it reads as a wobble, because
 * there is no hand to explain it. ζ = 1 keeps the lag that makes it feel physical and removes the ring.
 *
 * ω₀ = 14 rad/s gives about 70ms of lag — enough to feel like weight, little enough that the pointer
 * arrives where it is going rather than gliding after it. Cap's own preset is 12.5 and this sat at 18 for
 * one cut, which read as darting.
 */
export const CURSOR_SPRING: SpringConfig = spring({ omega: 14, mass: 3, zeta: 1 });

/**
 * The camera: snappy, and critically damped.
 *
 * Two separate decisions here, and both were notes from a viewing.
 *
 * ζ = 1 rather than Cap's 0.943 is what stops it looking bouncy. The zoom target is a *step* — 1 straight
 * to 1.75 — and an underdamped spring answering a step necessarily overshoots: the camera pushed past its
 * mark, pulled back and settled, which reads as the frame springing rather than a camera moving. At ζ = 1
 * the approach is monotonic; it arrives and stops. Verified numerically: peak overshoot is one part in
 * 10^15, and the zoom curve has exactly one velocity sign change across a beat.
 *
 * ω₀ = 11 rather than Cap's 9.43 or the 15 an earlier cut used. 15 settled in ~300ms, which was quick
 * enough to read as a snap rather than a move; 11 settles in ~430ms, which is brisk without being jumpy.
 * Faster also costs pan velocity on the release, since the offset saturates against the coverage limit
 * and the card has to slide to stay covering.
 */
export const CAMERA_SPRING: SpringConfig = spring({ omega: 11, mass: 2.25, zeta: 1 });

/** Position and velocity after `dt` seconds of chasing `target` from `(x, v)`. */
const advance = (
  x: number,
  v: number,
  target: number,
  dt: number,
  { stiffness, mass, damping }: SpringConfig,
): [number, number] => {
  const omega = Math.sqrt(stiffness / mass);
  const zeta = damping / (2 * Math.sqrt(stiffness * mass));
  // Displacement from the target, which is the quantity that actually decays.
  const d = x - target;

  // Near-critical is its own branch, and the tolerance is not defensive padding: at ζ within a
  // rounding error of 1 the underdamped form divides by ωd ≈ 0 and the overdamped form divides by
  // r2 - r1 ≈ 0, so both degenerate. Both presets here are deliberately ζ = 1.
  if (Math.abs(zeta - 1) < 1e-9) {
    const decay = Math.exp(-omega * dt);
    const c2 = v + omega * d;
    return [target + decay * (d + c2 * dt), decay * (c2 - omega * (d + c2 * dt))];
  }

  if (zeta < 1) {
    const wd = omega * Math.sqrt(1 - zeta * zeta);
    const decay = Math.exp(-zeta * omega * dt);
    const c1 = d;
    const c2 = (v + zeta * omega * d) / wd;
    const cos = Math.cos(wd * dt);
    const sin = Math.sin(wd * dt);
    return [
      target + decay * (c1 * cos + c2 * sin),
      decay * ((c2 * wd - zeta * omega * c1) * cos - (c1 * wd + zeta * omega * c2) * sin),
    ];
  }

  const root = omega * Math.sqrt(zeta * zeta - 1);
  const r1 = -zeta * omega + root;
  const r2 = -zeta * omega - root;
  const c2 = (v - r1 * d) / (r2 - r1);
  const c1 = d - c2;
  const e1 = Math.exp(r1 * dt);
  const e2 = Math.exp(r2 * dt);
  return [target + c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2];
};

/** The retarget interval. Cap re-aims every 8 ms; finer changes nothing a frame can show. */
const STEP_SECONDS = 0.008;

/**
 * Runs a spring against a target function for `frames` frames and returns its value at each one.
 *
 * `target(timeSeconds)` is sampled on the 8 ms grid rather than per frame, so a target that jumps
 * between two frames still gets the spring moving at the moment it jumped.
 */
export const simulate = ({
  target,
  frames,
  fps,
  config,
  initial,
}: {
  target: (seconds: number) => number;
  frames: number;
  fps: number;
  config: SpringConfig;
  /** Where the spring starts. Defaults to wherever the target is at t=0, i.e. already settled. */
  initial?: number;
}): Float64Array => {
  const out = new Float64Array(frames);
  let x = initial ?? target(0);
  let v = 0;
  let t = 0;

  for (let frame = 0; frame < frames; frame++) {
    const frameTime = frame / fps;
    // Catch the simulation up to this frame's instant, one 8 ms retarget at a time.
    while (t + STEP_SECONDS <= frameTime) {
      [x, v] = advance(x, v, target(t), STEP_SECONDS, config);
      t += STEP_SECONDS;
    }
    // The sub-step remainder is evaluated but never committed. Committing it would leave the next
    // full step starting from a fractional offset, and the 8 ms retarget grid would slowly drift out
    // of phase with the target function.
    out[frame] = frameTime > t ? advance(x, v, target(t), frameTime - t, config)[0] : x;
  }
  return out;
};
