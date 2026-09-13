import React from 'react';
import {Img, interpolate, staticFile, useCurrentFrame} from 'remotion';
import {Headline, Kicker, SceneShell, Supporting} from '../components/SceneShell';
import {colors, panel} from '../styles';

const callouts = [
  ['Whole-volume truth', 'Capacity is never confused with file coverage.'],
  ['Folders you choose', 'Exact metadata stays scoped and local.'],
  ['Bounded history', 'Old detail compacts instead of growing forever.'],
];

export const StewardScene: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <SceneShell duration={210} accent={colors.blue}>
      <div style={{display: 'grid', gridTemplateColumns: '.84fr 1.16fr', gap: 70, height: '100%', alignItems: 'center'}}>
        <div>
          <Kicker>04 · Disk Steward</Kicker>
          <Headline maxWidth={760}>Evidence that is already there.</Headline>
          <Supporting maxWidth={720}>Monitor capacity and selected folders continuously—without deleting a thing.</Supporting>
          <div style={{display: 'grid', gap: 14, marginTop: 34}}>
            {callouts.map(([title, detail], index) => {
              const opacity = interpolate(frame, [26 + index * 25, 45 + index * 25], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
              return (
                <div key={title} style={{opacity, display: 'flex', gap: 17, padding: '17px 19px', borderRadius: 16, background: 'rgba(94,167,255,.08)', border: '1px solid rgba(94,167,255,.18)'}}>
                  <div style={{width: 12, height: 12, borderRadius: 20, background: index === 2 ? colors.green : colors.blue, marginTop: 11, flex: 'none'}} />
                  <div><div style={{fontSize: 27, fontWeight: 700}}>{title}</div><div style={{fontSize: 21, color: colors.muted, marginTop: 4, lineHeight: 1.25}}>{detail}</div></div>
                </div>
              );
            })}
          </div>
        </div>
        <div style={{...panel, padding: 18, borderRadius: 38, transform: `perspective(1600px) rotateY(-${interpolate(frame, [0, 50], [6, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'})}deg)`, position: 'relative'}}>
          <div style={{height: 42, display: 'flex', alignItems: 'center', gap: 10, paddingLeft: 10}}>
            <div style={{width: 12, height: 12, borderRadius: 20, background: '#FF6258'}} />
            <div style={{width: 12, height: 12, borderRadius: 20, background: '#FFBE3D'}} />
            <div style={{width: 12, height: 12, borderRadius: 20, background: '#28C941'}} />
            <div style={{marginLeft: 14, color: colors.muted, fontSize: 20}}>Disk Steward · status board</div>
          </div>
          <Img src={staticFile('disk-steward-dark.png')} style={{width: '100%', borderRadius: 25, display: 'block', border: `1px solid ${colors.line}`}} />
          <div style={{position: 'absolute', right: 42, top: 70, padding: '10px 16px', background: colors.green, color: '#07110C', borderRadius: 99, fontSize: 21, fontWeight: 780, boxShadow: `0 10px 30px ${colors.green}55`}}>Monitoring active</div>
        </div>
      </div>
    </SceneShell>
  );
};
