import React from 'react';
import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {Headline, Kicker, SceneShell, Supporting} from '../components/SceneShell';
import {colors, monoFamily, panel} from '../styles';

const artifacts = [
  ['worktree-17', '2.8 GB'],
  ['DerivedData', '6.4 GB'],
  ['agent-export.zip', '1.1 GB'],
  ['Downloads', '+3.7 GB'],
];

export const AgentWorkScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const done = spring({frame, fps, config: {damping: 16}});

  return (
    <SceneShell duration={150} accent={colors.cyan}>
      <div style={{display: 'grid', gridTemplateColumns: '1.05fr .95fr', gap: 84, height: '100%', alignItems: 'center'}}>
        <div>
          <Kicker>01 · The hidden cost of speed</Kicker>
          <Headline>AI work finishes. Its disk footprint may not.</Headline>
          <Supporting>Local agents create useful work—and the supporting files can outlive the task.</Supporting>
        </div>
        <div style={{...panel, padding: 30, minHeight: 560}}>
          <div style={{display: 'flex', alignItems: 'center', gap: 16, borderBottom: `1px solid ${colors.line}`, paddingBottom: 24}}>
            <div style={{width: 16, height: 16, borderRadius: 99, background: colors.green, boxShadow: `0 0 22px ${colors.green}`}} />
            <div style={{fontSize: 31, fontWeight: 700}}>Agent task complete</div>
            <div style={{marginLeft: 'auto', color: colors.green, fontSize: 26}}>✓ 47 files changed</div>
          </div>
          <div style={{marginTop: 28, color: colors.muted, fontFamily: monoFamily, fontSize: 23}}>Local artifacts left behind</div>
          <div style={{display: 'grid', gap: 16, marginTop: 20}}>
            {artifacts.map(([name, size], index) => {
              const entrance = spring({frame: frame - 28 - index * 15, fps, config: {damping: 18}});
              const glow = interpolate(frame, [55 + index * 10, 120], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
              return (
                <div key={name} style={{display: 'flex', alignItems: 'center', padding: '20px 22px', borderRadius: 18, background: `rgba(94,167,255,${0.07 + glow * 0.06})`, border: `1px solid rgba(94,167,255,.18)`, opacity: entrance, transform: `translateX(${(1 - entrance) * 40}px)`}}>
                  <div style={{fontSize: 28, fontFamily: monoFamily}}>▱ {name}</div>
                  <div style={{marginLeft: 'auto', fontSize: 28, color: colors.amber, fontWeight: 720}}>{size}</div>
                </div>
              );
            })}
          </div>
          <div style={{height: 12, borderRadius: 99, background: 'rgba(255,255,255,.08)', overflow: 'hidden', marginTop: 34}}>
            <div style={{height: '100%', width: `${31 + done * 46}%`, background: `linear-gradient(90deg, ${colors.blue}, ${colors.amber})`, borderRadius: 99}} />
          </div>
          <div style={{display: 'flex', marginTop: 13, color: colors.muted, fontSize: 23}}><span>Storage used</span><span style={{marginLeft: 'auto', color: colors.ink}}>77%</span></div>
        </div>
      </div>
    </SceneShell>
  );
};
