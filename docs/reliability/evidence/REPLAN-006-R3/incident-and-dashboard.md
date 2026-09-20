# Replan 006 R3: verification containment and dashboard consistency

Date: 2026-09-20 (JST). Inspected source: b7e3675, clean main before this replan.
This is a diagnosis/planning record, not new implementation or passing test evidence.

## Test-runner incident

Observed test identity: PID 60334, parent PID 1 (launchd), running Xcode's xctest
with filter DiskStewardAppTests.ObjectConvergenceTests/testAStoreWithRowsInsideObjectsConvergesAndSaysSo
and bundle /private/tmp/ds-check-b0pghoqx/project/.build/arm64-apple-macosx/debug/DiskStewardPackageTests.xctest.

- The isolated run's result.json says stopReason=timeout, exitCode=-9,
  seconds=300.034458667, passed=false, repositoryUnchanged=false.
- At inspection the child was still alive after 51 minutes with 100% CPU.
  RSS initially measured 11,563,984 KiB and later 12,376,192 KiB.
- A two-second sample at 15:46:03 JST reported Physical footprint=86.9G
  (peak also 86.9G). RSS alone understated the process's reported memory footprint.
- Active stack: ObjectConvergenceTests.swift:66 -> PersistentMonitoringProbe.sample
  -> convergeStoredObjects -> ObjectClassifier.repositoryPath, with samples at
  ObjectClassification.swift:245-247 in the old snapshot's unbounded ancestor walk.
- The fixture evidence.sqlite was 352,256 bytes, WAL 4,152 bytes, shm 32,768 bytes.
  These observations do not establish the suggested large-WAL memory explanation.
- The user approved stopping this exact test. PID and command were rechecked,
  SIGTERM sent to PID 60334, and ps confirmed no such process remained.
  No production app, live evidence data, or other test was terminated.
- Commit a4ebfe6 already added absolute-path guards and a 256-ancestor bound
  to current source. That does not update an executable in an older snapshot.
- The runner uses start_new_session and killpg(child.pid), but the live child
  survived its timeout. The exact escape/reparenting mechanism was not captured:
  TASK-616 must verify it, not assume that changing process-group handling alone
  proves full descendant cleanup.
- A loaded MallocStackLogging framework is not evidence the diagnostic was enabled.
  No environment dump or allocation-ownership attribution was obtained.

Raw local evidence (may later expire):
- /private/tmp/disk-steward-xctest-60334-sample.txt
  SHA256 7e99a76132b34b9ef6b72865cb014102663d147401933163e4f2b1f5140a04f4
- /private/tmp/ds-check-b0pghoqx/result.json
  SHA256 c08c9051e54b134a1999a843684b4a125140560bab6791a59e5f1853749b0120
- The result is also retained here as orphaned-run-result.json, without changing
  its failure or repositoryUnchanged=false status. It is not acceptance evidence.

Inspected implementation: Scripts/Testing/verify_candidate.py::run_command and
clean_environment; Scripts/Testing/supervise_soak.py::group_rss and
terminate_owned_group; docs/reliability/handoffs/harness/run-focused.py and
run-mutation.py. The soak helper only accounts for a process group and can
return when its direct child exits. The focused/mutation runners share run_command.
No new Swift, scale, mutation or soak run was started during diagnosis or replanning.

## Dashboard evidence

User screenshot: +2.1 MB, "Since the previous sample", monitoring active with
file-detail scan in progress; user reports an earlier +5.6 GB growth notification
and says the displayed change has remained frozen. Screenshot retained as dashboard.png.

Observed source defects, unchanged between v1.2.1 and the inspected checkout
for StatusBoardView, StatusBoardViewModel and ThresholdNotificationPolicy:
- StatusBoardView.swift::GrowthSection and CapacitySection receive a plain let
  viewModel rather than observing the changing source used inside each subview.
  The parent does observe lifecycle; it is therefore not justified to claim
  the whole board never observes changes. A hosted multi-update rendering
  regression is still needed to establish the exact redraw failure.
- StatusBoardViewModel has a separate published snapshot, populated only by
  refresh(). It does not subscribe that snapshot to latestObservation.
- refresh() copies lifecycle.latestObservation.snapshot if available and returns;
  it does not request lifecycle.sampleNow().
- PersistentMonitoringProbe uses positive-only volume delta aggregation in both
  normal and storage-refusal paths. A decrease is discarded before presentation.
- Notification and growth text read growthReport.volumeUsedDelta, but a historic
  alert and the latest interval need not match. The label is not "since launch".
  The actual 5.6 GB notification interval was not captured.
- Tests/DiskStewardAppTests/StatusBoard/StatusBoardPresentationTests.swift checks
  a static fixture and light/dark rendering; it does not assert successive
  rendered updates. Its injected negative delta bypasses the production filter.
- A read-only MCP summary at 15:50:10 JST returned a fresh volume observation,
  while persisted detailed state remained 2026-09-13T07:10:15.916Z. That proves
  the query can obtain capacity, not that the GUI published the same sample.
- Native UI inspection timed out. This is source-supported diagnosis plus the
  user's observation, not a completed automated live-GUI reproduction.

Supporting framework reference: https://developer.apple.com/documentation/swiftui/observedobject
(the observation subscription requirement; not proof of this app's runtime behavior).

## Repair sequence and acceptance boundary

1. TASK-616: safely bootstrap process containment with small bounded fixtures,
   then establish descendant cleanup and finite memory/time/output budgets for
   every relevant test entry point. Keep unrelated-process sentinels untouched.
2. TASK-617: reproduce rendered updates, unify observation-bound presentation,
   request real bounded refresh, preserve signed deltas and show interval/baseline,
   separate capacity and detailed-evidence freshness, retain one session-local
   latest growth alert. No new persistent alert history or schema migration.
3. TASK-614 and object sizing/ranking/presentation continue under safe supervision.
   GATE-619 requires both repairs; GATE-629 and GATE-639 repeat their proofs.

Historical six-task verification is retained. The previous 587-test report is
historical functional evidence, not proof that the runner cleaned up all children.
The old handoff's "no verifier ... active" statement was disproved by the orphan;
the new handoff supersedes that runtime-state assertion. Do not rerun the old
unbounded test or mutation until the containment task has passed.
