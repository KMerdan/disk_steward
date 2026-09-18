# GATE-539 — Useful bounded monitoring progress (rung 3)

Actor: `claude`. Independent exercise of the integrated candidate for OUTCOME-530 on top of every earlier verified rung. Nothing was committed, installed, signed or released; every run is an isolated snapshot under `/private/tmp`.

## Exact candidate

`docs/reliability/evidence/TASK-562/candidate-2/candidate.json`: source input `5ecd49a317171e493451894bcc082cd8d4516d2922c29564107baace9d21dd68` (the final candidate; TASK-562's second full run). Stages: harness ok, toolchain ok, manifest ok, entitlements ok, build ok, tests ok, package-generator ok, package-toolchain ok, package-system-temporary ok, package-project ok, package-build ok, package-architecture-app ok, package-architecture-helper ok, package-smoke ok, package-helper ok. 547 tests, 5 opt-in skips, 0 failures; `sentinelPreserved: True`; packaged unsigned app, architecture, smoke and bundled-helper stages passed.

`docs/reliability/evidence/audits/scoped-all-rungs-final-green/tests.log`: every earlier rung's scoped suites rerun in one isolated snapshot on the same input `5ecd49a31717…`: 423 tests across 60 suites, 0 failures, 1 opt-in skip (NativeClientLifecycleTests). Suite counts in `suite-counts.json`.

## Scenarios for this rung, independently rerun

- **Bounded scan continuation and persistence (TASK-531)**: `docs/reliability/evidence/audits/scoped-all-rungs-final-green/` — BoundedFrontierTests 6, DirectoryMetadataScannerConvergentScanGenerationTests 46, ScanContinuationIncrementTests 2, ScanPublicationFenceTests 7, PersistentRecorderIncrementTests 1, LifecycleProjectionTests 5, MonitoringTests 15; 0 failures. Full workload: `scale-runs/wide-100k/` — 100 000 files enumerated in one pass on the final candidate (`candidate-input.txt`), 27.8 s, no directory-change restarts, peak in-process RSS 56 MiB, sampled database family peak 605 MiB of which 286 MiB WAL while the 512 MiB storage cap was in force, status `completed` with no error (see `supervisor.out`; the cap bounds the database, the family sample includes the WAL as explained in `docs/reliability/evidence/TASK-532/storage-headroom.md`); the 1M wide run is inherited from `docs/reliability/evidence/TASK-531/scale-runs/wide-1m/`.
- **Storage headroom and bounded retention recovery (TASK-532)**: `docs/reliability/evidence/audits/scoped-all-rungs-final-green/` — StorageHeadroomTests 7, StorageRecoveryIncrementTests 1, RetentionScheduleTests 1, EvidenceStoreTests 12, HistoricalMigrationTests 7; 0 failures; refused slices lose no directory names (INSPECT-TASK-532-SCANNER).
- **Benchmark research (RESEARCH-530)**: `docs/reliability/evidence/RESEARCH-530/benchmark-progress.md`; the chosen bounded-frontier design is what TASK-531/532 implement and the runs above measure.
- **Real-time behaviour**: supervised production soaks of 112 min on the same product sources (`docs/reliability/evidence/TASK-572/soak-runs/soak-3h/`) and 43 min on the exact final candidate (`soak-final-candidate/`): 0 published-state mismatches, RSS plateaued under 460 MiB, bounded database family, 16 and 6 retention runs without forced evictions; numbers in each `summary.json`.
- **Inherited rungs 1 and 2**: isolation/ownership suites (SocketOwnershipRegressionTests 17, VerificationIsolationTests 2) and the trustworthy-evidence/lifecycle/endpoint suites (EvidenceObjectLifecycleTests 26, MonitoringLifecycleTests 22, NotificationDeliveryTests 7, MonitoringReceiptTests 12, EndpointDeliveryRegressionTests 13, DiskStewardEndpointTests 4) rerun on this candidate; packaged smoke re-established.

## Findings affecting this rung

FIND-SCALE resolved (INSPECT-TASK-531-1/INSPECT-RESEARCH-530-1); FIND-OVERNIGHT resolved (INSPECT-FIND-OVERNIGHT-1, R13 criterion); FIND-ROLLBACK, FIND-QUERY, FIND-OCCURRENCE, FIND-SERVICE resolved.

## Safety and recovery (inherited)

- Migration/rollback rehearsal against the compatible baseline binary (`docs/reliability/evidence/TASK-572/rollback-rehearsal.md`, FIND-ROLLBACK resolved) and the four named historical migration cases required as passed by the verifier.
- Real-time supervised soaks (`docs/reliability/evidence/TASK-572/soak-runs/soak-3h/summary.json`, 112 min; `soak-final-candidate/summary.json`, 43 min on the exact final candidate) and the 100k wide full workload on the final candidate (`docs/reliability/evidence/GATE-539/scale-runs/wide-100k/`).

## Limitations

- Fixture endpoint adapter only; no native EndpointSecurity activation or entitlement.
- Fake-clock lifecycle proofs; real sleep/wake and native notification submission are not exercised; native client profiles stay opt-in.
- Unsigned disposable-copy packaging; host macOS 15.6.1 arm64.
- No overnight soak by the owner's R13 direction (open-source release; long-run behaviour comes from user feedback): real-time soaks of 112 min and 43 min (exact final candidate) plus the scale matrix are the resource evidence.
