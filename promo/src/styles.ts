import type {CSSProperties} from 'react';

export const colors = {
  ink: '#F4F7FB',
  muted: '#AAB4C4',
  blue: '#5EA7FF',
  cyan: '#62E4F5',
  green: '#55D68A',
  amber: '#FFB958',
  red: '#FF706B',
  panel: 'rgba(20, 27, 39, 0.82)',
  line: 'rgba(255,255,255,0.11)',
  background: '#080C14',
};

export const fontFamily =
  '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif';

export const monoFamily =
  '"SFMono-Regular", "SF Mono", Menlo, ui-monospace, monospace';

export const scene: CSSProperties = {
  position: 'absolute',
  inset: 0,
  padding: '92px 112px 116px',
  color: colors.ink,
  fontFamily,
  overflow: 'hidden',
};

export const panel: CSSProperties = {
  border: `1px solid ${colors.line}`,
  borderRadius: 32,
  background: colors.panel,
  boxShadow: '0 36px 100px rgba(0,0,0,0.36)',
};
