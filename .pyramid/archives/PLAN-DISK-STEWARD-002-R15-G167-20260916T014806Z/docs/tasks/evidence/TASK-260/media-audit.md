# TASK-260 — promotion media audit

Date: 2026-09-13 (Asia/Tokyo)

## Result

Pass. The public promotion is a reproducible Remotion composition with an H.264 video stream of exactly 900 frames at 30 fps (30.000 seconds), 1920×1080 output, AAC voiceover, burned-in captions, a real Disk Steward status-board capture, and no third-party footage or music.

The MP4 container reports 30.058667 seconds because of AAC encoder padding; the video stream itself is exactly 900 / 30 = 30.000 seconds. The narration ends at 27.802404 seconds, leaving the final brand card readable through frame 899.

## Media inspection

```text
Video codec:        h264
Dimensions:         1920 × 1080
Frame rate:         30/1
Video frames:       900
Video duration:     30.000 seconds
Audio codec:        aac
Container duration: 30.058667 seconds
MP4 size:           4,343,998 bytes
```

The Remotion-rendered poster is frame 835. Additional review stills were rendered at frames 75, 225, 375, 555, and 735. Visual inspection confirmed:

- headline, supporting copy, and captions remain within the 1920×1080 safe area;
- illustrative storage sizes are presented as scene graphics, not measured telemetry;
- the actual dark-mode Disk Steward screenshot is legible and labeled as the status board;
- the evidence handoff is marked `local only`, `read-only context`, and `integrity verified`;
- the final card identifies the public repository, MIT license, macOS platform, and non-destructive promise.

## Reproducibility checks

```text
npm install       PASS — 255 packages audited, 0 vulnerabilities
npm run typecheck PASS — TypeScript no-emit check
npm run poster    PASS — frame 835 rendered
npm run render    PASS — 900 frames encoded; 4.3 MB output
```

Inputs and source are retained under `promo/`. Output is retained under `docs/media/`. The timecoded narration and primary-source claim ledger are in `docs/research/promo-30s-transcript.md`.

## Claim review

The script was checked against official OpenAI, Anthropic, and Apple documentation. It describes local-agent work products as a plausible source of disk growth, not a measured universal behavior. It does not claim that all System Data comes from AI agents, that Disk Steward knows unobserved history, or that the app automatically deletes anything.
