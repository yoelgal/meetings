import { Audio } from '@remotion/media';
import {
  AbsoluteFill,
  Img,
  Sequence,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import { AppWindow } from '../components/AppWindow';
import { INTER, MONO, ensureFonts } from '../fonts';
import { FPS, sec } from '../theme';
import session from './session.json';

/**
 * The launch film: hook → problem → reveal → five features → end card, about thirty-four seconds.
 *
 * Where `Demo` is one continuous Loom-style take with no words, this is a launch: one claim per beat,
 * said in type, proved by the real app straight after. Every frame of app footage is the shipping app
 * against the invented store `video/brag/shoot.sh` seeds; the only things drawn here are the type, the
 * waveforms that stand for the two tracks, and the terminal (whose text is real CLI output).
 */

const BLUE = '#0A84FF'; // systemBlue: the mic channel, "You", as ChannelStyle.swift draws it
const PINK = '#FF375F'; // systemPink: the system channel, "Others"
const INK = '#F5F5F7';
const DIM = '#8E8E99';

/** Scene boundaries, in seconds. Every cut from the reveal on sits on the score's beat grid —
 * 6.6 s plus a whole number of 0.6 s beats (100 BPM) — and `score.py` uses the same numbers. */
const T = {
  hook: 0,
  problem: 3.0,
  reveal: 6.6,
  live: 10.2,
  anchored: 16.2,
  share: 20.4,
  cli: 24.6,
  end: 30.0,
  total: 34.0,
};
export const LAUNCH_FRAMES = sec(T.total);

const ease = (t: number) => (t <= 0 ? 0 : t >= 1 ? 1 : t * t * (3 - 2 * t));
const clamp = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;

/** Fade+rise in at `at` seconds, optional fade out at `out` seconds (scene-relative). */
const useReveal = (at: number, out?: number, rise = 18) => {
  const frame = useCurrentFrame();
  const t = (frame - sec(at)) / sec(0.45);
  let opacity = ease(t);
  if (out !== undefined) opacity *= 1 - ease((frame - sec(out)) / sec(0.3));
  return { opacity, transform: `translateY(${((1 - ease(t)) * rise).toFixed(2)}px)` };
};

const Backdrop: React.FC = () => (
  <AbsoluteFill
    style={{
      background:
        'radial-gradient(ellipse 85% 75% at 50% 38%, #17134a 0%, #0a0826 55%, #03030f 100%)',
    }}
  />
);

const Headline: React.FC<{
  children: React.ReactNode;
  at: number;
  out?: number;
  size?: number;
  color?: string;
  top?: number;
}> = ({ children, at, out, size = 64, color = INK, top }) => {
  const style = useReveal(at, out);
  return (
    <div
      style={{
        ...style,
        position: top === undefined ? 'relative' : 'absolute',
        top,
        left: 0,
        right: 0,
        textAlign: 'center',
        fontFamily: INTER,
        fontWeight: 650,
        fontSize: size,
        letterSpacing: -0.022 * size,
        lineHeight: 1.1,
        color,
      }}
    >
      {children}
    </div>
  );
};

// MARK: - The two tracks, drawn

/** A row of bars driven by deterministic noise, so every render of a frame is the same frame. */
const Wave: React.FC<{ color: string; width: number; seed: number; energy?: number; bars?: number }> = ({
  color,
  width,
  seed,
  energy = 1,
  bars = 64,
}) => {
  const frame = useCurrentFrame();
  const gap = 6;
  const bar = (width - gap * (bars - 1)) / bars;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap, height: 150 }}>
      {Array.from({ length: bars }, (_, i) => {
        const phase = frame / FPS;
        const n =
          0.5 +
          0.28 * Math.sin(i * 0.61 + seed + phase * 5.1) +
          0.22 * Math.sin(i * 1.37 + seed * 2 + phase * 7.3);
        const envelope = Math.sin((Math.PI * (i + 0.5)) / bars) ** 0.6;
        const h = Math.max(6, 140 * n * envelope * energy);
        return <div key={i} style={{ width: bar, height: h, borderRadius: bar, background: color }} />;
      })}
    </div>
  );
};

