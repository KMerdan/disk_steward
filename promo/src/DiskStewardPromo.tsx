import React from 'react';
import {AbsoluteFill, Audio, Sequence, staticFile} from 'remotion';
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
    <Audio src={staticFile('voiceover.wav')} volume={1} />
    <Sequence from={0} durationInFrames={150}><AgentWorkScene /></Sequence>
    <Sequence from={150} durationInFrames={150}><MysteryScene /></Sequence>
    <Sequence from={300} durationInFrames={150}><AnalysisScene /></Sequence>
    <Sequence from={450} durationInFrames={210}><StewardScene /></Sequence>
    <Sequence from={660} durationInFrames={150}><EvidenceScene /></Sequence>
    <Sequence from={810} durationInFrames={90}><FinalScene /></Sequence>
    <Captions />
  </AbsoluteFill>
);
