import React from 'react';
import {Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {SceneShell} from '../components/SceneShell';
import {clamp, colors, monoFamily} from '../styles';

const toolNames = ['get_storage_summary', 'explain_growth', 'list_current_consumers', 'find_cleanup_candidates'];

export const EvidenceScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const power = spring({frame: frame - 8, fps, config: {damping: 16, stiffness: 110}});

  return (
    <SceneShell accent={colors.cyan} label="Local MCP · opt-in">
      <div style={{position: 'absolute', inset: 0, overflow: 'hidden'}}>
        <div style={{position: 'absolute', fontSize: 330, fontWeight: 950, letterSpacing: -24, color: 'rgba(83,226,243,.035)', left: 130, top: 320, rotate: '-8deg'}}>MCP</div>

        <div style={{position: 'absolute', left: 165, top: 395, width: 190, height: 190, borderRadius: 47, background: 'rgba(17,22,31,.96)', border: '1px solid rgba(255,255,255,.16)', display: 'grid', placeItems: 'center', boxShadow: '0 35px 100px rgba(0,0,0,.55)', scale: .8 + power * .2}}>
          <Img src={staticFile('app-icon.png')} style={{width: 132, height: 132, borderRadius: 31}} />
        </div>
        <div style={{position: 'absolute', left: 150, top: 612, display: 'flex', alignItems: 'center', gap: 12, fontSize: 19, color: colors.green}}>
          <span style={{width: 49, height: 28, borderRadius: 99, background: colors.green, padding: 3, display: 'flex', justifyContent: 'flex-end'}}><span style={{width: 22, height: 22, borderRadius: 99, background: '#06110A'}} /></span>
          AGENT ACCESS ON
        </div>

        <svg viewBox="0 0 1920 1080" style={{position: 'absolute', inset: 0, width: '100%', height: '100%'}}>
          <defs>
            <linearGradient id="mcp-line" x1="0" x2="1"><stop stopColor={colors.green}/><stop offset=".52" stopColor={colors.cyan}/><stop offset="1" stopColor={colors.blue}/></linearGradient>
          </defs>
          <path d="M355 490 C560 490 610 490 770 490" fill="none" stroke="url(#mcp-line)" strokeWidth="9" strokeLinecap="round" strokeDasharray="440" strokeDashoffset={440 * (1 - interpolate(frame, [12, 45], [0, 1], clamp))}/>
          <path d="M1040 490 C1250 490 1280 320 1480 320" fill="none" stroke="url(#mcp-line)" strokeWidth="9" strokeLinecap="round" strokeDasharray="540" strokeDashoffset={540 * (1 - interpolate(frame, [34, 77], [0, 1], clamp))}/>
          <path d="M1040 490 C1250 490 1280 660 1480 660" fill="none" stroke="url(#mcp-line)" strokeWidth="9" strokeLinecap="round" strokeDasharray="540" strokeDashoffset={540 * (1 - interpolate(frame, [47, 90], [0, 1], clamp))}/>
        </svg>

        <div style={{position: 'absolute', left: 765, top: 355, width: 280, height: 280, borderRadius: 64, display: 'grid', placeItems: 'center', background: 'linear-gradient(145deg, #123552, #101721)', border: '1px solid rgba(83,226,243,.42)', boxShadow: `0 0 ${interpolate(frame, [0, 90], [20, 90], clamp)}px rgba(83,226,243,.25)`, scale: .76 + power * .24, rotate: '5deg'}}>
          <div style={{textAlign: 'center', rotate: '-5deg'}}>
            <div style={{fontSize: 70, fontWeight: 920, letterSpacing: -3}}>MCP</div>
            <div style={{fontFamily: monoFamily, fontSize: 17, color: colors.cyan, marginTop: 6}}>disk-witness</div>
            <div style={{fontSize: 16, color: colors.green, marginTop: 15, letterSpacing: 1.5}}>READ ONLY</div>
          </div>
        </div>

        {toolNames.map((tool, index) => {
          const travel = interpolate(frame, [35 + index * 12, 82 + index * 12], [0, 1], clamp);
          return <div key={tool} style={{position: 'absolute', left: 1000 + travel * 320, top: 376 + index * 74 + Math.sin(travel * Math.PI) * (index % 2 ? 34 : -34), padding: '10px 14px', borderRadius: 11, background: 'rgba(11,18,27,.94)', border: '1px solid rgba(83,226,243,.3)', fontFamily: monoFamily, color: colors.cyan, fontSize: 16, opacity: interpolate(travel, [0, .15, .86, 1], [0, 1, 1, 0], clamp), scale: .82 + travel * .18}}>{tool}</div>;
        })}

        {[
          ['Codex', 245],
          ['Claude', 585],
        ].map(([name, top], index) => (
          <div key={String(name)} style={{position: 'absolute', right: 112, top: Number(top), width: 250, height: 150, borderRadius: 31, background: 'rgba(16,22,31,.92)', border: '1px solid rgba(255,255,255,.14)', display: 'grid', placeItems: 'center', boxShadow: '0 28px 80px rgba(0,0,0,.45)', opacity: interpolate(frame, [56 + index * 15, 76 + index * 15], [0, 1], clamp)}}>
            <div style={{textAlign: 'center'}}><div style={{fontSize: 43, fontWeight: 850}}>{name}</div><div style={{fontSize: 17, color: colors.cyan, marginTop: 7, letterSpacing: 1.4}}>MCP CLIENT</div></div>
          </div>
        ))}

        <div style={{position: 'absolute', left: 112, top: 155, fontSize: 84, fontWeight: 900, letterSpacing: -4.5, lineHeight: .92}}>ASK.<br/><span style={{color: colors.cyan}}>DON’T RESCAN.</span></div>
        <div style={{position: 'absolute', left: 760, bottom: 145, display: 'flex', alignItems: 'center', gap: 18}}>
          <span style={{fontSize: 24, color: colors.muted}}>10 evidence tools</span>
          <span style={{padding: '13px 18px', borderRadius: 999, background: 'rgba(66,212,119,.12)', border: '1px solid rgba(66,212,119,.35)', color: colors.green, fontSize: 20, fontWeight: 770}}>NO DELETE TOOL</span>
        </div>
      </div>
    </SceneShell>
  );
};
