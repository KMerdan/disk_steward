# TASK-614: stop a scan that cannot converge and say so

Candidate input `35a702b350e676a6d053bbccb31902ea604c15dde280154809cfe88fd3f1cfb9`
(main 345c072, TASK-641 and TASK-614 uncommitted). Nothing is committed or
installed.

## Change

- `ScanConvergencePolicy` (in `Sources/DiskStewardApp/Lifecycle/ScanConvergenceStop.swift`)
  judges the active generation. It stops it on any of three verdicts:
  - processed entries exceed 20 × max(staged files, 100k);
  - storage refused the scan on 3 consecutive samples at the same store limit;
  - accumulated active scan time exceeds 6 hours.
- The refusal counter resets on progress or when the limit changes, because
  raising the limit is the remedy. Active scan time is accumulated per
  generation, so relaunch and sleep don't reset it.
- The check runs at the start of each sample, before storage recovery,
  pressure retention or any slice.
  - A stop abandons the generation through
    `EvidenceStore.abandonActiveScanGeneration(reason:at:)`. That uses the
    same path as a scope change: staging is discarded and retained current
    evidence is untouched.
  - The stop is persisted to `scan-convergence.json` beside the store, so a
    relaunch never restarts the scope.
  - The stop is lifted after 24 hours, or when the scope or store limit
    changes.
- While stopped, a sample only measures the volume and reads lifecycle
  status. It runs no retention, requests no continuation, and returns
  `MonitoringObservation.scanStop`. The status line reads "Detail scan
  stopped", with a message that names the cause and the two remedies (narrow
  the watched roots, or raise the store limit).
- The scalar `activeScanGenerationSummary()` reads processed and staged
  counts without decoding the traversal checkpoint.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 70 tests, 0 failures, including the captured-store test (below). Covers scan convergence, storage recovery (TASK-532 scenario unchanged), probe cancellation, lifecycle, scan continuation, object convergence, receipts, lifecycle projection and status board suites |
| `ratio-verdict-red/` (`mut-no-ratio-verdict.json`) | Ratio verdict removed: 5 assertion failures in `ScanConvergenceStopTests` |
| `refusal-verdict-red/` (`mut-no-refusal-count.json`) | Refusal verdict removed: the same-cap refusal scenario never stops, and the thresholds test fails |
| `persisted-stop-red/` (`mut-stop-not-persisted.json`) | The stop is not persisted: the relaunch assertions fail |

The persisted-stop red was first stopped by the supervisor's transient
`Cannot classify new process` error before any test ran. It was re-run; the
archived run is the completed one.

### Captured live store (AC-TASK-614-02)

- **Capture.** `sqlite3 -readonly <live store> ".backup <scratch>/captured/evidence.sqlite"`
  was taken on 2026-10-04: schema 14, 405 MB, `quick_check` ok. Its active
  generation `scan-generation-e394ea04…` showed 488,958,754 processed and
  122,862 staged.
- **Isolation.** The copy was placed only inside the isolated test snapshot,
  at `.captured/evidence.sqlite`. The opt-in `CapturedStoreConvergenceTests`
  copies it again into a temporary directory. The live store was opened only
  read-only, for the backup.
- **Result.** On the first sample the stop fired for that generation:
  - reason `processed-far-beyond-staged`, processed 488,958,754;
  - no scan slice committed, and no continuation requested;
  - the generation was abandoned, all 44 observations were retained, and the
    lifecycle summary answers.
- **Staged count.** The stop recorded 0 staged files. Opening the schema-14
  capture migrates it to schema 15, and staged counts are recomputed from
  staged rows. For that reason the message reports processed and staged
  counts neutrally rather than as "files kept".

## Pre-existing flake, not caused by this task

`ObjectConvergenceTests.testAStoreWithRowsInsideObjectsConvergesAndSaysSo`
sometimes throws `change evidence is later than observation publication` from
its own legacy-seed step. It fails the same way on unmodified main 345c072
(`baseline-object-convergence-flake/run-2`; runs 1 and 3 pass). It failed in
2 of 4 runs on the candidate before passing in the green run.

## Limits

- The 6-hour verdict counts active scan time in this process as written to
  the sidecar. A failed sidecar write only delays that verdict.
- The fixture can't materialize 123k staged rows, so it checks the ratio
  verdict against the store's derived staged count (0).
- Rung 2 (TASK-653) retires the scanner itself. This stop is the rung-1
  relief until then.

Process note: the implementation and evidence above were produced before TASK-614 was formally claimed (claim recorded afterwards on 2026-10-04); no other actor held the task.