// MARK: - Scenes

const Hook: React.FC = () => {
  const frame = useCurrentFrame();
  const line = '“I’ll send it by Friday.”';
  const typed = Math.floor(interpolate(frame, [sec(0.15), sec(1.0)], [0, line.length], clamp));
  const question = frame >= sec(1.8);
  return (
    <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
      {!question ? (
        <div style={{ fontFamily: INTER, fontSize: 76, fontWeight: 500, color: INK, letterSpacing: -1.5 }}>
          {line.slice(0, typed)}
          <span style={{ opacity: Math.floor(frame / 16) % 2 ? 0 : 0.7 }}>▏</span>
        </div>
      ) : (
        <div
          style={{
            fontFamily: INTER,
            fontSize: 150,
            fontWeight: 750,
            letterSpacing: -4.5,
            color: INK,
            transform: `scale(${1.06 - 0.06 * ease((frame - sec(1.8)) / sec(0.35))})`,
          }}
        >
          Who said that?
        </div>
      )}
    </AbsoluteFill>
  );
};

const Problem: React.FC = () => (
  <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
    <div style={{ position: 'absolute', top: 300 }}>
      <Wave color="#5d5d6b" width={1100} seed={1.3} energy={0.9} />
    </div>
    <Headline at={0.15} out={1.75} top={640}>
      Most recorders hear one mixed track.
    </Headline>
    <Headline at={1.95} top={640}>
      Then they guess who’s talking.
    </Headline>
  </AbsoluteFill>
);

const Reveal: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const split = spring({ frame: frame - sec(0.1), fps, config: { damping: 200 } });
  const label = useReveal(0.55);
  const mark = useReveal(1.2, undefined, 0);
  return (
    <AbsoluteFill style={{ alignItems: 'center' }}>
      {[
        { color: BLUE, name: 'You', sub: 'your microphone', dy: -95, seed: 2.1 },
        { color: PINK, name: 'Others', sub: 'your Mac’s audio', dy: 95, seed: 4.7 },
      ].map((track) => (
        <div
          key={track.name}
          style={{
            position: 'absolute',
            top: 300 + track.dy * split,
            display: 'flex',
            alignItems: 'center',
            gap: 40,
          }}
        >
          <Wave color={track.color} width={1000} seed={track.seed} energy={0.55 + 0.25 * split} bars={56} />
          <div style={{ ...label, width: 280, fontFamily: INTER }}>
            <div style={{ fontSize: 48, fontWeight: 700, color: track.color, letterSpacing: -1 }}>
              {track.name}
            </div>
            <div style={{ fontSize: 24, color: DIM, marginTop: 2 }}>{track.sub}</div>
          </div>
        </div>
      ))}
      <div
        style={{
          ...mark,
          position: 'absolute',
          top: 740,
          display: 'flex',
          alignItems: 'center',
          gap: 26,
        }}
      >
        <Img
          src={staticFile('launch/logo.png')}
          style={{
            width: 132,
            height: 132,
            mixBlendMode: 'screen',
            WebkitMaskImage: 'radial-gradient(circle, #000 50%, transparent 76%)',
          }}
        />
        <div style={{ fontFamily: INTER, fontSize: 60, fontWeight: 650, color: INK, letterSpacing: -1.4 }}>
          Meetings records them separately.
        </div>
      </div>
    </AbsoluteFill>
  );
};

