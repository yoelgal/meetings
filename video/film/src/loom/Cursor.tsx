/**
 * A drawn macOS pointer.
 *
 * There is no cursor in the plate: `wincap.swift` records with `showsCursor = false`, deliberately.
 * That is not a limitation worked around here, it is the same order of operations Screen Studio and Cap
 * use — you cannot spring-smooth, scale up or re-time a cursor that has been baked into the pixels. The
 * cursor being synthetic is also what lets this whole demo be produced without ever touching the
 * operator's pointer, which is the invariant the app's own source insists on.
 *
 * Drawn as a path rather than shipped as a PNG so it stays sharp at the 2x master and at any zoom.
 */
export const Cursor: React.FC<{
  /** Frame coordinates, in film pixels. */
  x: number;
  y: number;
  /** Cap's `STANDARD_CURSOR_HEIGHT` is 60px at 1080p, and grows with the zoom so it matches the UI. */
  height: number;
  /** 1 at rest, 0.8 fully pressed. */
  scale: number;
  opacity?: number;
}> = ({ x, y, height, scale, opacity = 1 }) => {
  // The classic Mac arrow is white-filled with a dark outline, which is why it stays visible over a
  // dark UI without being recoloured. Path is authored in a 20x28 box; height drives the rest.
  const width = height * (20 / 28);

  return (
    <svg
      width={width}
      height={height}
      viewBox="0 0 20 28"
      style={{
        position: 'absolute',
        left: x,
        top: y,
        // The hotspot is the arrow's tip, which is the path's origin — so the cursor points *at* the
        // coordinate rather than sitting below and right of it. The punch scales about that same tip,
        // because a click that scales about the centre visibly slides the tip off the button.
        transformOrigin: '0% 0%',
        transform: `scale(${scale.toFixed(4)})`,
        opacity,
        overflow: 'visible',
        pointerEvents: 'none',
      }}
    >
      {/* A soft contact shadow. Cap gives the cursor its own shadow for the same reason it gives the
          window one: without it, the pointer reads as part of the UI rather than as floating over it. */}
      <path
        d={ARROW}
        fill="rgba(0,0,0,0.34)"
        transform="translate(0.9 1.4)"
        style={{ filter: 'blur(1.1px)' }}
      />
      <path d={ARROW} fill="#ffffff" stroke="#0a0a0c" strokeWidth={1.1} strokeLinejoin="round" />
    </svg>
  );
};

/** Tip at (0,0); the tail kicks right so it reads as the system pointer rather than a generic arrow. */
const ARROW = 'M0.6 0.6 L0.6 21.2 L5.9 16.1 L9.4 24.6 L13.1 23.0 L9.7 14.8 L17.4 14.6 Z';
