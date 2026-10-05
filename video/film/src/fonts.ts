import { loadFont } from '@remotion/fonts';
import { staticFile } from 'remotion';

/**
 * Inter, and only Inter.
 *
 * San Francisco is installed on every Mac and would be the obvious choice for a macOS demo. Its licence
 * (Apple San Francisco Font License, EA1370 §2A/§2B) grants use "solely for creating mock-ups of user
 * interfaces" and expressly forbids using the font to "create, develop, display or otherwise distribute
 * any documentation, artwork, website content or any other work product". A demo video is a work
 * product. Inter is SIL OFL 1.1, which permits exactly this.
 *
 * San Francisco still appears in every frame — inside the app, drawn by macOS with its own copy of its
 * own font. That is the operating system rendering its interface, not us embedding a typeface.
 */
export const INTER = 'Inter Variable';

/** The terminal beat only. A terminal set in a proportional face is not a terminal. */
export const MONO = 'JetBrains Mono Variable';

let requested = false;

/**
 * Registers the face, once, and holds the render open until it arrives.
 *
 * Called from a **component body**, not module scope. `remotion render` evaluates the bundle twice —
 * once in Node to read the compositions out of it, then in the browser to draw frames — and in the Node
 * pass there is no `window.remotion_staticBase`, so `staticFile()` returns undefined and `loadFont`
 * throws before a single frame is attempted. A component body only ever runs in the browser pass.
 * (`remotion still` happens to survive module-scope loading, which is why this looked fine right up
 * until the first full render.)
 */
export const ensureFonts = (): void => {
  if (requested) return;
  requested = true;
  void loadFont({
    family: INTER,
    url: staticFile('fonts/inter-variable.woff2'),
    format: 'woff2',
    weight: '100 900',
  });
  void loadFont({
    family: MONO,
    url: staticFile('fonts/jetbrains-mono-variable.woff2'),
    format: 'woff2',
    weight: '100 800',
  });
};
