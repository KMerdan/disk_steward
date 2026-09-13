# TASK-241 reconciliation verification

Status: implementation complete; ready for independent Pyramid audit.

## Implemented evidence chain

Each sampling transaction now persists, in order, a scope version, observation run,
per-root coverage, whole-volume snapshot, file objects, temporal path bindings,
file-state observations, the derived current-state projection, change events, and
coverage gaps. The transaction is atomic and the observation identifier is an
idempotency key.

The current-state projection is deliberately conservative:

- absence after a complete observation of the same scope produces `delete`;
- absence after a partial or failed observation produces non-actionable `unknown`
  while preserving the identifier and timestamp of the last confirmed state;
- removal from configured scope produces `scope-exit`, not `delete`;
- a newly included object produces `scope-enter` after a scope change;
- an object retaining identity at a new path produces `rename`;
- a different identity at the same path produces `replace`;
- open root/event gaps are resolved by later complete coverage while their history
  remains queryable;
- startup after persisted prior state records the app-offline interval and safely
  reconciles the new complete observation.

Cleanup-facing reads exclude unknown, stale, and out-of-scope records by default.
Callers must opt in to non-actionable records.

## A/B/C scenarios

`EvidenceObjectLifecycleTests` proves both requested variants:

1. Complete O1 `{A,B,C}` followed by complete O2 `{A,C}` produces exactly one
   deletion event for B, removes B from current state, and reprocessing O2 makes no
   duplicate event.
2. Complete O1 `{A,B,C}` followed by partial O2 `{A,C}` produces no deletion,
   leaves B as non-actionable `unknown` with state-as-of O1, records an `entry-cap`
   gap, then resolves the gap and confirms deletion only after complete O3.

The same suite also covers modify, truncate, rename, replacement, scope entry/exit,
restart/offline reconciliation, and transaction rollback on a scope mismatch.

## Verification

- `swift test --filter EvidenceObjectLifecycleTests`
  - 6 tests executed, 0 failures.
- `swift test`
  - 111 tests executed, 0 failures.
- `git diff --check`
  - no whitespace errors.

The unrestricted test run is required because several existing integration tests
create private Unix sockets and Swift build caches; sandbox-denied runs are not
treated as product failures.

## Files

- `Sources/DiskStewardCore/Monitoring/DirectoryMetadataScanner.swift`
- `Sources/DiskStewardCore/Monitoring/MonitoringPolicy.swift`
- `Sources/DiskStewardCore/EvidenceStore/EvidenceStore.swift`
- `Sources/DiskStewardCore/EvidenceStore/EvidenceStoreModels.swift`
- `Sources/DiskStewardCore/EvidenceStore/SQLiteConnection.swift`
- `Sources/DiskStewardApp/Lifecycle/PersistentMonitoringProbe.swift`
- `Tests/DiskStewardCoreTests/EvidenceStore/EvidenceStoreTests.swift`
- `Tests/DiskStewardCoreTests/EvidenceStore/EvidenceObjectLifecycleTests.swift`
