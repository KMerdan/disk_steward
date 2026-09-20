# TASK-615 — Running the object model in the app

Actor: `claude`, 2026-09-20. Focused runs on input `bb08ca1d7776…`; the full verifier is recorded below. No live evidence database was opened and no real project tree was modified.

## What changed

`PersistentMonitoringProbe` now builds its scanner with an `ObjectClassifier` backed by `GitRepositoryOracle`, and converges an existing store before each sample:

- The directories that still hold per-file rows are classified, not the files. For each, the object is the **outermost** ancestor that classifies, not the directory the file sits in.
- At most `maximumCollapsePerSample` (64) objects are collapsed per sample, so a store with a million stale rows converges over a few samples instead of blocking one.
- Convergence stops for the launch as soon as a pass removes nothing, so a converged store pays one classification pass and no more.
- What it changed is reported as a visible limitation on the observation: "Collapsed N file rows into M build-output objects…". The app does not rewrite a user's evidence silently.
- Passing `objectClassifier: nil` restores the previous behaviour exactly, which is what a machine without usable classification gets.

## A hang this work found, and fixed

The first run of these tests hung for 30 minutes with no output and was killed. A stack sample of the stuck process (`hang-diagnosis/stack-sample.txt`, run record in `timed-out-run.json`) pointed at `ObjectClassifier.repositoryPath(for:)`.

The cause: for a path that is not absolute, `URL.deletingLastPathComponent()` prepends `..` rather than reaching a fixed point, so the walk never terminated. Paths reach that code from the store, so one oddly-shaped row could have hung a scan on a real machine.

The fix rejects non-absolute paths, bounds the walk at `maximumAncestorDepth` (256), and standardizes as it goes. `ancestors(of:)` exposes the same bounded walk so the probe does not re-implement it. `testARelativeOrOddPathDecidesNothingInsteadOfWalkingForever` asserts that an empty, relative or `..` path decides nothing in under a second, and the `unbounded-walk` mutation re-creates the hang and fails that test.

## Proofs (AC-TASK-615-01)

| case | test |
|---|---|
| a wired probe publishes objects and stages nothing inside them | `testAWiredProbePublishesObjectsAndStagesNothingInsideThem` |
| a store with rows inside objects converges, and the app says so | `testAStoreWithRowsInsideObjectsConvergesAndSaysSo` |
| a machine without classification still monitors as before | `testAProbeWithoutAClassifierKeepsScanningEverything` |
| a relative or odd path decides nothing instead of walking forever | `testARelativeOrOddPathDecidesNothingInsteadOfWalkingForever` |
| ancestors run outermost last and stop at the root | `testAncestorsRunOutermostLastAndStopAtTheRoot` |

28 tests across the four object suites, zero failures (`focused-green/`).

## Non-vacuity

| mutation | result |
|---|---|
| the probe builds its scanner without the classifier | both wiring tests fail (`unwired-mutation-red/`) |
| an installed store is never converged | `testAStoreWithRowsInsideObjectsConvergesAndSaysSo` fails (`noconverge-mutation-red/`) |
| the ancestor walk accepts a relative path again | the hang regression fails (`unbounded-walk-mutation-red/`) |

## Limitations

- Convergence classifies the directories the store names. A directory that no longer exists on disk classifies as unresolved and its rows stay until a scan removes them normally.
- Objects still publish without aggregates: `TASK-621` measures them. A reader must not treat a missing size as zero.
- The convergence path is exercised against stores built in the test, not against a copy of this machine's installed store; that capture belongs to the rung gate, where a real store can be copied and converged end to end.
- `GitRepositoryOracle` spawns `git` for repositories only. A tree outside any repository, like the fixtures here, never spawns a process.
