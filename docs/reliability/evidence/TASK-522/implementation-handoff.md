# TASK-522 — lifecycle and ordinary-change integration handoff

17 September 2026. Implementation evidence for PLAN-DISK-STEWARD-005 R8. This completes the worker's scoped implementation, not its brownfield audit, OUTCOME-520, the whole intent, or a release. The earlier user-status turn recovered passing logs but made no implementation change. This continuation completed candidate verification, reproduced and fixed two recovery-marker defects, strengthened a misleading test oracle, and reconciled task provenance.

## Exact candidate and chronology

- Task baseline: `b9154fdc02be7a8912db7285d93eff51e9d55af44a013e0fdbb3beceb94ef555`, frozen in `/private/tmp/disk-steward-521-core-final.ZAhMFh`.
- Lifecycle predecessor `3039895c...`: `lifecycle-progress.md`.
- Notification predecessor `5da2e407...`: `notification-progress.md`.
- Receipt-core predecessor `0bc06c388195bfb255a75ddd985ee39d51f3047c6c89df55b82d0f1976ad2b0d`: `receipt-core-progress.md`.
- First integrated candidate `2a6e7b6e5be251a946163c0e210beef2c03afacf7e1c84727154ba24f8216125`, frozen in `/private/tmp/disk-steward-522-inbox-review.uxMyD4`: green suite but subsequently reproduced marker defects. Not the accepted candidate.
- Corrected product candidate `51cf05199dfc307788edae3052319853e44592d608fbdb8e64bb46dbf9d324a0`, frozen in `/private/tmp/disk-steward-522-inbox-final.H8j2Er`: product fixes pass, but review found an insufficient partial-persistence test oracle.
- Accepted source/test candidate **`b3b546fb1c09a77825ab564ef449fc748e216a36f03bbfe5871e85d0c8c54d21`**, frozen in `/private/tmp/disk-steward-522-inbox-accepted.3NjURz`. Product source is identical to `51cf0519`; the sole further change is the corrected test oracle. Canonical and disposable execution trees match this hash.

Hash recipe, from each root: `rg --files --no-ignore -0 Package.swift Sources Tests Config Scripts DiskSteward.xcodeproj Integrations Schemas Fixtures Resources Extensions | sort -z | xargs -0 shasum -a 256 | shasum -a 256`. Documentation is deliberately outside this product/test hash. Execution copy: `/private/tmp/disk-steward-522-lifecycle-dev.9CYz1T`.

## Complete implementation-file inventory

Compared with the task baseline, exactly these fifteen source/test files differ; no unrelated dirty edits were reverted:

1. `Sources/DiskStewardApp/ApplicationDelegate.swift`
2. `Sources/DiskStewardApp/StatusItemController.swift`
3. `Sources/DiskStewardApp/Lifecycle/MonitoringLifecycleController.swift`
4. `Sources/DiskStewardApp/Lifecycle/PersistentMonitoringProbe.swift`
5. `Sources/DiskStewardApp/Notifications/UserNotificationDelivery.swift`
6. `Sources/DiskStewardCore/EvidenceStore/EvidenceStore.swift`
7. `Sources/DiskStewardCore/EvidenceStore/SQLiteConnection.swift`
8. New `Sources/DiskStewardCore/Monitoring/ScanPublicationFence.swift`
9. `Sources/DiskStewardCore/Monitoring/TargetedFSEventsCollector.swift`
10. `Tests/DiskStewardAppTests/Lifecycle/MonitoringLifecycleTests.swift`
11. New `Tests/DiskStewardAppTests/Lifecycle/MonitoringProbeCancellationTests.swift`
12. New `Tests/DiskStewardAppTests/Lifecycle/NotificationDeliveryTests.swift`
13. New `Tests/DiskStewardAppTests/Lifecycle/MonitoringReceiptTests.swift`
14. `Tests/DiskStewardCoreTests/Monitoring/MonitoringTests.swift`
15. New `Tests/DiskStewardCoreTests/Monitoring/ScanPublicationFenceTests.swift`

Five files changed since the receipt-core predecessor: the controller, probe, lifecycle tests (shared fake clock visibility), new receipt tests, and EvidenceStore's no-op-by-default invalidation checkpoint. All are within R8 write scope. Assets: BOOT, LIFECYCLE, UI, STORE, SCANNER. ApplicationDelegate and StatusItemController were already permitted source paths, but ASSET-BOOT was missing from TASK-522's impact records. `assurance-boot-map.json` adds that confirmed mapping and a planned pre-audit inspection without claiming packaged AppKit acceptance or changing the task contract.

## Integrated behavior

The native callback now enters one bounded cumulative inbox synchronously, before any actor hop. It never retains a native batch or creates one task per event. At most 64 affected configured roots are retained, with 256-hint and 4,096-UTF16-unit path admission; overflow or malformed input becomes global uncertainty. These are app admission bounds, not limits on OS-owned buffers or all configured-root work.

