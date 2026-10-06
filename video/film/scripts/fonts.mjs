// Copies the fonts the demo embeds out of node_modules and into public/fonts.
//
// Copied rather than imported so that `remotion render` resolves them through `staticFile()` — a
// bundler-resolved CSS import loads asynchronously and races the first frame, which is how a render
// comes back with the whole video set in Helvetica.
//
// Inter (OFL) sets the captions and the closing card. JetBrains Mono (OFL) sets the terminal beat,
// because that beat is a terminal and Inter is not a monospace. San Francisco is installed on every Mac
// and its licence permits UI mock-ups only — see src/fonts.ts.
import { mkdir, copyFile, access } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const out = resolve(root, 'public/fonts');

const files = [
  ['@fontsource-variable/inter/files/inter-latin-wght-normal.woff2', 'inter-variable.woff2'],
  [
    '@fontsource-variable/jetbrains-mono/files/jetbrains-mono-latin-wght-normal.woff2',
    'jetbrains-mono-variable.woff2',
  ],
];

await mkdir(out, { recursive: true });
for (const [from, to] of files) {
  const source = resolve(root, 'node_modules', from);
  await access(source);
  await copyFile(source, resolve(out, to));
  console.log(`fonts: public/fonts/${to}`);
}
