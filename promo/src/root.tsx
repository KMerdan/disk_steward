import React from 'react';
import {Composition} from 'remotion';
import {DiskStewardPromo} from './DiskStewardPromo';

export const RemotionRoot: React.FC = () => (
  <Composition
    id="DiskStewardPromo"
    component={DiskStewardPromo}
    durationInFrames={900}
    fps={30}
    width={1920}
    height={1080}
  />
);
