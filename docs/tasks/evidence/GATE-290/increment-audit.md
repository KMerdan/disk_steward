# GATE-290 polished native application increment audit

Audit date: 2026-09-13. Result: pass.

## Build, bundle, and launch

- A clean unsigned Debug build from `DiskSteward.xcodeproj`, scheme
  `DiskSteward`, succeeded in an isolated DerivedData directory.
- The product is `Disk Steward.app`, bundle identifier
  `com.marudankiji.disksteward`, with `LSUIElement=true`.
- The app and embedded `Contents/Helpers/disk-witness-mcp` are arm64 Mach-O
  executables. App icon and compiled asset catalog are present.
- Built-app `--ui-smoke` reports accessory activation, a labeled Disk Steward
  status item, available capacity snapshot, distinct left-click status board
  and right-click utility menu, the complete menu, and Agent Access off.

## Human surface

- The 352-point status board prioritizes free space, used capacity, and recent
  change; monitoring/freshness and Agent Access are secondary; Export Evidence
  is the only prominent action.
- Aqua and Dark Aqua renders have identical geometry and no clipped or missing
  content. System colors, material, typography, controls, and symbols adapt to
  appearance.
- Active, paused, degraded, no-baseline, and error presentations each have
  unique text, deterministic action, and textual accessibility summary.
  Capacity, growth, monitoring, and Agent Access do not rely on color alone.

## MCP and privacy boundary

- The helper embedded in the built app initializes under MCP protocol
  `2025-06-18` and lists ten tools.
- Every listed tool has `readOnlyHint=true`, `destructiveHint=false`,
  `openWorldHint=false`, and a closed input schema.
- Fresh Agent Access defaults off. Integration tests prove on permits private
  local queries, off removes/refuses the socket, and neither transition pauses
  monitoring nor deletes evidence.
- No network listener or write-capable cleanup API was introduced. Cleanup
  results remain review candidates and explicitly never assert safe deletion.

## Evidence lifecycle composition

- Complete A/B/C followed by complete A/C records B deleted; partial A/C keeps
  B unknown until a later complete observation.
- Rename, truncate, replacement, scope exit, restart gap, deletion, and path
  reuse preserve distinct identity-aware state.
- Current present state survives history compaction. Normal retention rolls raw
  detail into hourly and daily summaries, downsamples snapshots, applies a
  finite anomaly window, and records coverage loss before forced pressure
  eviction.
- Lifecycle queries disclose actual tier ranges, precision, gaps, database
  bytes/cap, compaction, current state, and export inventory.
- Manual exports remain user-owned; private MCP bundles are destroyed after
  serving. Complete bundles use one database backup and include current state,
  provenance, sessions, coverage, lifecycle, events, rollups, snapshots,
  integrity, and manifest data.
- Current-consumer filtering and ordering happen before limits with stable
  keyset pagination. Cleanup is revalidated against the same live filesystem
  identity. Task impact separates historical activity from surviving bytes,
  including ended sessions. Unknown authorship is never upgraded merely from
  an active session.

## Verification transcript summary

- `swift test`: 135 tests, 0 failures.
- Xcode Debug build: `BUILD SUCCEEDED`.
- Built app UI smoke: passed.
- App bundle identity/helper/resources inspection: passed.
- Embedded helper MCP initialize and read-only tool inventory: passed.
- Light/dark visual and state-matrix tests: 3 tests, 0 failures.
- Export, retention, pressure, lifecycle, privacy, fallback, current-state,
  provenance, Agent Access, IPC, MCP, installer, and final-product suites all
  passed within the full run.
- `git diff --check`: passed.

No product requirement was weakened and no implementation change was made by
this gate.
