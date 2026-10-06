import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame } from 'remotion';
import { INTER } from '../fonts';
import { FPS } from '../theme';
import { smoothstep } from './track';

/**
 * The closing card: the mark, and the name beside it. The README banner, held for three seconds.
 *
 * Deliberately just those two things. An earlier cut stacked the app icon over the name over a tagline
 * over an availability line — four staggered reveals, which is a slide, not a sign-off. The banner is
 * already the answer to "what is this called", it is the artwork the project actually uses, and matching
 * it means the demo ends somewhere the reader has already been.
 *
 * `brand/logo.png` is the repo's own mark, copied in by `shoot.sh` rather than redrawn. It is opaque —
 * a baked navy background with the bloom painted into it — so it is composited with `screen`, which drops
 * everything darker than the card and keeps the glow. That is why the card fades to near-black first: on
 * the demo's bright wallpaper, `screen` would wash the mark out completely.
 */
const MARK = 470;
const TYPE = 128;

export const Closing: React.FC<{ durationInFrames: number }> = ({ durationInFrames }) => {
  const frame = useCurrentFrame();

  // The hero entrance: opacity finishing before the geometry does, and a scale that only ever shrinks
  // toward 1, so nothing ever overshoots its final size.
  const reveal = (delay: number) => {
    const t = frame - delay;
    const duration = Math.round(1.1 * FPS);
    const appear = interpolate(t, [0, duration * 0.7], [0, 1], {
      easing: smoothstep,
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
    });
    const settle = interpolate(t, [0, duration], [0, 1], {
      easing: smoothstep,
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
    });
    return {
      opacity: appear,
      transform: `scale(${(1.05 - 0.05 * settle).toFixed(4)})`,
      willChange: 'opacity, transform',
    };
  };

  // The card fades as one rather than line by line. A staggered exit reads as cheap every time.
  const out = interpolate(frame, [durationInFrames - Math.round(0.5 * FPS), durationInFrames], [1, 0], {
    easing: smoothstep,
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  // The veil takes the bright wallpaper down to the banner's own near-black navy. It has to reach full
  // opacity, not 93%: `screen` over even a little residual lavender lifts the mark's baked background
  // into a visible square around it.
  const veil = interpolate(frame, [0, Math.round(0.6 * FPS)], [0, 1], {
    easing: smoothstep,
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', opacity: out }}>
      <AbsoluteFill
        style={{
          opacity: veil,
          background: 'radial-gradient(ellipse 90% 120% at 50% 50%, #100d33 0%, #05041a 62%, #02030f 100%)',
        }}
      />

      <div style={{ display: 'flex', alignItems: 'center' }}>
        <Img
          src={staticFile('brand/logo.png')}
          style={{
            ...reveal(0),
            width: MARK,
            height: MARK,
            marginRight: -22,
            mixBlendMode: 'screen',
            // `screen` alone is not enough, and measuring the source is what showed why. The mark's own
            // bloom runs off the edge of the square it is drawn in — the four corners read #01032d, but
            // the middle of the top edge reads #250c67 — so the image has a bright, hard border, and
            // screening it over the card put a visible rectangle around the mark.
            //
            // The mark itself reaches about 52% of the way to a corner. So: opaque out to 50%, faded to
            // nothing by 76%, which keeps every pixel of the artwork and lets the clipped glow fall off
            // the way it would have if the canvas had been bigger.
            maskImage: 'radial-gradient(circle at 50% 50%, #000 50%, transparent 76%)',
            WebkitMaskImage: 'radial-gradient(circle at 50% 50%, #000 50%, transparent 76%)',
          }}
        />

        <div
          style={{
            ...reveal(Math.round(0.18 * FPS)),
            fontFamily: INTER,
            fontSize: TYPE,
            fontWeight: 600,
            // Tracking goes more negative as size goes up — Apple's own rule, and -0.019em at 128px is -2.4px.
            letterSpacing: -0.019 * TYPE,
            color: '#ffffff',
          }}
        >
          Meetings
        </div>
      </div>
    </AbsoluteFill>
  );
};
