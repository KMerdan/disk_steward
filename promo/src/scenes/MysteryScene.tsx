import React from 'react';
import {interpolate, useCurrentFrame} from 'remotion';
import {SceneShell} from '../components/SceneShell';
import {clamp, colors} from '../styles';

const labels = ['Caches', 'Worktrees', 'Downloads', 'Artifacts'];

export const MysteryScene: React.FC = () => {
  const frame = useCurrentFrame();
  const growth = interpolate(frame, [6, 88], [48, 184], clamp);

  return (
    <SceneShell accent={colors.red} label="A category is not a cause">
      <div style={{position: 'absolute', inset: 0, display: 'grid', placeItems: 'center'}}>
        <div style={{position: 'relative', width: 690, height: 690, display: 'grid', placeItems: 'center', rotate: `${interpolate(frame, [0, 135], [-8, 4], clamp)}deg`}}>
          <div style={{position: 'absolute', inset: 0, borderRadius: '50%', background: `conic-gradient(from -90deg, ${colors.orange} 0deg, ${colors.red} ${interpolate(growth, [48, 184], [75, 310], clamp)}deg, rgba(255,255,255,.07) 310deg)`, filter: 'drop-shadow(0 45px 90px rgba(255,80,55,.2))'}} />
          <div style={{position: 'absolute', inset: 52, borderRadius: '50%', background: colors.background, boxShadow: 'inset 0 0 60px rgba(0,0,0,.65)'}} />
          <div style={{position: 'relative', textAlign: 'center'}}>
            <div style={{fontSize: 184, fontWeight: 900, letterSpacing: -12, lineHeight: .86}}>{Math.round(growth)}</div>
            <div style={{fontSize: 35, color: colors.red, fontWeight: 800, letterSpacing: 4}}>GB · SYSTEM DATA</div>
          </div>
        </div>

        {labels.map((label, index) => {
          const angle = index * Math.PI / 2 + frame * .012;
          const radius = 420;
          return <div key={label} style={{position: 'absolute', left: `calc(50% + ${Math.cos(angle) * radius}px)`, top: `calc(50% + ${Math.sin(angle) * radius}px)`, translate: '-50% -50%', padding: '12px 17px', borderRadius: 999, border: '1px solid rgba(255,255,255,.14)', background: 'rgba(9,12,18,.9)', color: colors.muted, fontSize: 20}}>{label}?</div>;
        })}

        <div style={{position: 'absolute', right: 110, bottom: 170, textAlign: 'right', opacity: interpolate(frame, [63, 82], [0, 1], clamp)}}>
          <div style={{fontSize: 27, color: colors.muted}}>A category tells you</div>
          <div style={{fontSize: 72, fontWeight: 870, letterSpacing: -3.5}}>HOW MUCH.</div>
          <div style={{fontSize: 72, fontWeight: 870, letterSpacing: -3.5, color: colors.red}}>NOT WHY.</div>
        </div>
      </div>
    </SceneShell>
  );
};
