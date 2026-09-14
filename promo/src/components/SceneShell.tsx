import React from 'react';
import {Img, interpolate, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {clamp, colors, scene} from '../styles';

export const SceneShell: React.FC<{
  children: React.ReactNode;
  accent?: string;
  label?: string;
}> = ({children, accent = colors.blue, label}) => {
  const frame = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();

  return (
    <div
      style={{
        ...scene,
        background: colors.background,
      }}
    >
      <div
        style={{
          position: 'absolute',
          inset: 0,
          opacity: 0.08,
          backgroundImage:
            'linear-gradient(rgba(255,255,255,.07) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,.07) 1px, transparent 1px)',
          backgroundSize: '64px 64px',
          maskImage: 'linear-gradient(to bottom, rgba(0,0,0,.8), transparent 88%)',
        }}
      />
      <div style={{position: 'absolute', width: 980, height: 980, borderRadius: '50%', right: -260, top: -390, background: accent, opacity: 0.16, filter: 'blur(140px)', scale: interpolate(frame, [0, durationInFrames], [.92, 1.14], clamp), translate: `${interpolate(frame, [0, durationInFrames], [0, -70], clamp)}px ${interpolate(frame, [0, durationInFrames], [0, 85], clamp)}px`}} />
      <div style={{position: 'absolute', width: 720, height: 720, borderRadius: '50%', left: -290, bottom: -360, background: '#153E78', opacity: 0.18, filter: 'blur(130px)', scale: interpolate(frame, [0, durationInFrames], [1.08, .9], clamp)}} />
      <div style={{position: 'absolute', left: 42, top: 34, display: 'flex', alignItems: 'center', gap: 13, zIndex: 4}}>
        <Img src={staticFile('app-icon.png')} style={{width: 36, height: 36, borderRadius: 9}} />
        <span style={{fontSize: 20, fontWeight: 720, letterSpacing: -0.2}}>Disk Steward</span>
        {label ? <span style={{fontSize: 18, color: colors.muted}}>· {label}</span> : null}
      </div>
      <div style={{position: 'relative', height: '100%', perspective: 1600}}>{children}</div>
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
      fontSize: 25,
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
      fontSize: 104,
      lineHeight: 0.96,
      letterSpacing: -5.6,
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
      fontSize: 38,
      lineHeight: 1.25,
      letterSpacing: -0.7,
    }}
  >
    {children}
  </div>
);