Each accepted batch changes a UUID publication revision, even at the same timestamp. One reserved wake feeds one owned controller drain. A stream UUID rejects callbacks from replaced/stopped streams. Startup, restart and stream stop retain a global gap because a SinceNow stream cannot prove missed history. Receipt acceptance fences the sample's shared permit; final SQLite COMMIT is serialized with that acceptance, while filesystem traversal and transaction preparation do not hold the receipt fence. A receipt after a completed COMMIT does not undo that earlier observation.

The probe shares one persistence attempt between callers. It snapshots cumulative roots, durably invalidates each affected pass, and acknowledges only that exact revision after all writes succeed. A newer receipt keeps old plus new roots pending. Partial failure retains the cumulative set and denies new publication permits; bounded retries reapply it conservatively. Pending work drains during pause/sleep. Quit has a deadline and reports undrained work honestly. A fresh probe establishes startup uncertainty before resumed staging can publish, including after an unpersisted receipt was lost with the prior process.

Samples and receipt drains jointly own the current safety marker. A clean receipt drain cannot acknowledge a previous crash; only explicit resume releases that prior-launch requirement. Resume cannot clear the marker while current sample/drain work or an unpersisted receipt remains. This distinction fixes both reproduced integration regressions.

Previous lifecycle epoch/cancellation, partial-coverage presentation, post-commit baseline, and notification submission-boundary repairs remain. The concrete notification adapter rechecks cancellation after settings/authorization and synchronously before OS submission on MainActor. Already-submitted notifications are not retroactively revoked.

## Requirement-to-evidence map

| Contract | Current evidence |
| --- | --- |
| AC01: pause/sleep/quit and settings cannot publish late status or follow-up samples | `MonitoringLifecycleTests`, `MonitoringProbeCancellationTests`; existing fake-clock stop, coalescing, direct-settings, deadline and committed-baseline fixtures all pass on the accepted candidate. |
| AC01: no late notification submission; already-submitted completion remains owned | Seven `NotificationDeliveryTests` use the real adapter and a synthetic system center, holding settings, authorization and submission callbacks. No real permission prompt. |
| AC01: partial/failed detail is not all-current | Real probe coverage tests and status assertions remain in the full/optimized suite. |
| AC01: recovery ownership survives new receipt work | Two new receipt tests reproduce prior-crash marker clearing on shutdown and explicit resume during held invalidation, then prove preservation and eventual correct clearing. |
| AC02: ordinary hint before store admission or during transaction preparation | Two collector/controller/probe/store tests gate an already-issued permit before the volume phase or at `after-present-objects`, delete fixture A, deliver an ordinary callback, and require unchanged baseline/observation count before a later validated B/C result and exactly one A deletion. |
| AC02: equal-time cumulative receipts and persistence failure | The actual store is held at `before-invalidation` after A was snapshotted. Equal-time B arrives; A completion cannot acknowledge it. A trigger then fails the second sorted root. A separately read transactional counter proves the first root newly committed in that failing attempt, not merely in an older attempt. Retry keeps the same cumulative revision until both roots persist. |
| AC02: unaffected roots, pause/sleep, old streams and restart | Real partial generations retain an independent root's progress. Paused/sleeping controllers persist receipts without sampling and reject old callbacks after resume. A reopened store/new probe resets interrupted staging before it can publish and produces one validated deletion. |
| AC02: bounded ingress/wakes and explicit overflow | 10,000 accepted mailbox receipts require one wake; native interpreter tests reject huge counts before reading elements and bound copied paths/hints. Overflow is global reconciliation uncertainty, never deletion evidence. |
| AC02: final commit ordering/rollback and bounded lock use | Seven `ScanPublicationFenceTests` cover receipt before entry, during three preparation checkpoints on another queue, after commit, old acknowledgements, rollback/connection reuse, busy-reader rejection, and native-COMMIT cancellation normalization. |

## Reproduction and verification

All execution used disposable databases/settings/roots/sockets, never installed application state or real client configuration. Normal host permissions were needed for isolated Unix-socket and FSEvents fixtures. Four native-client/packaged-helper/capture opt-ins remained unset.

