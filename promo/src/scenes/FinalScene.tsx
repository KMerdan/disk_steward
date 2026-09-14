import React from 'react';
import {Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {SceneShell} from '../components/SceneShell';
import {clamp, colors, monoFamily} from '../styles';

export const FinalScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const enter = spring({frame, fps, config: {damping: 16, stiffness: 90}});

  return (
    <SceneShell accent={colors.orange}>
      <div style={{position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', overflow: 'hidden'}}>
        {[1, 2, 3].map((ring) => <div key={ring} style={{position: 'absolute', width: ring * 420, height: ring * 420, borderRadius: '50%', border: '2px solid rgba(255,122,22,.12)', scale: interpolate(frame, [0, 95], [.82, 1.12], clamp), opacity: 1 - ring * .2}} />)}
        <div style={{position: 'relative', display: 'flex', alignItems: 'center', gap: 52, scale: .86 + enter * .14}}>
          <Img src={staticFile('app-icon.png')} style={{width: 220, height: 220, borderRadius: 52, boxShadow: '0 35px 120px rgba(255,122,22,.38)', rotate: `${interpolate(frame, [0, 95], [-7, 3], clamp)}deg`}} />
          <div>
            <div style={{fontSize: 100, fontWeight: 920, letterSpacing: -5.8, lineHeight: .88}}>KNOW<br/><span style={{color: colors.cyan}}>THEN DECIDE.</span></div>
            <div style={{fontSize: 27, color: colors.muted, marginTop: 24}}>Disk Steward · macOS</div>
          </div>
        </div>
        <div style={{position: 'absolute', bottom: 145, fontFamily: monoFamily, fontSize: 23, color: colors.ink}}>github.com/KMerdan/disk_steward <span style={{color: colors.muted}}>· MIT</span></div>
      </div>
    </SceneShell>
  );
};
