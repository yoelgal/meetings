import { AbsoluteFill, interpolate, useCurrentFrame } from 'remotion';
import session from '../cli/session.json';
import { MONO } from '../fonts';
import { FPS, WINDOW_SHADOW } from '../theme';
import { smoothstep } from './track';

type Step = { command: string; output: string };
const STEPS = session as Step[];

/**
 * The agent's half of the product: a real `meetings` session, typed on screen.
 *
 * Every command and every line of output in `src/cli/session.json` was captured by `video/shoot.sh`
 * running those commands against the demo store, so this beat cannot drift away from what the CLI
 * actually prints, and nothing here was written to look good.
 *
 * Rendered rather than screen-recorded. A recording of a terminal brings its own typeface, its own theme
 * and its own window chrome into a demo that has spent twenty seconds establishing one of each; drawing
 * the text keeps the beat inside the demo's design and lets the reveal be directed. It sits on a card
 * with the same shadow as the app window, so the cut into it reads as the same desk.
 *
 * The commands type out at a rate a person types. The output does not — output arrives at once, because
 * that is what output does, and typing it would be the one thing in this demo that lies about how the
 * software behaves.
 */
export const Terminal: React.FC<{ durationInFrames: number }> = ({ durationInFrames }) => {
  const frame = useCurrentFrame();
  const beats = layout(durationInFrames);

  // 350ms rather than the 150ms this used when it was a scene of its own. It is an overlay now — it opens
  // in front of the app window, which stays on screen behind it and never cuts away — and an overlay that
  // snaps in reads as a cut, which is the one thing this edit does not do.
  const fade = Math.round(0.35 * FPS);
  const opacity = interpolate(
    frame,
    [0, fade, durationInFrames - fade, durationInFrames],
    [0, 1, 1, 0],
    { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: smoothstep },
  );

  return (
    <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', opacity }}>
      {/* Darkens the desk behind, so the card reads as being in front of the app rather than instead of
          it. It also does the practical job of holding the app's own window state still and unreadable
          while it changes underneath: the write-up clip is swapped in behind this scrim, which is the one
          moment in the demo where a change of picture is completely invisible. */}
      <AbsoluteFill style={{ background: 'rgba(4,5,11,0.62)' }} />
      <div
        style={{
          width: 1420,
          padding: '46px 54px',
          borderRadius: 20,
          // Opaque, not 94%. As a scene of its own this card had nothing behind it and the translucency
          // was free; as an overlay it sat over a dark app window and the two tones merged, so the card
          // read as a dim patch rather than as something in front. Opaque plus the app window's own shadow
          // is what puts it on top.
          background: '#0b0d16',
          border: '1px solid rgba(255,255,255,0.09)',
          filter: WINDOW_SHADOW.split(', ')
            .map((layer) => `drop-shadow(${layer})`)
            .join(' '),
          fontFamily: MONO,
          fontSize: 22,
          lineHeight: 1.62,
          color: '#e7e7ea',
          // `pre-wrap`, not `pre`: a `meetings list` row is ~106 characters and a summary line can be
          // longer, and with `pre` they ran straight out through the right edge of the card. A real
          // terminal wraps too, so wrapping is also the honest rendering.
          whiteSpace: 'pre-wrap',
          // Tabular output only lines up if the digits are the same width as everything else.
          fontVariantNumeric: 'tabular-nums',
          fontVariantLigatures: 'none',
        }}
      >
        {STEPS.map((step, index) => {
          const beat = beats[index];
          if (frame < beat.typeStart) return null;
          const typed = Math.floor(
            interpolate(frame, [beat.typeStart, beat.typeEnd], [0, step.command.length], {
              extrapolateLeft: 'clamp',
              extrapolateRight: 'clamp',
            }),
          );
          const caret = frame < beat.outputAt && Math.floor(frame / 18) % 2 === 0;
          return (
            <div key={step.command} style={{ marginBottom: index === STEPS.length - 1 ? 0 : 30 }}>
              <div>
                <span style={{ color: '#6e6e73' }}>$ </span>
                <span>{step.command.slice(0, typed)}</span>
                {caret ? <span style={{ opacity: 0.85 }}>▏</span> : null}
              </div>
              {frame >= beat.outputAt && step.output.length > 0 ? (
                <Output text={step.output} at={beat.outputAt} />
              ) : null}
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};

/** Output fades up over four frames: long enough not to be a hard cut, short enough to read as an answer. */
const Output: React.FC<{ text: string; at: number }> = ({ text, at }) => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [at, at + 4], [0, 1], {
    easing: smoothstep,
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  return (
    <div style={{ opacity, marginTop: 8, color: '#b9bac1' }}>
      {text.split('\n').map((line, index) => (
        <div key={`${index}-${line}`}>{line}</div>
      ))}
    </div>
  );
};

/**
 * When each step types, answers, and yields to the next.
 *
 * Derived from the beat's length rather than hard-coded, so re-capturing a session with a different
 * number of steps re-paces itself instead of running off the end of the Sequence.
 */
const layout = (durationInFrames: number) => {
  const hold = Math.round(0.5 * FPS);
  const share = (durationInFrames - hold) / STEPS.length;
  return STEPS.map((step, index) => {
    const start = Math.round(index * share);
    // 22ms a character is a fast, even typist, capped so a long command still leaves time to read the
    // answer it produced.
    const typing = Math.min(step.command.length * (FPS * 0.022), share * 0.5);
    return {
      typeStart: start,
      typeEnd: start + typing,
      outputAt: Math.round(start + typing + FPS * 0.14),
    };
  });
};
