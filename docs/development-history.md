# How Disk Steward Was Built

Disk Steward grew from one disk-space problem into a verified macOS product through two completed Pyramid intents. This is the human-readable view of that evidence trail: why the work began, what each increment proved, where audits failed, and how the release became trustworthy.

```mermaid
flowchart LR
    P["Disk growth became<br/>hard to explain"] --> I1["Intent 1<br/><b>Build trustworthy evidence</b>"]

    subgraph F["Product foundation"]
      direction LR
      F1["Snapshot + export"] --> F2["Bounded SQLite history"]
      F2 --> F3["Read-only MCP"]
      F3 --> F4["Provenance + privacy"]
    end

    I1 --> F1
    F4 --> C1["✓ Evidence monitor<br/>verified"]
    C1 --> L["Real use exposed<br/>lifecycle and export gaps"]
    L --> I2["Intent 2<br/><b>Make it a product</b>"]

    subgraph R["Product and release"]
      direction LR
      R1["Evidence identity<br/>and reconciliation"] --> R2["Native Xcode app<br/>and Apple-like UI"]
      R2 --> R3["Folder + export<br/>repairs"]
      R3 --> R4["Signing, notarization<br/>and Gatekeeper"]
      R4 --> R5["GitHub + MIT<br/>Homebrew + promo"]
    end

    I2 --> R1
    R5 --> C2["✓ v1.0.0<br/>verified and public"]

    classDef origin fill:#111827,color:#fff,stroke:#334155,stroke-width:2px;
    classDef intent fill:#0f766e,color:#fff,stroke:#2dd4bf,stroke-width:2px;
    classDef work fill:#f8fafc,color:#0f172a,stroke:#94a3b8,stroke-width:1.5px;
    classDef pivot fill:#7c2d12,color:#fff,stroke:#fb923c,stroke-width:2px;
    classDef done fill:#14532d,color:#fff,stroke:#4ade80,stroke-width:2px;
    class P origin;
    class I1,I2 intent;
    class F1,F2,F3,F4,R1,R2,R3,R4,R5 work;
    class L pivot;
    class C1,C2 done;
```

## The two intent cycles

| Cycle | Why it began | Demonstrated path | Result |
| --- | --- | --- | --- |
| **1 · Trustworthy evidence** | Coding-agent output, caches, and generated artifacts were consuming space without a durable explanation. | Launchable snapshot and export → bounded evidence recorder → read-only agent queries → confidence-aware provenance. | Completed with the menu-bar monitor, bounded lifecycle, evidence bundles, and local MCP contract verified. |
| **2 · A distributable product** | Real use showed that useful evidence also needed stable object identity, deletion reconciliation, better export UX, a polished native surface, and an honest release path. | Evidence-chain repair → canonical Xcode app → convergent scans and actionable exports → Developer ID release → public product story. | Completed with a signed, notarized, stapled v1.0.0, public MIT repository, Homebrew cask, and 30-second promotion. |

## What the Pyramid recorded

| Signal | Count | What it means |
| --- | ---: | --- |
| Immutable lifecycle events | **255** | Every claim, implementation, audit, repair, replan, pause, and closure remains traceable. |
| Completed intents | **2** | The evidence-monitor foundation and the distributable-product cycle both reached verified closure. |
| Accepted audits | **79** | Product and release claims advanced only after their evidence passed. |
| Failed audits | **5** | Evidence usefulness, export behavior, release readiness, and menu-bar assumptions were repaired instead of being hidden. |
| Replans | **20** | New evidence changed the route while preserving prior valid work and rationale. |
| Final regression suite | **158 tests** | The current Swift suite completed with zero failures. |

## Important turning points

1. **A snapshot was not enough.** The design moved to current-state projections plus immutable observations, explicit coverage, and bounded retention.
2. **Missing does not automatically mean deleted.** Stable file objects, path bindings, and complete-scan generations were introduced so `A, B, C → A, C` can retire `B` only when coverage proves it.
3. **Agent access became a product boundary.** MCP is opt-in, local, and read-only; monitoring and manual export continue independently, and there is no delete tool.
4. **The first export failed the usefulness test.** The human-triggered bundle was rebuilt around the authoritative database and now includes current consumers, history, provenance, coverage, lifecycle, gaps, and integrity hashes.
5. **Distribution stayed evidence-led.** The exact universal app—not merely an Xcode build—was verified for Developer ID signatures, hardened runtime, notarization, stapling, Gatekeeper, launch behavior, and Homebrew checksum identity.
6. **The disappearing icon was not an app crash.** Live-process and accessibility evidence isolated a stale iBar cache; restarting iBar and relaunching Disk Steward restored the status item without changing app data or lifecycle code.

## Explore the complete record

- [Interactive Pyramid Observer](../.pyramid/pyramid.html) — switch between **Intent**, **History**, **Focus**, **Star**, **Pyramid**, and **Dependencies** views.
- [Final release report](../.pyramid/reports/FINAL-PLAN-DISK-STEWARD-002-R15-G166.md) — the accepted claims, decisions, evidence, and residual risks for the distributable-product cycle.
- [Final release audit](tasks/evidence/GATE-390/current-final-release-audit.md) — artifact identity, product journey, public repository, Homebrew, and promotion checks.
- [Menu-bar recovery evidence](tasks/evidence/TASK-210/menu-bar-recovery-verification.json) — the observation that separated a third-party menu-bar cache issue from an application defect.

The interactive file is self-contained. Download it and open it in a browser to explore the complete graph and both intent chronicles without running the Pyramid tooling.
