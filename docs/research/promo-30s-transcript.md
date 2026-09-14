# Disk Steward — 30-second product story

This is the production transcript, visual plan, and claim ledger for the public Disk Steward promotion. The video uses the real application UI, original motion graphics, locally generated narration and score, and no user runtime evidence.

## Timecoded transcript

| Time | Narration and burned-in caption | Visual intent |
| --- | --- | --- |
| 00:00.4–00:02.1 | **Your coding agent finished.** | Cold-open on a completed task. |
| 00:02.1–00:03.9 | **Its disk footprint may not.** | The hook turns from success to a persistent footprint. |
| 00:03.9–00:07.2 | **Worktrees, caches, downloads, artifacts—quietly left behind.** | Familiar local artifacts remain after completion. |
| 00:07.2–00:10.8 | **Then System Data gets huge. But a category is not a cause.** | An illustrative aggregate grows while the real product is revealed early. |
| 00:10.8–00:13.2 | **Disk Steward was already watching.** | The real Disk Steward status board is the proof. |
| 00:13.2–00:17.9 | **It separates whole-disk growth from the folders you choose, and keeps bounded evidence.** | Three deliberately distinct scopes: capacity, detailed roots, and retained history. |
| 00:17.9–00:20.9 | **It records what changed, disappeared, or remains uncertain.** | A concrete A/B/C lifecycle shows two current objects and one observed removal. |
| 00:20.9–00:22.6 | **Turn on local MCP.** | The opt-in Agent Access toggle establishes the trust boundary. |
| 00:22.6–00:26.6 | **Codex and Claude get ten read-only tools to ask what grew, what remains, and what deserves review.** | Four real tool names are shown, with six more identified as part of the bounded inventory. |
| 00:26.6–00:28.0 | **MCP cannot delete a file.** | The local-only connector explicitly exposes no deletion capability. |
| 00:28.0–00:29.4 | **Start with evidence. Then decide what to delete.** | The product benefit resolves into a safe human decision. |
| 00:29.4–00:30.0 | **Disk Steward.** | Product icon, promise, source repository, platform, and license. |

## Full voiceover

> Your coding agent finished. Its disk footprint may not. Worktrees, caches, downloads, artifacts—quietly left behind. Then System Data gets huge. But a category is not a cause. Disk Steward was already watching. It separates whole-disk growth from the folders you choose, keeps bounded evidence, and records what changed, disappeared, or remains uncertain. Turn on local MCP. Codex and Claude can ask what grew, what remains, and what deserves review—with ten read-only tools. MCP cannot delete a file. Start with evidence. Then decide what to delete. Disk Steward.

## Creative rationale

The cut applies the principles established in the “Improve Remotion VC pitch deck” session: lead with changed behavior rather than architecture, use one concrete scenario, show the real product as proof, give each frame one dominant idea, and preserve honest evidence boundaries. The second visual pass replaces presentation-like copy blocks with animated cause-and-effect: task debris persists, an aggregate storage ring grows, the real product floats into focus, an object disappears from the evidence timeline, and MCP tool calls visibly travel from Disk Steward to agent clients.

Current product-video guidance informed the refinement. The real interface appears by roughly second 7 instead of waiting until the midpoint, and the strongest narrative contrast lands in the opening seconds. Motion carries meaning instead of decorating static cards; small amounts of depth, occlusion, glow, and scale establish hierarchy around the product UI and MCP boundary. Vimeo describes motion design as movement that guides attention and recommends showing product behavior rather than reading a feature list. Apple recommends purposeful motion and using depth only when it clarifies hierarchy. [Vimeo motion-design guide](https://vimeo.com/blog/post/what-is-motion-design), [Vimeo product-video guidance](https://vimeo.com/create/product), [Apple Human Interface Guidelines: Motion](https://developer.apple.com/design/human-interface-guidelines/motion), [Apple spatial-layout guidance](https://developer.apple.com/design/human-interface-guidelines/spatial-layout/)

## Claim boundaries

The story makes a narrow claim: local development can leave worktrees, caches, downloads, and artifacts that users later need to understand. It does not claim that every agent session grows the disk, that AI agents are the sole cause of macOS System Data, or that the illustrative gigabyte values came from telemetry. Apple describes System Data as a broad storage category, so the video explicitly says that the category is not itself a file-level cause. [Apple: Free up storage space on Mac](https://support.apple.com/en-gb/102624)

Product facts represented by the video:

- Whole-volume capacity and detailed watched-root evidence are separate scopes.
- Current objects, observed removals, and incomplete coverage are distinguishable states.
- Evidence retention is bounded; older detail is compacted instead of growing forever.
- Export is manual and integrity-verifiable.
- MCP access is local, read-only, and off by default on a fresh installation.
- Disk Steward exposes no deletion tool and does not automatically clean files.

Those facts are specified in the repository’s [evidence lifecycle](../architecture/evidence-object-lifecycle.md), [export contract](../architecture/evidence-export.md), [MCP contract](../architecture/mcp.md), and [privacy model](../operations/privacy-and-retention.md).

## Reproduction

The composition is exactly 1920×1080, 30 fps, and 900 frames. From `promo/`:

```sh
npm install
npm run score
npm run typecheck
npm run poster
npm run render
```

The narration source is `promo/voiceover.txt`. The original 30-second score is generated deterministically by `promo/scripts/generate-score.cjs`. Burned-in captions are the accessibility and timing authority if the narration is replaced later.
