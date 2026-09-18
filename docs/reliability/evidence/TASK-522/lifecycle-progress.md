# TASK-522 — lifecycle ownership and shutdown progress

17 September 2026. This is intermediate implementation evidence, not completion of TASK-522, a Pyramid audit, or release approval. The preceding user-status turn made no implementation progress; this continuation reproduced failures, changed the owned lifecycle boundary, and verified an exact disposable candidate.

## Identity and scope

- PLAN-DISK-STEWARD-005 R6 G45; codex owns TASK-522 under GUARD-TASK-DA9EE5A600E3EF01E64FB53AE046A24C at verification time.
- Starting product/test hash: b9154fdc02be7a8912db7285d93eff51e9d55af44a013e0fdbb3beceb94ef555, frozen at /private/tmp/disk-steward-521-core-final.ZAhMFh.
- Final intermediate hash: 3039895c6af1c4b876d780e2fe6974039af0e2ff4d8b2e0e8425a4e3b48b03ad, frozen at /private/tmp/disk-steward-522-lifecycle-final.PiK4Sf. The canonical tree and disposable test copy /private/tmp/disk-steward-522-lifecycle-dev.9CYz1T match it.
- Hash recipe: `rg --files --no-ignore -0 Package.swift Sources Tests Config Scripts DiskSteward.xcodeproj Integrations Schemas Fixtures Resources Extensions | sort -z | xargs -0 shasum -a 256 | shasum -a 256`.
- Six changed implementation/test files relative to that base: Sources/DiskStewardApp/Lifecycle/MonitoringLifecycleController.swift; Sources/DiskStewardApp/Lifecycle/PersistentMonitoringProbe.swift; Sources/DiskStewardApp/ApplicationDelegate.swift; Sources/DiskStewardApp/StatusItemController.swift; Tests/DiskStewardAppTests/Lifecycle/MonitoringLifecycleTests.swift; new Tests/DiskStewardAppTests/Lifecycle/MonitoringProbeCancellationTests.swift. Existing unrelated dirty changes are preserved.
- Affected assets: LIFECYCLE, UI, and transitive STORE/SCANNER. No core-store/schema change in this subpatch. All authored files remain inside TASK-522's current scope.

## What changed

The controller owns one active sample regardless of timer, manual-refresh or debounce caller. Pause, sleep and quit cancel that task and fence late UI publication; coalesced work remains owned. Cancellation is cooperative: submitted atomic store work may finish, and confirmed completion releases the safety marker. Resume acknowledges only a previous-launch interruption, never an active sample's marker.

Normal quit now requests a bounded five-second drain through ApplicationDelegate and StatusItemController. A completed drain clears the marker through sample completion. A deadline does not fabricate clean completion; the unfinished marker remains, so a subsequent launch uses Safety Pause. There is one shared drain continuation, and completion/timeout cannot resume it twice. Terminal guards reject queued wake, resume, pause and sleep transitions after shutdown. This follows Apple's documented delayed-termination/reply contract; source compilation and controller fixtures are not packaged AppKit acceptance. [Apple applicationShouldTerminate](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)), [Apple termination reply](https://developer.apple.com/documentation/appkit/nsapplication/reply(toapplicationshouldterminate:)).

An injected lifecycle clock replaces real scheduling waits in the pause/sleep/coalescing regressions. A narrow collector protocol permits synthetic policy checks. The settings subscription uses incoming values because @Published publishes before storage: the previous code restarted the old scope and could restart a paused collector. Periodic-loop cleanup is UUID-fenced, and settings-driven unpause schedules one epoch-checked restart using the committed latest settings. Later pause/sleep/quit cancels it; later settings replace it without losing the requested start. An unrelated edit cannot hide the Safety Pause explanation.

The persistent probe checks cancellation before expensive phases and after awaited work, without claiming to roll back a completed transaction. Accepted commit bookkeeping advances before a post-commit cancellation can suppress the UI result; otherwise the next volume delta would use the wrong baseline. Deterministic volume and post-commit hooks test both first and later commits on the same probe. Partial-report text uses the store's returned generation rather than a possibly superseded input cursor.

## Reproductions and checks

All checks use disposable data/source copies; real-client, packaged-helper, gate-evidence and capture-directory opt-ins are unset. Test source is not run from the canonical repository. The full suite's temporary Unix sockets, FSEvents fixture and isolated smoke process require normal host permissions. A sandboxed attempt was retained as failed evidence, not passed or ignored.

