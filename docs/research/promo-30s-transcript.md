# Disk Steward — 30-second product story

This is the narration, on-screen caption plan, and claim ledger for the public 30-second Disk Steward promotion. The video uses no user runtime evidence, no third-party footage, and no unsupported statistics.

## Timecoded transcript

| Time | Narration and burned-in caption | Visual intent |
| --- | --- | --- |
| 00:00–00:03 | **AI coding agents move fast.** | A completed local agent task; generated work products begin to accumulate. |
| 00:03–00:08 | **But their worktrees, caches, downloads, and artifacts can keep growing after the task ends.** | Familiar local artifact categories and a rising storage gauge. The sizes are illustrative UI, not product telemetry. |
| 00:08–00:12 | **Weeks later, System Data is huge.** | The macOS storage mystery: a large aggregate number without file-level causation. |
| 00:12–00:16 | **Cleanup begins with another slow, uncertain investigation.** | A new scan starts from scratch and explicitly remains incomplete. |
| 00:16–00:20 | **Disk Steward watches capacity and the folders you choose.** | The real Disk Steward status-board capture appears with the product's two honest monitoring scopes. |
| 00:20–00:24.5 | **It keeps bounded evidence and exports read-only context to Codex or Claude.** | A small integrity-checked evidence bundle flows locally to two agent endpoints. |
| 00:24.5–00:27.5 | **Your agent starts with evidence, not guesses.** | The handoff resolves into verified, local, read-only context. |
| 00:27.5–00:30 | **Disk Steward. Know what grew before you delete.** | Product icon, name, promise, repository, MIT license, and macOS identity. |

## Full voiceover

> AI coding agents move fast. But their worktrees, caches, downloads, and artifacts can keep growing after the task ends. Weeks later, System Data is huge. Cleanup begins with another slow, uncertain investigation. Disk Steward watches capacity and the folders you choose. It keeps bounded evidence and exports read-only context to Codex or Claude. Your agent starts with evidence, not guesses. Disk Steward. Know what grew before you delete.

## Research and claim boundaries

The story deliberately makes a narrow claim: coding agents work with local project resources, and local development work can leave files that a user later has to understand. It does **not** claim that every agent session increases disk use, that agents are the sole cause of macOS System Data, or that a displayed example size came from telemetry.

- OpenAI documents Codex working with a local folder or Git repository and using the local terminal and developer tools. That supports showing local repositories, worktrees, caches, downloads, and generated artifacts as plausible work products—not a universal growth rate. [OpenAI: Work with Codex](https://help.openai.com/en/articles/20001275/), [OpenAI: Codex use cases](https://developers.openai.com/codex/use-cases)
- Anthropic documents Claude Code as running locally, working in a project directory, and supporting resumable sessions. Its data-usage documentation also describes configurable local session storage. That supports the local-session framing while leaving exact retention and storage size unstated. [Anthropic: Claude Code setup](https://docs.anthropic.com/en/docs/claude-code/getting-started), [Anthropic: CLI usage](https://docs.anthropic.com/en/docs/claude-code/cli-usage), [Anthropic: data usage](https://docs.anthropic.com/fr/docs/claude-code/data-usage)
- Apple explains that Storage Settings reports broad categories such as System Data. Disk Steward's product claim is intentionally different: it measures whole-volume capacity separately from detailed metadata under user-selected roots. [Apple: See used and available storage space](https://support.apple.com/guide/mac-help/see-used-and-available-storage-space-mchlp2519/mac)
- Apple requires Developer ID signing and recommends notarization for software distributed outside the Mac App Store. The video therefore links to the public source and calls the product a developer preview; it does not present an unverified download. [Apple: Developer ID](https://developer.apple.com/developer-id/), [Apple: Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Product facts represented

- Whole-volume capacity and detailed watched-root evidence are separate scopes.
- Evidence retention is bounded; reduced precision or coverage is recorded rather than silently hidden.
- Export is manual and integrity-verifiable.
- MCP access is local, read-only, and off by default on a fresh installation.
- Disk Steward does not delete files or automatically clean caches.

Those statements are covered by the repository's [evidence lifecycle](../architecture/evidence-object-lifecycle.md), [export contract](../architecture/evidence-export.md), [MCP contract](../architecture/mcp.md), and [privacy model](../operations/privacy-and-retention.md).

## Reproduction

The composition is 1920×1080, 30 fps, and 900 frames. From `promo/`:

```sh
npm install
npm run typecheck
npm run poster
npm run render
```

The narration is generated locally from `promo/voiceover.txt`; the rendered captions remain authoritative even if another voice is substituted later.
