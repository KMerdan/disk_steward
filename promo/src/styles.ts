import type {CSSProperties} from 'react';

export const colors = {
  ink: '#F7F8FB',
  muted: '#A7AFBD',
  blue: '#3187FF',
  cyan: '#53E2F3',
  green: '#42D477',
  amber: '#FFAA29',
  orange: '#FF7A16',
  red: '#FF5F57',
  panel: 'rgba(16, 21, 31, 0.84)',
  line: 'rgba(255,255,255,0.11)',
  background: '#05070C',
};

export const fontFamily =
  '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif';

export const monoFamily =
  '"SFMono-Regular", "SF Mono", Menlo, ui-monospace, monospace';

export const scene: CSSProperties = {
  position: 'absolute',
  inset: 0,
  padding: '88px 112px 132px',
  color: colors.ink,
  fontFamily,
  overflow: 'hidden',
};

export const panel: CSSProperties = {
  border: `1px solid ${colors.line}`,
  borderRadius: 32,
  background: colors.panel,
  boxShadow: '0 38px 110px rgba(0,0,0,0.42)',
};

export const clamp = {
  extrapolateLeft: 'clamp' as const,
  extrapolateRight: 'clamp' as const,
};