- `inbox-recovery-tests.log`: initial eight receipt tests pass; `inbox-full.log`: first integrated candidate, 412 total / 411 passed / one opt-in skipped / zero failures. These do not prove the later marker fixes.
- `inbox-recovery-marker-red.log`: one new method fails two assertions: successful drain cleared the unacknowledged crash marker and next launch lost Safety Pause.
- `inbox-overlap-red.log`: test-seam compile failure due to actor-isolated closure capture, fixed by copying the existing Sendable checkpoint before the transaction closure. Not a runtime product reproduction.
- `inbox-overlap-red-compiled.log`: equal-time real-persistence test passes; resume-during-persistence fails its marker assertion. Product fix adds ownership guards to resume and work completion.
- `inbox-final-focused.log`: 52 focused methods pass on `51cf0519`; `inbox-final-full.log`: 416 total / 415 passed / one skip / no failures; `inbox-final-release.log`: 67 optimized methods pass. Review still required strengthening one test oracle.
- **`inbox-accepted-focused.log`**: final `b3b546fb`, all twelve receipt methods pass, 1.721 seconds, session 13188 exit 0.
- **`inbox-accepted-full.log`**: final `b3b546fb`, **416 total = 415 passed, one native-client opt-in skipped, zero failures**, 28.822 seconds, session 13033 exit 0; completed 08:05:25 UTC.
- **`inbox-accepted-release.log`**: same final hash, **67 optimized lifecycle/notification/receipt/publication/native-ingress methods passed**, 2.186 seconds after a 6.45-second incremental build, session 86006 exit 0.

Base command: `env -u DISK_STEWARD_NATIVE_CLIENT_TESTS -u DISK_STEWARD_PACKAGED_HELPER -u DISK_STEWARD_GATE_EVIDENCE -u DISK_STEWARD_CAPTURE_DIR CLANG_MODULE_CACHE_PATH=/private/tmp/disk-steward-522-lifecycle-dev.9CYz1T/module-cache swift test --disable-sandbox --jobs 2`. Receipt-only adds `--filter MonitoringReceiptTests`. Optimized adds `-c release --filter 'MonitoringReceiptTests|MonitoringLifecycleTests|MonitoringProbeCancellationTests|NotificationDeliveryTests|ScanPublicationFenceTests|MonitoringTests'`. No source edits followed accepted-candidate verification. `git diff --check` passes.

## Review reconciliation and history

Three new helper job/result pairs validate against their schemas, match parent/guard/snapshot/phase, have empty change declarations, and stay within budgets (4,852; 4,938; 3,092 compact JSON characters). One spare helper slot was used for read-only frozen-source review alongside coordinator test execution. No helper mutations, native activation or untracked delegation occurred.

The first review's two marker defects were independently reproduced and fixed. Its missing actual-persistence race proof was added. The second review correctly rejected a misleading partial-write oracle: `other` sorted before `watched`, so the failure happened first. The corrected `z-other` ordering and a committed first-root counter resolve that gap, as confirmed by the final one-file review and rerun tests. The coordinator compared production trees and confirmed no product change after `51cf0519`, checked hashes and references, and reconciled all findings before the subsequent canonical impact/implementation transition. Raw helper results remain pending/ineligible as returned: static reviews are not independently run tests or audit approval.

This handoff supersedes the **remaining TASK-522 implementation** sections of the three predecessor reports, which remain immutable historical descriptions of their earlier candidates. `agent-result.json` inventories every task implementation file plus evidence and replan records. Canonical state must be updated with the runtime, not by editing task projections.

## Limits and next assurance boundary

No claim of an atomic filesystem snapshot, exact writer attribution, hard disk-I/O deadline, exhaustive concurrency proof, native notification display or signed/packaged acceptance. The final COMMIT lock disables SQLite busy retries but cannot make underlying disk I/O instantaneous. Sustained mutation can require repeated reconciliation; useful 100k/1M progress, database headroom, durable traversal and memory measurements remain RESEARCH-530/TASK-531/TASK-532, not waived by these tests.

TASK-522's worker implementation can be submitted; required BOOT/LIFECYCLE/UI/STORE/SCANNER inspections and cumulative GATE-519/GATE-529 assurance remain pending. Seven material intent findings, remaining MCP/export/privacy/onboarding work, CI, overnight supervision, rollback and monitoring controls remain open. Do not mark INTENT-005 complete or infer release readiness. No installed app, user files/evidence, client configuration, signing identity, Git history, push or release was changed.

## Canonical submission and next work

The runtime applied the BOOT impact mapping at G55 (`EVENT-20260917T081122955107Z-37246815`), then accepted the complete worker result at G56 (`EVENT-20260917T081241369433Z-C9D5939F`). TASK-522 is now **implemented / verification pending / health clear / no owner**, with no scope drift. Context: `CTX-D644710364BBEC82590A99F2CED9E217`. No audit pass was recorded. Plan validation passes, and history doctor reports 11 valid records, six chronicles, no pending append and no errors; zero commit bindings remain, so no exact committed replay is claimed.

GATE-519 is not audit-ready: TASK-511/TASK-512 require verification, relevant inspections are stale, and material findings remain open. Do not force a pass from this task's suite. The ready frontier still includes RESEARCH-530, TASK-551, TASK-552 and TASK-571. The next capacity work should measure representative 100k/1M traversal/publication alternatives before choosing TASK-531/TASK-532 changes; all original intent obligations remain active.
