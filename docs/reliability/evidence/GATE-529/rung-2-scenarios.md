# GATE-529 — Trustworthy current evidence across changes and lifecycle (rung 2)

Actor: `claude` (gate taken at G123, guard `GUARD-TASK-09162C9DE7DD16CF0CA9B1635A747DBB`). Independent exercise of the integrated candidate for OUTCOME-520 on top of the verified rung 1 (OUTCOME-510). Nothing was committed, installed, signed or released.

## Exact candidate

`candidate/candidate.json`: source input `09bd0c1a445d2f0e6568113f09506b1278321901e76ab0a803b8017edfce2ba6`. Stages: harness ok, toolchain ok, manifest ok, entitlements ok, build ok, tests ok, package-generator ok, package-toolchain ok, package-system-temporary ok, package-project ok, package-build ok, package-architecture-app ok, package-architecture-helper ok, package-smoke ok, package-helper ok. Tests: Executed 523 tests, with 5 tests skipped and 0 failures (0 unexpected) in 70.842 (70.870) seconds; `sentinelPreserved: True`. Packaged unsigned app and bundled helper verified as in rung 1 (`package-smoke.log`, `package-helper.log`).

## Scenarios for this rung, independently rerun

- **Staged deletion, restart, directory mutation, failed roots, moves and scope changes (TASK-521)**: `docs/reliability/evidence/audits/scoped-511-521-522-green/` — DirectoryMetadataScannerConvergentScanGenerationTests 46, EvidenceObjectLifecycleTests 26, HistoricalMigrationTests 7, MonitoringTests 15, EvidenceStoreTests 12, DurableProvenanceLifecycleTests 5, UnknownOccurrenceTests 6, EvidenceEventTimingTests 2; 0 failures. Audit passed (EVENT-20260918T052751582266Z-4AED5A97).
- **Lifecycle, notifications, hints and boot (TASK-522)**: same run — MonitoringLifecycleTests 22, NotificationDeliveryTests 7, MonitoringReceiptTests 12, ScanPublicationFenceTests 7, PersistentRecorderIncrementTests 1, MonitoringProbeCancellationTests 4; 0 failures. Delayed-termination wiring inspected in source (INSPECT-TASK-522-BOOT). Audit passed (EVENT-20260918T052751911160Z-E23B0ECE).
- **Ordered, bounded, fenced endpoint delivery and stop/restart (TASK-523, AC-GATE-529-02)**: `docs/reliability/evidence/audits/scoped-523-541-542-551-552-green/` — EndpointDeliveryRegressionTests 13, DiskStewardEndpointTests 4; 0 failures, on the current candidate. FIND-ENDPOINT-ORDER is resolved through INSPECT-TASK-523-1 with the deterministic fixture reproduction (`docs/reliability/evidence/TASK-523/endpoint-red.log`) preceding the green suites; no real system-extension activation is claimed. Audit passed (EVENT-20260918T052752237062Z-4A8A9771).
- **Inherited rung 1**: isolation and ownership suites and the packaged smoke re-established on this candidate (see `docs/reliability/evidence/GATE-519/rung-1-scenarios.md`; the same stages passed here).
- **Safety and recovery**: migration/rollback rehearsal (`docs/reliability/evidence/TASK-572/rollback-rehearsal.md`) and historical migration cases in the full suite.

## Findings affecting this rung

FIND-ISOLATION, FIND-SCALE, FIND-ENDPOINT-ORDER, FIND-QUERY, FIND-ROLLBACK, FIND-OCCURRENCE: resolved. FIND-ATTRIBUTION: open (see the audit record for its disposition). FIND-OVERNIGHT: open on RESOURCE/BUILD, outside this rung; the TASK-572 soak is running.

## Limitations

- Fixture endpoint adapter only; no native EndpointSecurity activation or entitlement.
- Fake-clock lifecycle proofs; real sleep/wake and native notification submission are not exercised.
- Unsigned disposable-copy packaging; host macOS 15.6.1 arm64.
