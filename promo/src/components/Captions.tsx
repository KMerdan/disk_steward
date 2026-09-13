import React from 'react';
import {useCurrentFrame, useVideoConfig} from 'remotion';
import {colors, fontFamily} from '../styles';

const captions = [
  [0, 88, 'AI coding agents move fast.'],
  [88, 238, 'But their worktrees, caches, downloads, and artifacts can keep growing after the task ends.'],
  [238, 350, 'Weeks later, System Data is huge.'],
  [350, 468, 'Cleanup begins with another slow, uncertain investigation.'],
  [468, 600, 'Disk Steward watches capacity and the folders you choose.'],
  [600, 735, 'It keeps bounded evidence and exports read-only context to Codex or Claude.'],
  [735, 825, 'Your agent starts with evidence, not guesses.'],
  [825, 900, 'Disk Steward. Know what grew before you delete.'],
] as const;

export const Captions: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const current = captions.find(([start, end]) => frame >= start && frame < end);
  if (!current) return null;

  return (
    <div
      aria-label={`Caption at ${(frame / fps).toFixed(1)} seconds: ${current[2]}`}
      style={{
        position: 'absolute',
        left: 170,
        right: 170,
        bottom: 42,
        display: 'flex',
        justifyContent: 'center',
        zIndex: 100,
        fontFamily,
      }}
    >
      <div
        style={{
          maxWidth: 1450,
          padding: '15px 26px 17px',
          borderRadius: 18,
          background: 'rgba(0,0,0,.72)',
          border: '1px solid rgba(255,255,255,.16)',
          color: colors.ink,
          textAlign: 'center',
          fontSize: 34,
          lineHeight: 1.18,
          fontWeight: 620,
          letterSpacing: -0.35,
          boxShadow: '0 14px 35px rgba(0,0,0,.3)',
        }}
      >
        {current[2]}
      </div>
    </div>
  );
};
