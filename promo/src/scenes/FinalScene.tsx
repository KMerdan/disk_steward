import React from 'react';
import {Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {SceneShell} from '../components/SceneShell';
import {colors, monoFamily} from '../styles';

export const FinalScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const entrance = spring({frame, fps, config: {damping: 16, stiffness: 90}});
  const glow = interpolate(frame, [0, 90], [.2, .72], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <SceneShell duration={90} accent={colors.blue}>
      <div style={{height: '100%', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', textAlign: 'center', transform: `scale(${0.92 + entrance * 0.08})`}}>
        <Img src={staticFile('app-icon.png')} style={{width: 180, height: 180, borderRadius: 40, boxShadow: `0 24px 100px rgba(94,167,255,${glow})`}} />
        <div style={{fontSize: 94, fontWeight: 780, letterSpacing: -4.8, marginTop: 34}}>Disk Steward</div>
        <div style={{fontSize: 47, color: colors.cyan, marginTop: 10, letterSpacing: -1.1}}>Know what grew before you delete.</div>
        <div style={{fontFamily: monoFamily, color: colors.muted, fontSize: 25, marginTop: 30}}>github.com/KMerdan/disk_steward · MIT · macOS</div>
      </div>
    </SceneShell>
  );
};
