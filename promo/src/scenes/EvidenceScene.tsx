import React from 'react';
import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {Headline, Kicker, SceneShell, Supporting} from '../components/SceneShell';
import {colors, monoFamily, panel} from '../styles';

const evidenceFiles = ['codex-brief.md', 'current-consumers.json', 'change-events.jsonl', 'integrity.json'];

export const EvidenceScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const flow = interpolate(frame, [22, 125], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <SceneShell duration={150} accent={colors.green}>
      <div style={{display: 'grid', gridTemplateColumns: '.95fr 1.05fr', gap: 72, height: '100%', alignItems: 'center'}}>
        <div>
          <Kicker color={colors.green}>05 · Ready for your agent</Kicker>
          <Headline>Evidence in. Guesswork out.</Headline>
          <Supporting>Export a verified bundle or enable local, read-only MCP access for Codex and Claude.</Supporting>
        </div>
        <div style={{position: 'relative', height: 600}}>
          <svg viewBox="0 0 880 600" style={{position: 'absolute', inset: 0, width: '100%', height: '100%'}}>
            <path d="M345 300 C470 300 485 155 635 155" fill="none" stroke="rgba(98,228,245,.25)" strokeWidth="10" />
            <path d="M345 300 C470 300 485 445 635 445" fill="none" stroke="rgba(98,228,245,.25)" strokeWidth="10" />
            <circle cx={345 + flow * 290} cy={300 - Math.sin(flow * Math.PI) * 145} r="12" fill={colors.cyan} />
            <circle cx={345 + flow * 290} cy={300 + Math.sin(flow * Math.PI) * 145} r="12" fill={colors.cyan} />
          </svg>
          <div style={{...panel, position: 'absolute', left: 0, top: 115, width: 340, padding: 25}}>
            <div style={{fontSize: 28, fontWeight: 740}}>Evidence bundle</div>
            <div style={{display: 'grid', gap: 11, marginTop: 20}}>
              {evidenceFiles.map((file, index) => {
                const entrance = spring({frame: frame - 10 - index * 9, fps, config: {damping: 18}});
                return <div key={file} style={{opacity: entrance, fontFamily: monoFamily, color: colors.muted, fontSize: 19}}>✓ {file}</div>;
              })}
            </div>
            <div style={{marginTop: 22, padding: '10px 14px', display: 'inline-block', borderRadius: 99, color: colors.green, background: 'rgba(85,214,138,.1)', fontSize: 20}}>integrity verified</div>
          </div>
          {[
            ['Codex', 92],
            ['Claude', 382],
          ].map(([name, top]) => (
            <div key={name} style={{...panel, position: 'absolute', left: 630, top, width: 235, height: 126, display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center'}}>
              <div style={{fontSize: 32, fontWeight: 760}}>{name}</div>
              <div style={{fontSize: 20, color: colors.cyan, marginTop: 8}}>read-only context</div>
            </div>
          ))}
          <div style={{position: 'absolute', left: 385, top: 273, padding: '12px 18px', borderRadius: 99, background: '#102436', border: '1px solid rgba(98,228,245,.28)', color: colors.cyan, fontSize: 21, fontWeight: 690}}>local only</div>
        </div>
      </div>
    </SceneShell>
  );
};
