import React from 'react';
import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {SceneShell} from '../components/SceneShell';
import {clamp, colors, monoFamily} from '../styles';

const objects = [
  {id: 'A', name: 'build-cache', size: '6.4 GB', x: 360, color: colors.green},
  {id: 'B', name: 'old-worktree', size: '2.8 GB', x: 850, color: colors.blue},
  {id: 'C', name: 'export-assets', size: '1.1 GB', x: 1340, color: colors.green},
] as const;

export const AnalysisScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const scanX = interpolate(frame, [10, 112], [220, 1540], clamp);
  const removed = interpolate(frame, [72, 94], [0, 1], clamp);

  return (
    <SceneShell accent={colors.green} label="Evidence follows the lifecycle">
      <div style={{position: 'absolute', inset: 0}}>
        <div style={{position: 'absolute', left: 180, right: 180, top: 520, height: 4, background: 'rgba(255,255,255,.12)', boxShadow: '0 0 28px rgba(83,226,243,.22)'}} />
        <div style={{position: 'absolute', left: scanX, top: 270, width: 3, height: 500, background: `linear-gradient(transparent, ${colors.cyan}, transparent)`, boxShadow: `0 0 44px ${colors.cyan}`, opacity: .85}} />

        {objects.map((object, index) => {
          const enter = spring({frame: frame - 10 - index * 13, fps, config: {damping: 16}});
          const isRemoved = object.id === 'B';
          return (
            <div key={object.id} style={{position: 'absolute', left: object.x, top: 520, translate: '-50% -50%', opacity: isRemoved ? 1 - removed * .76 : enter, scale: isRemoved ? 1 - removed * .22 : .72 + enter * .28, filter: isRemoved ? `blur(${removed * 4}px)` : 'none'}}>
              <div style={{width: 230, height: 230, borderRadius: 38, display: 'grid', placeItems: 'center', background: 'rgba(16,22,31,.96)', border: `2px solid ${object.color}66`, boxShadow: `0 30px 90px rgba(0,0,0,.52), 0 0 55px ${object.color}16`, rotate: `${interpolate(frame, [0, 175], [-3 + index * 2, 3 - index], clamp)}deg`}}>
                <div style={{textAlign: 'center'}}>
                  <div style={{fontSize: 74, fontWeight: 900, color: object.color}}>{object.id}</div>
                  <div style={{fontFamily: monoFamily, fontSize: 18, marginTop: 7}}>{object.name}</div>
                  <div style={{fontSize: 20, color: colors.muted, marginTop: 8}}>{object.size}</div>
                </div>
              </div>
              <div style={{width: 20, height: 20, borderRadius: 99, background: isRemoved && removed > .45 ? colors.blue : object.color, margin: '40px auto 0', boxShadow: `0 0 25px ${object.color}`}} />
              <div style={{textAlign: 'center', marginTop: 13, fontSize: 18, letterSpacing: 2, color: isRemoved && removed > .45 ? colors.blue : object.color}}>{isRemoved && removed > .45 ? 'REMOVED' : 'PRESENT'}</div>
            </div>
          );
        })}

        <div style={{position: 'absolute', left: 112, top: 150, fontSize: 83, fontWeight: 890, letterSpacing: -4.5, lineHeight: .92}}>A + C remain.<br/><span style={{color: colors.blue, opacity: interpolate(frame, [78, 96], [0, 1], clamp)}}>B is gone.</span></div>
        <div style={{position: 'absolute', right: 112, top: 180, display: 'flex', gap: 12}}>
          {['CURRENT', 'EVENT', 'COVERAGE'].map((word, index) => <div key={word} style={{padding: '11px 15px', borderRadius: 999, border: `1px solid ${index === 2 ? colors.amber : colors.cyan}55`, color: index === 2 ? colors.amber : colors.cyan, fontSize: 17, letterSpacing: 1.3}}>{word}</div>)}
        </div>
        <div style={{position: 'absolute', right: 112, bottom: 150, color: colors.muted, fontSize: 23}}>History compacts. State stays clear.</div>
      </div>
    </SceneShell>
  );
};
