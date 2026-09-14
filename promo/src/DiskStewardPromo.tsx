import React from 'react';
import {Audio} from '@remotion/media';
import {TransitionSeries, linearTiming} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {slide} from '@remotion/transitions/slide';
import {wipe} from '@remotion/transitions/wipe';
import {AbsoluteFill, Sequence, staticFile} from 'remotion';
import {Captions} from './components/Captions';
import {AgentWorkScene} from './scenes/AgentWorkScene';
import {AnalysisScene} from './scenes/AnalysisScene';
import {EvidenceScene} from './scenes/EvidenceScene';
import {FinalScene} from './scenes/FinalScene';
import {MysteryScene} from './scenes/MysteryScene';
import {StewardScene} from './scenes/StewardScene';
import {colors} from './styles';

export const DiskStewardPromo: React.FC = () => (
  <AbsoluteFill style={{background: colors.background}}>
    <Audio src={staticFile('score.wav')} volume={0.2} />
    <Sequence from={12}>
      <Audio src={staticFile('voiceover.wav')} volume={1} />
    </Sequence>
    <TransitionSeries>
      <TransitionSeries.Sequence durationInFrames={105}><AgentWorkScene /></TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={linearTiming({durationInFrames: 6})} />
      <TransitionSeries.Sequence durationInFrames={135}><MysteryScene /></TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={wipe({direction: 'from-bottom'})} timing={linearTiming({durationInFrames: 8})} />
      <TransitionSeries.Sequence durationInFrames={225}><StewardScene /></TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={slide({direction: 'from-right'})} timing={linearTiming({durationInFrames: 10})} />
      <TransitionSeries.Sequence durationInFrames={175}><AnalysisScene /></TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={wipe({direction: 'from-left'})} timing={linearTiming({durationInFrames: 8})} />
      <TransitionSeries.Sequence durationInFrames={205}><EvidenceScene /></TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={linearTiming({durationInFrames: 8})} />
      <TransitionSeries.Sequence durationInFrames={95}><FinalScene /></TransitionSeries.Sequence>
    </TransitionSeries>
    <Captions />
  </AbsoluteFill>
);
