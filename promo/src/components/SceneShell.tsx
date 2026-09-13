import React from 'react';
import {interpolate, useCurrentFrame} from 'remotion';
import {colors, scene} from '../styles';

export const SceneShell: React.FC<{
  children: React.ReactNode;
  duration: number;
  accent?: string;
}> = ({children, duration, accent = colors.blue}) => {
  const frame = useCurrentFrame();
  const opacity = interpolate(
    frame,
    [0, 12, duration - 12, duration],
    [0, 1, 1, 0],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'},
  );
  const rise = interpolate(frame, [0, 20], [22, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <div
      style={{
        ...scene,
        opacity,
        transform: `translateY(${rise}px)`,
        background: `radial-gradient(circle at 80% 20%, ${accent}24 0, transparent 34%), radial-gradient(circle at 18% 92%, #214d7d35 0, transparent 33%), #080C14`,
      }}
    >
      <div
        style={{
          position: 'absolute',
          inset: 0,
          opacity: 0.18,
          backgroundImage:
            'linear-gradient(rgba(255,255,255,.07) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,.07) 1px, transparent 1px)',
          backgroundSize: '64px 64px',
          maskImage: 'linear-gradient(to bottom, rgba(0,0,0,.8), transparent 88%)',
        }}
      />
      <div style={{position: 'relative', height: '100%'}}>{children}</div>
    </div>
  );
};

export const Kicker: React.FC<{children: React.ReactNode; color?: string}> = ({
  children,
  color = colors.cyan,
}) => (
  <div
    style={{
      color,
      fontSize: 28,
      fontWeight: 700,
      letterSpacing: 2.8,
      textTransform: 'uppercase',
      marginBottom: 22,
    }}
  >
    {children}
  </div>
);

export const Headline: React.FC<{children: React.ReactNode; maxWidth?: number}> = ({
  children,
  maxWidth = 1040,
}) => (
  <div
    style={{
      maxWidth,
      fontSize: 88,
      lineHeight: 0.98,
      letterSpacing: -4.5,
      fontWeight: 760,
    }}
  >
    {children}
  </div>
);

export const Supporting: React.FC<{children: React.ReactNode; maxWidth?: number}> = ({
  children,
  maxWidth = 920,
}) => (
  <div
    style={{
      maxWidth,
      marginTop: 30,
      color: colors.muted,
      fontSize: 41,
      lineHeight: 1.25,
      letterSpacing: -0.7,
    }}
  >
    {children}
  </div>
);
