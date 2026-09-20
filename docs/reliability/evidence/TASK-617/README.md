# TASK-617 — live capacity and explainable growth alerts

Implementation and regression checks are complete. Canonical verification is
recorded separately by the Pyramid task audit; this is its supporting evidence.

## Reproduction

The pre-fix, snapshot-isolated hosted regression kept the same NSHostingView
mounted across three synthetic observations. Vision OCR of its rendered pixels
read `420 GB free / No change` at every step even though the second and third
observations should show `414.4 GB free / +5.6 GB` and `+2.1 MB`. The separate
evidence timestamp did update. Four assertions failed; the source was unchanged
during the run and all owned processes were cleaned up.

- Snapshot: `/private/tmp/ds-check-jg9ezzse/project`
- Input SHA256: `fcddf02979f899d62728388614f5d86eda46cbbf9b9c810660ad194decced171`
- Command: `PYTHONDONTWRITEBYTECODE=1 python3 docs/reliability/handoffs/harness/run-focused.py LiveStatusBoardTests 150`
- An earlier test-only attempt failed compilation on a Swift `Self` initializer;
  that attempt is not runtime reproduction evidence.

## Measurement contract

- The lifecycle publishes one observation containing the selected volume,
  snapshot ID, capacity sample time, volume UUID and optional signed comparison.
  The view model subscribes to that observation and both child sections observe
  the view model. Capacity, health, delta and timestamp cannot select unrelated
  volumes or retain an independent cached snapshot.
- First sample is unknown, not zero. Comparable samples need matching UUID,
  mount path, capacity/flags, distinct observation IDs and increasing timestamps.
  Missing identity or invalid time refuses a growth baseline. Baselines are
  session-local; restart, settings changes, pause/sleep, and failed samples require
  another pair. While paused or failed, last-known values remain explicitly labeled.
- A capacity sample is usable even while the detailed scan is incomplete. File
  freshness comes only from the last complete file-scan timestamp, never the
  lifecycle-query timestamp or a new capacity sample.
- Refresh requests the lifecycle's single-flight operation, with at most one
  coalesced follow-up. Pause/sleep/shutdown still fence it. The UI exposes pending
  and stale/paused state and does not label a cached read as a fresh measurement.
- Recent change and notifications use the same signed comparison and decimal
  byte formatter. Exactly one latest growth-threshold event is kept in memory,
  including triggering/baseline IDs, UUID, path, amount and both timestamps.
  Later small changes, decreases, pause and volume changes do not rewrite it.
  Restart clears it. It is a threshold event, not proof that macOS displayed a
  notification; notification permissions remain independent.
- File-detail explanation intervals can differ from consecutive published
  capacity samples (for example after a cancelled durable commit). Notifications
  explicitly warn about that difference; this task does not fabricate attribution.

No persistent schema migration, live-database access, installation, release,
real notifications or cleanup of user files is part of this task.

## Review-driven regressions

Independent read-only review found and prompted fixes for initial-sample errors,
growth-event retention behind a suspended capacity notification, and a formerly
two-alert cancellation fixture that needed a genuine baseline under the new
contract. The final candidate also distinguishes initial safety pause from a
retryable sampling error, shows idle rather than a reading spinner while paused,
and delivers valid capacity alerts while file reconciliation remains pending.
File-detail uncertainty is still shown; no claim of file attribution is inferred.

Coverage includes an uncancelled two-alert control, cancellation after the first
submission, a pending→clear reconciliation transition without replay, and a real
synthetic store-admission refusal with a negative selected-volume delta. Date
expectations are independently formatted from fixture timestamps, not hard-coded
to Tokyo and not obtained from the view model under test.

The ordinary full-suite intermediate candidate passed 599 tests (6 intentional
skips). It was superseded by the review fixes; it is not the final-candidate
acceptance receipt.

## Final candidate and results

- Frozen snapshot: `/private/tmp/ds-check-qubaxlgo/project`.
- Input SHA256: `8b2494c3c786942542723ed5aa013bbebde206a0654d3b8e1df7a6db276dd8fc`.
- Command: `PYTHONDONTWRITEBYTECODE=1 python3 docs/reliability/handoffs/harness/run-focused.py '.' 300`.
- **604 tests executed, 6 intentional skips, 0 failures**. Build and tests took
  125.96 seconds; peak aggregate physical footprint was 926,737,888 bytes under
  the 2 GiB limit. `cleanupVerified: true`, no remaining owned processes,
  no cleanup errors, and `repositoryUnchanged: true`.
- `before.json` / `before.log` retain the failed pre-fix hosted regression;
  `after.json` / `after.log` retain the complete final candidate receipt.
  The log includes recognized visible text and an observation-bound alert trace.
- `after-small.png`, `after-reopened-dark.png`, `after-first-failure.png` are
  synthetic rendered fixtures, not screenshots of the installed app.
- `review.json` records the reconciled, independent read-only source review;
  the coordinator owns actual execution and audit. No unresolved actionable
  finding remains in the reviewed scope.

## Acceptance map and limits

1. `LiveStatusBoardTests` proves the same mounted board changes through baseline,
   +5.6 GB, +2.1 MB, −3 GB and pause, then renders the current state on reopening.
   Additional hosted tests cover first failure→retry and paused/safety startup.
2. `VolumePresentationTests` covers identity/path/capacity/time comparability,
   zero change, restart, failure/recovery, pause/resume, separate file freshness,
   actual single-flight refresh, pending state, sleep/quit fencing and clean drain.
3. The fake notification trace checks matching observation/baseline IDs, UUID,
   bytes, interval and formatting. Later samples retain exactly one original
   alert. Simultaneous-alert suspension, cancellation, two-alert control and
   pending→clear reconciliation are explicitly covered.
4. `MonitoringProbeCancellationTests` executes both ordinary and genuinely
   refused-store paths with a selected-volume decrease and another disk's
   positive delta; neither path discards the decrease or sums unrelated disks.
5. The full ordinary suite includes existing lifecycle scheduling/cancellation,
   export, MCP/IPC, migration and resource regressions under TASK-616 supervision.

This is source-level, isolated functional assurance, not a notarized release,
installed-app test, real OS notification display, scale/overnight run or permission
to migrate the live store. UUID lookup can be unavailable on a filesystem; then
growth is explicitly unknown. Capacity metadata and UUID are sequential OS reads,
not an atomic guarantee against a physical hot-swap during the sampling call.
Legacy scale/soak/rollback tools remain fail-closed under TASK-616 until separately
ported to fully bounded setup. Later increment gates remain required.

## Canonical continuation checkpoint

At PLAN-DISK-STEWARD-006 revision 3 / graph 42, **TASK-616 and TASK-617 are
verified** and both have current assurance with no node-level blockers. The
dashboard audit event is `EVENT-20260920T105407415016Z-FD516D3F`; canonical
validation passed. No task is left claimed by this worker.

The next ready implementation work is TASK-614 (scope capacity admission) and
TASK-621 (object sizing/freshness). No increment gate has passed, and wider
object-model/real-scope/rollback/release assurance is still unfinished. Earlier
R3 handoff and CONTEXT graph-34 wording describes the pre-repair state; use
canonical Pyramid inspection plus this graph-42 checkpoint for continuation.
The installed application was not replaced. Current source also contains earlier
unreleased schema-15/object work; do not infer live-store migration or distribution
readiness from this dashboard audit.
