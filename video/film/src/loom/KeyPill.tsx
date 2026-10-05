import { INTER } from '../fonts';
import { smoothstep } from './track';

/**
 * The floating pill that shows a pressed shortcut.
 *
 * Geometry is Cap's: font 50px at 1080p, padding 0.45x the font, radius 0.5x the font so it is a true
 * pill rather than a rounded box, on black at 95%. It enters and leaves over 150ms with a 6px
 * ease-out bounce — up on the way in, down on the way out — which is the detail that stops it reading
 * as a static label that blinked.
 *
 * It exists because a keyboard-driven step is otherwise invisible: the search palette opening is the
 * only thing on screen, and without the pill the viewer has no idea whether it was a click, a menu or
 * a shortcut.
 */
const FONT = 50;
const PADDING = FONT * 0.45;

export const KeyPill: React.FC<{
  keys: string;
  /** 0 = fully hidden, 1 = fully shown. */
  progress: number;
  /** Which way the bounce goes: entering rises, leaving sinks. */
  leaving?: boolean;
}> = ({ keys, progress, leaving = false }) => {
  const eased = smoothstep(progress);
  const bounce = 6 * (1 - eased) * (leaving ? 1 : -1);

  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        // Cap parks it at 0.85 of frame height. Here it sits a little higher, because this film also
        // carries a caption along the bottom and two stacked overlays read as one cluttered band.
        top: 1080 * 0.78,
        display: 'flex',
        justifyContent: 'center',
        opacity: eased,
        transform: `translateY(${bounce.toFixed(2)}px)`,
        pointerEvents: 'none',
      }}
    >
      <div
        style={{
          fontFamily: INTER,
          fontSize: FONT,
          fontWeight: 500,
          lineHeight: 1.2,
          color: '#ffffff',
          background: 'rgba(0,0,0,0.95)',
          padding: `${PADDING * 0.55}px ${PADDING}px`,
          borderRadius: FONT * 0.5,
          letterSpacing: 0.5,
          // The glyphs are ⌘ and ⌥ as often as letters, and Inter's default figures are proportional.
          fontVariantNumeric: 'tabular-nums',
        }}
      >
        {keys}
      </div>
    </div>
  );
};
