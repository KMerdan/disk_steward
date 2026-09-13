import React from 'react';
import {interpolate, useCurrentFrame} from 'remotion';
import {Headline, Kicker, SceneShell, Supporting} from '../components/SceneShell';
import {colors, monoFamily, panel} from '../styles';

const paths = ['~/Library/Developer', '~/Downloads', '~/.cache', '~/Documents', '~/Library/Caches'];

export const AnalysisScene: React.FC = () => {
  const frame = useCurrentFrame();
  const progress = interpolate(frame, [14, 142], [3, 71], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const active = Math.min(paths.length - 1, Math.floor(frame / 26));
  return (
    <SceneShell duration={150} accent={colors.amber}>
      <div style={{display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 84, height: '100%', alignItems: 'center'}}>
        <div>
          <Kicker color={colors.amber}>03 · Analysis starts over</Kicker>
          <Headline>Another disk dig. Slow, partial, easy to misread.</Headline>
          <Supporting>A fresh scan has no durable memory of what was present, deleted, or only partly observed.</Supporting>
        </div>
        <div style={{...panel, padding: 34}}>
          <div style={{display: 'flex', alignItems: 'center'}}>
            <div style={{fontSize: 30, fontWeight: 700}}>Investigating this Mac…</div>
            <div style={{marginLeft: 'auto', color: colors.amber, fontSize: 30, fontWeight: 730}}>{progress.toFixed(0)}%</div>
          </div>
          <div style={{height: 12, borderRadius: 99, background: 'rgba(255,255,255,.09)', marginTop: 26, overflow: 'hidden'}}><div style={{height: '100%', width: `${progress}%`, background: colors.amber}} /></div>
          <div style={{display: 'grid', gap: 12, marginTop: 28}}>
            {paths.map((path, index) => (
              <div key={path} style={{padding: '15px 18px', borderRadius: 12, fontFamily: monoFamily, fontSize: 24, color: index === active ? colors.ink : colors.muted, background: index === active ? 'rgba(255,185,88,.13)' : 'transparent', border: `1px solid ${index === active ? 'rgba(255,185,88,.3)' : 'transparent'}`}}>
                {index < active ? '✓' : index === active ? '↻' : '·'} {path}
              </div>
            ))}
          </div>
          <div style={{marginTop: 28, padding: 22, borderRadius: 18, background: 'rgba(255,112,107,.09)', border: '1px solid rgba(255,112,107,.22)', display: 'flex', alignItems: 'center'}}>
            <span style={{fontSize: 26, color: colors.red}}>Coverage incomplete</span>
            <span style={{marginLeft: 'auto', color: colors.muted, fontSize: 22}}>deletion ≠ proven</span>
          </div>
        </div>
      </div>
    </SceneShell>
  );
};
