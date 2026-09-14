import type {Caption} from '@remotion/captions';
import React from 'react';
import {interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {clamp, colors, fontFamily} from '../styles';

const caption = (startMs: number, endMs: number, text: string): Caption => ({
  text,
  startMs,
  endMs,
  timestampMs: null,
  confidence: null,
});

const captions: Caption[] = [
  caption(400, 2100, 'Your coding agent finished.'),
  caption(2100, 3900, 'Its disk footprint may not.'),
  caption(3900, 7200, 'Worktrees, caches, downloads, artifacts—quietly left behind.'),
  caption(7200, 10800, 'Then System Data gets huge. But a category is not a cause.'),
  caption(10800, 13200, 'Disk Steward was already watching.'),
  caption(13200, 17900, 'It separates whole-disk growth from the folders you choose, and keeps bounded evidence.'),
  caption(17900, 20900, 'It records what changed, disappeared, or remains uncertain.'),
  caption(20900, 22600, 'Turn on local MCP.'),
  caption(22600, 26600, 'Codex and Claude get ten read-only tools to ask what grew, what remains, and what deserves review.'),
  caption(26600, 28000, 'MCP cannot delete a file.'),
  caption(28000, 29400, 'Start with evidence. Then decide what to delete.'),
  caption(29400, 30000, 'Disk Steward.'),
];

export const Captions: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const nowMs = (frame / fps) * 1000;
  const current = captions.find(({startMs, endMs}) => nowMs >= startMs && nowMs < endMs);
  if (!current) return null;
  const localMs = nowMs - current.startMs;
  const entrance = interpolate(localMs, [0, 150], [0, 1], clamp);

  return (
    <div
      aria-label={`Caption at ${(frame / fps).toFixed(1)} seconds: ${current.text}`}
      style={{
        position: 'absolute',
        left: 112,
        right: 112,
        bottom: 38,
        display: 'flex',
        justifyContent: 'flex-start',
        zIndex: 100,
        fontFamily,
      }}
    >
      <div
        style={{
          maxWidth: 1080,
          padding: '8px 0 9px 18px',
          borderLeft: `4px solid ${colors.orange}`,
          background: 'linear-gradient(90deg, rgba(5,7,12,.82), rgba(5,7,12,0))',
          color: colors.ink,
          textAlign: 'left',
          fontSize: 27,
          lineHeight: 1.18,
          fontWeight: 610,
          letterSpacing: -0.2,
          opacity: entrance,
          transform: `translateY(${(1 - entrance) * 9}px)`,
        }}
      >
        {current.text}
      </div>
    </div>
  );
};
