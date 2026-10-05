import { AbsoluteFill, Sequence } from 'remotion';
import { ensureFonts } from './fonts';
import { Closing } from './loom/Closing';
import { LoomStage } from './loom/LoomStage';
import { Terminal } from './loom/Terminal';
import {
  CLOSING_AT,
  CLOSING_FOR,
  DEMO_FRAMES,
  ms,
  SHOTS,
  TERMINAL_AT,
  TERMINAL_FOR,
  TRACK,
} from './plan';

/**
 * The demo, in under thirty seconds, as one continuous shot.
 *
 * There is no beat sheet here any more, and that is the point. The first version of this file was a list
 * of seven beats, each with its own camera, cut together — and it read as seven clips no matter how the
 * transitions were handled, because the camera came to a halt seven times. The reference it is built
 * against never stops moving and never cuts: one take, one camera, the picture changing while the camera
 * is mid-move.
 *
 * So what is left here is only the assembly. The demo itself — window states, pointer path, overlay
 * timings — is data in `plan.ts`, which is also what lets `scripts/audit-camera.mjs` check that every
 * change of picture happens while the camera is moving.
 *
 * There are no captions, and that is also deliberate. Seven labels appearing and disappearing was the
 * other half of what made this read as a slideshow: each one drew a boundary around its beat and told the
 * viewer which of six views of the same app they were now looking at. The app is legible without them.
 */
export { DEMO_FRAMES };

export const Demo: React.FC = () => {
  ensureFonts();

  return (
    <AbsoluteFill style={{ backgroundColor: '#8b90f0' }}>
      <Backdrop />

      {/* One stage, running the whole length of the demo — including underneath the closing card, which
          fades up over it rather than replacing it. */}
      <LoomStage shots={SHOTS} track={TRACK} durationInFrames={DEMO_FRAMES} />

      <Sequence from={ms(TERMINAL_AT)} durationInFrames={ms(TERMINAL_FOR)} name="terminal">
        <Terminal durationInFrames={ms(TERMINAL_FOR)} />
      </Sequence>

      <Sequence from={ms(CLOSING_AT)} durationInFrames={ms(CLOSING_FOR)} name="closing">
        <Closing durationInFrames={ms(CLOSING_FOR)} />
      </Sequence>
    </AbsoluteFill>
  );
};

/**
 * A bright wallpaper, held still for the whole demo.
 *
 * Sampled from the reference rather than invented: its corners read `#f7eaca`, `#8489fe`, `#87bffb` and
 * `#a9abf8`, which is a warm-to-cool wash, not the near-black an earlier cut used. That change mattered
 * more than any other single one. A dark app window on a dark backdrop has nothing to sit on, and the
 * padding around it reads as a mistake rather than as a frame; on a lit surround the same window reads as
 * a photograph of a screen.
 *
 * A gradient rather than the real desktop wallpaper, because a wallpaper is the operator's and this demo
 * carries nothing of theirs. Held perfectly still on purpose: a backdrop that moves competes with a
 * camera that is already moving.
 *
 * The grain is not styling. A gradient across 1920px at 8 bits per channel steps roughly once every 90
 * pixels and shows visible rings, and H.264's deblocking filter flattens smooth gradients into bands. A
 * couple of per cent of noise dithers the quantisation away for a few hundred kilobits.
 */
const Backdrop: React.FC = () => (
  <>
    <AbsoluteFill style={{ background: 'linear-gradient(148deg, #b9bdf7 0%, #8f95f2 45%, #7fb6f5 100%)' }} />
    <AbsoluteFill
      style={{
        background: 'radial-gradient(ellipse 62% 58% at 4% 2%, #f7eaca 0%, rgba(247,234,202,0) 68%)',
      }}
    />
    <AbsoluteFill
      style={{
        background: 'radial-gradient(ellipse 55% 50% at 97% 6%, #8489fe 0%, rgba(132,137,254,0) 70%)',
      }}
    />
    <AbsoluteFill
      style={{
        background: 'radial-gradient(ellipse 60% 55% at 92% 98%, #87bffb 0%, rgba(135,191,251,0) 72%)',
      }}
    />
    <AbsoluteFill
      style={{
        opacity: 0.03,
        mixBlendMode: 'overlay',
        backgroundImage: `url("${GRAIN}")`,
        pointerEvents: 'none',
      }}
    />
  </>
);

const GRAIN =
  'data:image/svg+xml;utf8,' +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="320">' +
      '<filter id="n"><feTurbulence type="fractalNoise" baseFrequency="0.8" numOctaves="3" ' +
      'stitchTiles="stitch"/></filter><rect width="100%" height="100%" filter="url(#n)"/></svg>',
  );
