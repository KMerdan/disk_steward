import React from 'react';
import {Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {SceneShell} from '../components/SceneShell';
import {clamp, colors} from '../styles';

const signals = [
  ['WHOLE DISK', 'capacity'],
  ['CHOSEN ROOTS', 'evidence'],
  ['BOUNDED', 'history'],
] as const;

export const StewardScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const hero = spring({frame: frame - 4, fps, config: {damping: 19, stiffness: 80}});

  return (
    <SceneShell accent={colors.blue} label="Always ready">
      <div style={{position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', overflow: 'hidden'}}>
        <div style={{position: 'absolute', fontSize: 205, fontWeight: 920, letterSpacing: -12, color: 'rgba(255,255,255,.035)', whiteSpace: 'nowrap', translate: `${interpolate(frame, [0, 225], [110, -120], clamp)}px -25px`}}>ALREADY WATCHING</div>

        <div style={{position: 'relative', height: 815, width: 630, transformStyle: 'preserve-3d', scale: .86 + hero * .14, rotate: `${interpolate(frame, [0, 225], [-4, 3], clamp)}deg`, translate: `0px ${interpolate(frame, [0, 225], [22, -10], clamp)}px`}}>
          <div style={{position: 'absolute', inset: 16, borderRadius: 56, background: 'linear-gradient(145deg, rgba(49,135,255,.32), rgba(83,226,243,.06))', filter: 'blur(22px)', scale: 1.05}} />
          <div style={{position: 'absolute', inset: 0, padding: 16, borderRadius: 48, background: 'rgba(16,21,31,.92)', border: '1px solid rgba(255,255,255,.17)', boxShadow: '0 60px 150px rgba(0,0,0,.68)'}}>
            <Img src={staticFile('disk-steward-dark.png')} style={{height: '100%', width: '100%', objectFit: 'cover', borderRadius: 34}} />
          </div>
        </div>

        {signals.map(([title, detail], index) => {
          const enter = spring({frame: frame - 28 - index * 24, fps, config: {damping: 17}});
          const side = index === 1 ? 1 : -1;
          const y = -230 + index * 230;
          return (
            <div key={title} style={{position: 'absolute', left: '50%', top: '50%', minWidth: 260, padding: '17px 20px', borderRadius: 19, background: 'rgba(12,17,25,.9)', border: `1px solid ${index === 2 ? colors.green : colors.blue}55`, boxShadow: '0 24px 70px rgba(0,0,0,.46)', translate: `${side * (390 + (1 - enter) * 110) - 130}px ${y - 42}px`, opacity: enter}}>
              <div style={{fontSize: 21, fontWeight: 820, letterSpacing: 1.1, color: index === 2 ? colors.green : colors.cyan}}>{title}</div>
              <div style={{fontSize: 20, color: colors.muted, marginTop: 4}}>{detail}</div>
            </div>
          );
        })}

        <div style={{position: 'absolute', left: 112, top: 170, fontSize: 72, fontWeight: 880, letterSpacing: -3.5, lineHeight: .95, opacity: interpolate(frame, [12, 32], [0, 1], clamp)}}>QUIET.<br/><span style={{color: colors.cyan}}>READY.</span></div>
      </div>
    </SceneShell>
  );
};
