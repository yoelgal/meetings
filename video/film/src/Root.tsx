import { Composition } from 'remotion';
import { Demo, DEMO_FRAMES } from './Demo';
import { Launch, LAUNCH_FRAMES } from './launch/Launch';
import { FPS } from './theme';

export const RemotionRoot: React.FC = () => (
  <>
  <Composition
    id="Demo"
    component={Demo}
    durationInFrames={DEMO_FRAMES}
    fps={FPS}
    width={1920}
    height={1080}
  />
  <Composition
    id="Launch"
    component={Launch}
    durationInFrames={LAUNCH_FRAMES}
    fps={FPS}
    width={1920}
    height={1080}
  />
  </>
);
