import React from 'react';
import {interpolate, useCurrentFrame} from 'remotion';
import {Headline, Kicker, SceneShell, Supporting} from '../components/SceneShell';
import {colors, panel} from '../styles';

export const MysteryScene: React.FC = () => {
  const frame = useCurrentFrame();
  const growth = interpolate(frame, [10, 110], [48, 184], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const dash = interpolate(frame, [0, 150], [1200, 0]);
  return (
    <SceneShell duration={150} accent={colors.red}>
      <div style={{display: 'grid', gridTemplateColumns: '.92fr 1.08fr', gap: 78, height: '100%', alignItems: 'center'}}>
        <div>
          <Kicker color={colors.red}>02 · The surprise</Kicker>
          <Headline>“System Data” is huge. What actually grew?</Headline>
          <Supporting>A capacity number cannot explain which project, cache, download, or artifact caused it.</Supporting>
        </div>
        <div style={{...panel, padding: 36, minHeight: 545}}>
          <div style={{fontSize: 28, color: colors.muted}}>Macintosh HD</div>
          <div style={{display: 'flex', alignItems: 'baseline', gap: 16, marginTop: 8}}>
            <span style={{fontSize: 108, fontWeight: 760, letterSpacing: -6}}>{growth.toFixed(0)}</span>
            <span style={{fontSize: 38, color: colors.red, fontWeight: 700}}>GB System Data</span>
          </div>
          <svg viewBox="0 0 800 240" style={{width: '100%', marginTop: 8}}>
            <defs>
              <linearGradient id="area" x1="0" x2="0" y1="0" y2="1">
                <stop offset="0" stopColor={colors.red} stopOpacity=".42" />
                <stop offset="1" stopColor={colors.red} stopOpacity="0" />
              </linearGradient>
            </defs>
            <path d="M10 210 C120 205 170 190 250 194 C350 200 405 160 475 169 C560 179 610 105 670 118 C720 128 752 58 790 35 L790 230 L10 230Z" fill="url(#area)" />
            <path d="M10 210 C120 205 170 190 250 194 C350 200 405 160 475 169 C560 179 610 105 670 118 C720 128 752 58 790 35" fill="none" stroke={colors.red} strokeWidth="7" strokeLinecap="round" strokeDasharray="1200" strokeDashoffset={dash} />
          </svg>
          <div style={{display: 'flex', gap: 14, flexWrap: 'wrap', marginTop: 18}}>
            {['Which files?', 'Created when?', 'Still present?', 'Safe to review?'].map((item, index) => (
              <div key={item} style={{padding: '14px 19px', borderRadius: 14, border: `1px solid ${colors.line}`, color: index === 3 ? colors.amber : colors.muted, fontSize: 25}}>{item}</div>
            ))}
          </div>
        </div>
      </div>
    </SceneShell>
  );
};
