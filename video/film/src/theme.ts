/**
 * The demo's constants.
 *
 * Deliberately small. An earlier cut of this project was an Apple-style launch film and carried a whole
 * type scale, a colour system and a signature easing curve; a Loom-style screen demo needs almost none
 * of that, because the app's own interface is doing the design work and the only type on screen is one
 * caption per beat. What is left is the frame rate, the shadow that floats the window, and the reason
 * the shadow is built the way it is.
 */

/** 60fps, because the source clips are 60fps and the cursor spring is sampled per frame. */
export const FPS = 60;

/** Seconds to frames. Every duration in `Demo.tsx` is written in seconds and converted here. */
export const sec = (seconds: number) => Math.round(seconds * FPS);

/**
 * The floating-window shadow.
 *
 * Three layers, because one shadow reads as a sticker: a tight contact shadow grounds the window, a mid
 * layer gives it thickness, and a very large soft layer is what actually sells the float. The numbers
 * follow Cap's shadow defaults at 1080p — roughly 114px of spread and 30px of blur at half opacity —
 * split across the three layers rather than applied as a single signed-distance falloff.
 *
 * Applied as `drop-shadow`, never `box-shadow`: the captures carry the window's real rounded corners as
 * alpha, and `box-shadow` follows the element's rectangular box, so it would paint shadow into the
 * transparent corners.
 */
export const WINDOW_SHADOW = [
  '0 2px 10px rgba(0,0,0,0.30)',
  '0 26px 70px rgba(0,0,0,0.46)',
  '0 70px 170px rgba(0,0,0,0.52)',
].join(', ');