| Evidence | Actual result |
| --- | --- |
| terminal-red.log / ownership-red.log | Before the fix, 2 methods/11 assertions and then 3 methods/14 assertions failed: premature marker clearing, terminal-state changes and uncancelled manually initiated work. |
| settings-red.log | Old root policy reused and paused collector restarted: 2 failed assertions. |
| probe-red.log | Already-cancelled sampling still called the resource source: 1 failed assertion. The pre-submission cancellation case already passed due to existing SQLite cancellation; it is additional coverage, not a newly reproduced store defect. This run restored only the baseline probe in the disposable copy. |
| ownership-tests.log / lifecycle-final-focused.log | Test-harness compile mistakes (Sendable annotation and misplaced teardown respectively), subsequently corrected; not product regressions. |
| lifecycle-full.log | Sandboxed run failed (50 assertions, including EPERM local sockets, FSEvents, xcrun and capacity checks). Same 942a5d8 candidate passed under isolated host execution in lifecycle-full-host.log: 379 passed, 1 skipped. |
| review-red.log | Review-driven direct-settings loop and post-commit baseline reproductions: 2 methods, 5 failed assertions. |
| unpause-red.log / queued-settings-red.log | Direct unpause failed; then a newer settings update cancelled its queued restart without replacement. Bounded fixture failure replaced a potential hanging test. |
| safety-reason-red.log | Unrelated interval edit hid the Safety Pause reason: 1 failed assertion. |
| safety-reason-tests.log | Final hash: all 26 focused lifecycle/probe methods passed, 0.796 seconds. Includes zero/negative shutdown deadlines, completion/deadline race, early-timeout oracle, marker recovery, latest-settings scheduling, partial/failed real probe presentation and committed-cancellation baselines. |
| lifecycle-final-full.log | Final hash: 384 total, **383 passed, 1 native-client opt-in skipped, zero failures**, 27.646 seconds; ended 06:40:47 UTC, session 15850 exit 0. |

Other intermediate logs retain their original names and are not substituted for final-hash proof. The earlier candidate hashes 942a5d8, 6d22b93 and a855ff7 passed suites but were not accepted as sufficient after review found more cases. No source edits followed final verification. `git diff --check` passes.

Commands: `env -u DISK_STEWARD_NATIVE_CLIENT_TESTS -u DISK_STEWARD_PACKAGED_HELPER -u DISK_STEWARD_GATE_EVIDENCE -u DISK_STEWARD_CAPTURE_DIR CLANG_MODULE_CACHE_PATH=/private/tmp/disk-steward-522-lifecycle-dev.9CYz1T/module-cache swift test --disable-sandbox`; focused runs add `--filter 'MonitoringLifecycleTests|MonitoringProbeCancellationTests'`.

## Helper reconciliation

The preflight and three candidate/delta envelopes are retained with their jobs and schema-validated results. All match parent/guard, immutable snapshot, <=5 findings, <=8 evidence items, <=6500 compact JSON characters and empty change declarations. Raw results remain pending/ineligible as returned; none is represented as independent runtime validation or final approval.

Preflight marker ownership, stop-task ownership and terminal-state findings were independently read and reproduced. Its notification send-boundary and stale collector-callback findings remain open. Its broad concern about post-stop store writes is qualified by the actual SQLite cancellation behavior observed in probe-red.log; the policy is cooperative cancellation plus drain, not retroactive rollback.

The 942a5d8 review found the loop and committed-baseline failures, both reproduced in review-red.log and corrected. It also found insufficient deadline/gate test controls: clocks now assert pending timeout at four seconds, support nonpositive waits, and waits throw after a bound with teardown releasing probes. The 6d22b93 review found direct settings unpause, reproduced and corrected; the additional queued-settings case was independently found/reproduced by the coordinator. The a855ff7 review found safety-reason loss, reproduced and corrected by the final three-line guard plus regression. Those older candidate reviews are stale for final approval; the coordinator inspected that final small delta and reran the exact-hash focused/full checks. This is acceptance of a bounded intermediate patch only.

## Remaining TASK-522 work — do not mark implemented

1. AC-TASK-522-02 is not satisfied. The callback still schedules ordinary hints without durably invalidating affected passes; one task per batch and stale callbacks across restart still need bounded receipt/coalescing and generation fences. A passing core-store invalidation test is not end-to-end controller/probe/store proof. Include equal-time signals, in-flight slices, root isolation, restart, pause/sleep and persistence failure. Do not silently swallow failed invalidation or claim an atomic filesystem snapshot.
2. AC-TASK-522-01 is only partly satisfied. Owned-task cancellation exists, but UserNotificationDelivery still needs a delivery-side check at the external-send boundary, including a suspended authorization/delivery fixture. Notifications already handed to the OS cannot be retroactively prevented. That file is outside current TASK-522 write scope: extend the contract/impact map through Pyramid before editing it; do not bypass scope.
3. Evidence-store receipt/publish ordering may require a scoped core API extension. If so, replan its ownership/impact explicitly before touching Core. Inspect actual code rather than relying on older summaries: recordFSEvents currently persists hint receipts but calls upsertReconciliationInvalidation only for new gap evidence; ordinary per-root invalidation is not wired there or in the app. No design choice has yet been accepted for this boundary.
4. Keep the public occurrence-interval work assigned to TASK-552. Scale, database headroom, service/export/config regression gates, rollback/monitoring controls and overnight tests remain in the original plan. These 384 tests do not close those requirements.

No installed application, user evidence, watched files, real client configuration, signing identity, git history or release was changed. No commit, push, installation or release is claimed.

## Follow-through

The subsequent R7 notification-adapter subpatch and exact-hash verification are recorded in `notification-progress.md`. Its completion addresses the delivery-side portion above; the original report remains historical evidence for source3039895. TASK-522's ordinary-hint acceptance remains unfinished.

The later `implementation-handoff.md` records the complete worker implementation and accepted candidate, including ordinary hints and corrected shared receipt/recovery-marker ownership. The unfinished statements above describe their historical candidate, not the later implementation. Brownfield audit and intent completion remain separate.
