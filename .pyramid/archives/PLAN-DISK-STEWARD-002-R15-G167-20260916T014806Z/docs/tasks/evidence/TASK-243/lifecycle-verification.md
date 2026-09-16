# TASK-243 lifecycle verification

Verified on 2026-09-13 with the full Swift package test suite.

## Object truth and historical evidence

- A complete observation of `A, B, C` followed by a complete observation of
  `A, C` emits a deletion transition for `B` and changes its current presence
  to deleted. Replaying the same observation is idempotent.
- If the second observation is partial or failed, `B` becomes unknown instead
  of deleted. A later complete observation is required to resolve it.
- Current present state is stored independently from historical detail. Normal
  retention cannot remove present `A` or recreate expired/deleted `B`.
- Tombstones and detailed observation history expire only after their declared
  history horizon. Open evidence gaps remain visible until quantified.

## Retention tiers and pressure behavior

- Default detail windows: raw state/event/provenance 7 days, unreviewed anomaly
  detail up to 30 days, hourly summaries 30 days, and daily summaries 365 days.
- Snapshots retain raw-window samples, one deterministic sample per hour until
  day 30, and one deterministic sample per day until day 365.
- Retention runs at startup, after six hours, or at the near-cap threshold.
- Pressure handling performs normal roll-up/expiry first, then removes globally
  oldest eligible retained history. It writes a `RetentionRun` and creates a
  `CoverageGap` before forced removal. If only current truth remains, it reports
  the cap limitation rather than deleting current state.
- Retention history is capped at 1,500 runs, and completed gap history expires
  with the daily horizon so the monitor cannot grow its own ledger forever.

## Export ownership and recovery

- A manual export is user-owned. Its record stores requested and actual time
  range, retained precision, path-detail policy, byte count, manifest hash,
  path, and lifecycle status. Missing files are observed as `missing`; they are
  never deleted by retention.
- An MCP inline export has no persistent path. Its private temporary directory
  is read, removed, and transitioned from `creating` to `served` to `destroyed`
  for both success and error cleanup paths.
- Records left `creating` or `served` for more than six hours become explicitly
  failed on restart. The inventory keeps at most 512 records, retires the
  oldest completed record first, and never severs an in-flight lifecycle.

## Verification results

- `swift test --filter EvidenceRetentionLifecycleTests`: 3 tests, 0 failures.
- `swift test`: 128 tests, 0 failures.
- `git diff --check`: passed.

The relevant boundary coverage includes tier cutoffs, deterministic repeat
compaction, present-state survival, tombstone expiry, forced pressure loss,
restart recovery, export ownership, temporary cleanup, manual missing-state
tracking, and bounded inventory behavior.
