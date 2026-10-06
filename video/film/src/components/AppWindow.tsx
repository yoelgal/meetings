import { Video } from '@remotion/media';
import type { CSSProperties } from 'react';
import { Img, staticFile } from 'remotion';
import { WINDOW_SHADOW } from '../theme';

/**
 * One captured window, floated on the film's backdrop.
 *
 * Three things are deliberately *not* here:
 *
 *   - **No corner radius.** The capture already carries the window's real corners as alpha —
 *     `screencapture -o` cuts them on a still and `SCStreamConfiguration.backgroundColor = .clear`
 *     cuts them on a clip. Re-clipping with `border-radius` would round the corners a second time
 *     with a circular arc, and macOS 26's are superelliptical; the mismatch is visible as a faint
 *     double edge at 26pt.
 *   - **No border.** A hairline over an already-antialiased alpha edge reads as a stroke around a
 *     sticker.
 *   - **No scaling of the source.** The captures are 2880x1800 and land in a 1920x1080 frame, so the
 *     browser downsamples — which is what keeps the app's 10pt text crisp. Upscaling any of this
 *     would be the one thing that instantly gives a software film away.
 *
 * `drop-shadow` on the wrapper rather than `box-shadow`: `box-shadow` follows the element's *box*,
 * which is a rectangle, so it would paint shadow into the transparent corners. `drop-shadow` follows
 * the alpha.
 */
export const AppWindow: React.FC<{
  /** A file under public/, e.g. `shots/library.png` or `clips/live.mov`. */
  src: string;
  /** Rendered width in film pixels. The film's windows sit between 1180 and 1560. */
  width: number;
  style?: CSSProperties;
  /** Clip-only: the frame of this Sequence at which the clip should start playing. */
  from?: number;
  /** Clip-only: trim the source, in source frames. */
  trimBefore?: number;
  trimAfter?: number;
}> = ({ src, width, style, from, trimBefore, trimAfter }) => {
  const isClip = src.endsWith('.mov') || src.endsWith('.mp4');
  const file = staticFile(src);

  // The captures are all 1440x900pt at 2x. Held as a ratio rather than a height so a shot taken at
  // another window size still lands with the right proportions.
  const shadow = {
    filter: WINDOW_SHADOW.split(', ')
      .map((layer) => `drop-shadow(${layer})`)
      .join(' '),
  };

  return (
    <div style={{ width, ...shadow, ...style }}>
      {isClip ? (
        <Video
          src={file}
          from={from}
          trimBefore={trimBefore}
          trimAfter={trimAfter}
          style={{ width: '100%', height: 'auto', display: 'block' }}
          // The clips carry no audio track; saying so keeps the renderer from mixing silence in.
          muted
        />
      ) : (
        <Img src={file} style={{ width: '100%', height: 'auto', display: 'block' }} />
      )}
    </div>
  );
};
