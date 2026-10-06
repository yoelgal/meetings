import { Config } from '@remotion/cli/config';

Config.setVideoImageFormat('jpeg');
// The film is 1920x1080 and every source is 2880x1800, so the browser is always downsampling. Chrome's
// default image scaling is bilinear and visibly softens 10pt UI text at that ratio.
Config.setChromiumOpenGlRenderer('angle');
Config.setJpegQuality(100);
Config.setOverwriteOutput(true);
// bt709 for both masters. Remotion 4 defaults to "default", which leaves the colour tags off the file
// entirely and lets every player guess; QuickTime and Chrome guess differently, so the film looks
// milky in one of them.
Config.setColorSpace('bt709');
