# TASK-244 authoritative read-model verification

Verified on 2026-09-13 with focused contract tests and the complete Swift
package regression suite.

## Current objects and cleanup truth

- Current consumers are read from `current_file_state`, not reconstructed from
  a bounded export. Root, category, byte, and modification-time filters execute
  in SQLite before ordering and pagination.
- Pages use a stable allocated-bytes/path/object-identity keyset cursor and
  disclose matched, returned, truncated, and next-cursor values.
- Consumer category prefers retained event classification and otherwise derives
  deterministically from the canonical current path, so raw-event compaction
  cannot silently reclassify a surviving object.
- Cleanup candidates include only actionable `present` objects whose current
  path is revalidated with `lstat` against stable filesystem identity, size,
  and modification time. Deleted, unknown, partial, stale, inaccessible,
  symlinked, out-of-scope, changed, and path-reused objects are excluded.

## Historical evidence and attribution

- Growth queries combine raw, hourly, and daily retained tiers before filtering,
  ordering, and limiting. Results disclose requested and actual retained
  intervals, precision, coverage gaps, and raw versus surviving current bytes.
- Provenance resolves canonical object identity before applying full, basename,
  or hashed privacy shaping. Duplicate basenames remain separate objects.
- The ordered chain carries current state, observations, changes, stored claims,
  sessions, attribution intervals, contradictions, supersession, and gaps.
  Unknown creators remain unknown; an agent-session registration is never
  promoted into an observed-writer claim.
- Task impact supports active and ended sessions, reports historical
  growth/shrink/churn separately from surviving current logical and allocated
  bytes, and preserves the weakest supported attribution confidence.

## Lifecycle, export, and access boundary

- `get_storage_summary` distinguishes live volume sample time from persisted
  current-state time. `get_evidence_lifecycle` exposes tier ranges, database
  usage and cap, compaction, forced loss, current state, export inventory, and
  observation/retention gaps.
- Complete evidence bundles are produced from one SQLite backup and include
  current state, ordered provenance, agent sessions, coverage, lifecycle,
  events, rollups, snapshots, integrity hashes, and a manifest.
- Exported lifecycle policy comes from the latest recorded retention run, or is
  explicitly labeled as the application default when no run exists. Retained
  sessions and gaps have no undisclosed fixed row cutoff; the existing event
  cap and any loss of precision are disclosed.
- Agent Access still defaults off and owns the private Unix socket lifecycle.
  Every MCP tool is read-only; `list_active_writers` remains only as a
  compatibility alias and explicitly states that writer identity was not
  observed.

## Verification results

- `swift test --filter AgentQueryableEvidenceIncrementTests`: 1 test, 0 failures.
- `swift test --filter FinalProductIncrementTests`: 1 test, 0 failures.
- `swift test --filter EvidenceBundleExporterTests`: 7 tests, 0 failures.
- `swift test`: 132 tests, 0 failures.
- `git diff --check`: passed.

Coverage includes a 520-row filter-before-limit fixture, stable cursor traversal,
duplicate basenames, retained rollups, path reuse, partial observation, cleanup
exclusion, ended task impact, surviving bytes, hashed paths, disabled access,
inline export parity, response-size failure, and complete-bundle integrity.
