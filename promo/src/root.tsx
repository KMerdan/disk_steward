import React from 'react';
import {Composition, Folder} from 'remotion';
import {DiskStewardPromo} from './DiskStewardPromo';
import {AgentWorkScene} from './scenes/AgentWorkScene';
import {AnalysisScene} from './scenes/AnalysisScene';
import {EvidenceScene} from './scenes/EvidenceScene';
import {FinalScene} from './scenes/FinalScene';
import {MysteryScene} from './scenes/MysteryScene';
import {StewardScene} from './scenes/StewardScene';

export const RemotionRoot: React.FC = () => (
  <>
    <Composition id="DiskStewardPromo" component={DiskStewardPromo} durationInFrames={900} fps={30} width={1920} height={1080} />
    <Folder name="Scenes">
      <Composition id="01-Hook" component={AgentWorkScene} durationInFrames={105} fps={30} width={1920} height={1080} />
      <Composition id="02-Mystery" component={MysteryScene} durationInFrames={135} fps={30} width={1920} height={1080} />
      <Composition id="03-Product" component={StewardScene} durationInFrames={225} fps={30} width={1920} height={1080} />
      <Composition id="04-EvidenceChain" component={AnalysisScene} durationInFrames={175} fps={30} width={1920} height={1080} />
      <Composition id="05-AgentHandoff" component={EvidenceScene} durationInFrames={205} fps={30} width={1920} height={1080} />
      <Composition id="06-EndCard" component={FinalScene} durationInFrames={95} fps={30} width={1920} height={1080} />
    </Folder>
  </>
);
