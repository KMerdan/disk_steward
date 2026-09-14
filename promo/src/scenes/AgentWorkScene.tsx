import React from 'react';
import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {SceneShell} from '../components/SceneShell';
import {clamp, colors, monoFamily} from '../styles';

const debris = [
  ['worktree', '2.8 GB', -210, -170, -8],
  ['DerivedData', '6.4 GB', 70, -245, 5],
  ['cache', '3.1 GB', 265, -60, 9],
  ['export.zip', '1.1 GB', 170, 150, -5],
  ['Downloads', '+3.7 GB', -150, 205, 6],
] as const;

export const AgentWorkScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const complete = spring({frame: frame - 6, fps, config: {damping: 15, stiffness: 125}});

  return (
    <SceneShell accent={colors.orange} label="The invisible aftermath">
      <div style={{position: 'absolute', inset: 0, display: 'grid', placeItems: 'center'}}>
        <div style={{position: 'absolute', fontSize: 300, fontWeight: 900, letterSpacing: -20, color: 'rgba(255,255,255,.035)', scale: interpolate(frame, [0, 105], [1, 1.18], clamp)}}>DONE</div>

        <div style={{position: 'relative', width: 560, height: 330, borderRadius: 35, background: 'rgba(15,20,29,.94)', border: '1px solid rgba(255,255,255,.16)', boxShadow: '0 50px 140px rgba(0,0,0,.62)', scale: .88 + complete * .12, rotate: `${interpolate(frame, [0, 45], [-4, 0], clamp)}deg`, zIndex: 3}}>
          <div style={{height: 54, display: 'flex', alignItems: 'center', gap: 10, padding: '0 20px', borderBottom: '1px solid rgba(255,255,255,.09)'}}>
            {['#FF5F57', '#FFBD2E', '#28C840'].map((color) => <span key={color} style={{width: 13, height: 13, borderRadius: 99, background: color}} />)}
            <span style={{marginLeft: 12, color: colors.muted, fontFamily: monoFamily, fontSize: 18}}>agent-session</span>
          </div>
          <div style={{padding: '38px 42px'}}>
            <div style={{fontFamily: monoFamily, color: colors.muted, fontSize: 20}}>✓ tests passed</div>
            <div style={{fontFamily: monoFamily, color: colors.muted, fontSize: 20, marginTop: 13}}>✓ artifact exported</div>
            <div style={{display: 'flex', alignItems: 'center', gap: 16, marginTop: 34}}>
              <span style={{width: 44, height: 44, borderRadius: 99, display: 'grid', placeItems: 'center', background: colors.green, color: '#061109', fontSize: 26, fontWeight: 900}}>✓</span>
              <span style={{fontSize: 42, fontWeight: 820, letterSpacing: -1.6}}>Task complete</span>
            </div>
          </div>
        </div>

        {debris.map(([name, size, x, y, rotation], index) => {
          const fly = spring({frame: frame - 34 - index * 5, fps, config: {damping: 17, stiffness: 95}});
          return (
            <div key={name} style={{position: 'absolute', left: '50%', top: '50%', display: 'flex', alignItems: 'center', gap: 13, padding: '13px 17px', borderRadius: 15, background: 'rgba(20,25,35,.96)', border: `1px solid ${colors.orange}50`, boxShadow: '0 20px 55px rgba(0,0,0,.42)', translate: `${x * fly - 80}px ${y * fly - 24}px`, rotate: `${rotation * fly}deg`, scale: .72 + fly * .28, opacity: fly, zIndex: 5}}>
              <span style={{fontFamily: monoFamily, fontSize: 18}}>{name}</span>
              <span style={{color: colors.orange, fontSize: 17, fontWeight: 760}}>{size}</span>
            </div>
          );
        })}

        <div style={{position: 'absolute', left: 110, bottom: 160, fontSize: 82, lineHeight: .9, fontWeight: 860, letterSpacing: -4, opacity: interpolate(frame, [52, 69], [0, 1], clamp), translate: `${interpolate(frame, [52, 69], [-30, 0], clamp)}px 0px`}}>DONE.<br/><span style={{color: colors.orange}}>NOT GONE.</span></div>
      </div>
    </SceneShell>
  );
};