/** A feature beat: the claim on top, the real app underneath it. */
const Feature: React.FC<{ caption: React.ReactNode; children: React.ReactNode; length: number }> = ({
  caption,
  children,
  length,
}) => {
  const frame = useCurrentFrame();
  const inT = ease(frame / sec(0.5));
  const outT = ease((frame - (sec(length) - sec(0.3))) / sec(0.3));
  return (
    <AbsoluteFill style={{ opacity: 1 - outT }}>
      <Headline at={0.05} top={64} size={60}>
        {caption}
      </Headline>
      <AbsoluteFill
        style={{
          top: 170,
          alignItems: 'center',
          // Zooms stay below the caption rather than sliding under it.
          overflow: 'hidden',
          paddingTop: 20,
          opacity: inT,
          transform: `translateY(${(1 - inT) * 60}px)`,
        }}
      >
        {children}
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

/** A window pushed in slowly toward a focus point (fractions of the window). */
const Push: React.FC<{
  children: React.ReactNode;
  length: number;
  from?: number;
  to?: number;
  fx?: number;
  fy?: number;
}> = ({ children, length, from = 1, to = 1.12, fx = 0.6, fy = 0.4 }) => {
  const frame = useCurrentFrame();
  const t = ease(frame / sec(length));
  return (
    <div
      style={{
        transform: `scale(${from + (to - from) * t})`,
        transformOrigin: `${fx * 100}% ${fy * 100}%`,
      }}
    >
      {children}
    </div>
  );
};

const ShareSplit: React.FC = () => {
  const frame = useCurrentFrame();
  const gone = ease((frame - sec(1.4)) / sec(0.6));
  const pane = (title: string, withPanel: number) => (
    <div style={{ width: 900 }}>
      <div
        style={{
          fontFamily: INTER,
          fontSize: 28,
          fontWeight: 600,
          color: DIM,
          marginBottom: 18,
          textAlign: 'center',
        }}
      >
        {title}
      </div>
      <div style={{ position: 'relative' }}>
        <AppWindow src="launch/recording-window.png" width={900} />
        <div
          style={{
            position: 'absolute',
            right: -24,
            top: 70,
            width: 290,
            opacity: withPanel,
          }}
        >
          <AppWindow src="launch/panel-live.png" width={290} />
        </div>
      </div>
    </div>
  );
  return (
    <div style={{ display: 'flex', gap: 70, marginTop: 110 }}>
      {pane('Your screen', 1)}
      {pane('What they see', 1 - gone)}
    </div>
  );
};

type Step = { command: string; output: string };

const Terminal: React.FC<{ length: number }> = ({ length }) => {
  const frame = useCurrentFrame();
  const steps = session as Step[];
  const per = sec(length) / steps.length;
  return (
    <div
      style={{
        width: 1500,
        padding: '40px 48px',
        borderRadius: 20,
        background: '#0b0d16',
        border: '1px solid rgba(255,255,255,0.09)',
        boxShadow: '0 40px 120px rgba(0,0,0,0.55)',
        fontFamily: MONO,
        fontSize: 24,
        lineHeight: 1.5,
        color: '#e7e7ea',
        whiteSpace: 'pre-wrap',
        fontVariantLigatures: 'none',
        marginTop: 90,
      }}
    >
      {steps.map((step, i) => {
        const start = i * per;
        if (frame < start) return null;
        const typeEnd = start + Math.min(step.command.length * 1.4, per * 0.4);
        const typed = Math.floor(interpolate(frame, [start, typeEnd], [0, step.command.length], clamp));
        const outAt = typeEnd + sec(0.15);
        const lines = step.output.split('\n').filter((l) => l.trim() !== '').slice(0, 6);
        return (
          <div key={step.command} style={{ marginBottom: 22 }}>
            <span style={{ color: '#6e6e73' }}>$ </span>
            {step.command.slice(0, typed)}
            {frame >= outAt ? (
              <div style={{ color: '#b9bac1', marginTop: 6, opacity: ease((frame - outAt) / 6) }}>
                {lines.join('\n')}
              </div>
            ) : null}
          </div>
        );
      })}
    </div>
  );
};

const EndCard: React.FC = () => {
  const mark = useReveal(0.05, undefined, 0);
  const tag = useReveal(0.45);
  const install = useReveal(0.9);
  const meta = useReveal(1.3);
  return (
    <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
      <div style={{ ...mark, display: 'flex', alignItems: 'center', marginTop: -80 }}>
        <Img
          src={staticFile('launch/logo.png')}
          style={{
            width: 300,
            height: 300,
            marginRight: -10,
            mixBlendMode: 'screen',
            WebkitMaskImage: 'radial-gradient(circle, #000 50%, transparent 76%)',
          }}
        />
        <div style={{ fontFamily: INTER, fontSize: 120, fontWeight: 650, letterSpacing: -2.4, color: '#fff' }}>
          Meetings
        </div>
      </div>
      <div style={{ ...tag, fontFamily: INTER, fontSize: 44, fontWeight: 500, color: INK, marginTop: 6 }}>
        An app for you. A CLI for your agent.
      </div>
      <div
        style={{
          ...install,
          marginTop: 54,
          padding: '20px 30px',
          borderRadius: 14,
          background: 'rgba(255,255,255,0.06)',
          border: '1px solid rgba(255,255,255,0.12)',
          fontFamily: MONO,
          fontSize: 25,
          color: '#e7e7ea',
        }}
      >
        <span style={{ color: '#6e6e73' }}>$ </span>
        curl -fsSL https://raw.githubusercontent.com/yoelgal/meetings/main/install.sh | bash
      </div>
      <div style={{ ...meta, marginTop: 26, fontFamily: INTER, fontSize: 24, color: DIM }}>
        macOS 26 · Apple Silicon · On-device · Open source (MIT)
      </div>
    </AbsoluteFill>
  );
};

// MARK: - The film

export const Launch: React.FC = () => {
  ensureFonts();
  const at = (s: number) => sec(s);
  const len = (a: number, b: number) => sec(b - a);
  return (
    <AbsoluteFill style={{ background: '#03030f' }}>
      <Backdrop />
      <Audio src={staticFile('launch/score.wav')} />

      <Sequence from={at(T.hook)} durationInFrames={len(T.hook, T.problem)}>
        <Hook />
      </Sequence>
      <Sequence from={at(T.problem)} durationInFrames={len(T.problem, T.reveal)}>
        <Problem />
      </Sequence>
      <Sequence from={at(T.reveal)} durationInFrames={len(T.reveal, T.live)}>
        <Reveal />
      </Sequence>

      <Sequence from={at(T.live)} durationInFrames={len(T.live, T.anchored)}>
        <Feature length={T.anchored - T.live} caption="Transcribed live. On this Mac.">
          <Push length={T.anchored - T.live} to={1.85} fx={0.42} fy={0.08}>
            <AppWindow src="launch/live.mov" width={1500} trimBefore={sec(0.6)} />
          </Push>
        </Feature>
      </Sequence>

      <Sequence from={at(T.anchored)} durationInFrames={len(T.anchored, T.share)}>
        <Feature length={T.share - T.anchored} caption="Every note lands where it was said.">
          <Push length={T.share - T.anchored} to={1.4} fx={0.72} fy={0.78}>
            <AppWindow src="launch/anchored.png" width={1500} />
          </Push>
        </Feature>
      </Sequence>

      <Sequence from={at(T.share)} durationInFrames={len(T.share, T.cli)}>
        <Feature length={T.cli - T.share} caption="Your notes stay off the screen share.">
          <ShareSplit />
        </Feature>
      </Sequence>

      <Sequence from={at(T.cli)} durationInFrames={len(T.cli, T.end)}>
        <Feature length={T.end - T.cli} caption="No prompts in the app. Your agent writes it up.">
          <Sequence durationInFrames={sec(3.3)} layout="none">
            <Terminal length={3.1} />
          </Sequence>
          <Sequence from={sec(3.3)} layout="none">
            <AppWindow src="launch/writeup.mov" width={1500} trimBefore={sec(1.9)} />
          </Sequence>
        </Feature>
      </Sequence>

      <Sequence from={at(T.end)} durationInFrames={len(T.end, T.total)}>
        <EndCard />
      </Sequence>
    </AbsoluteFill>
  );
};
