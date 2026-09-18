# TASK-522 — notification submission boundary

17 September 2026. Intermediate repair evidence, not whole-task completion or release approval.

## Identity and scope

- Starting source/test hash: `3039895c6af1c4b876d780e2fe6974039af0e2ff4d8b2e0e8425a4e3b48b03ad`; predecessor: `lifecycle-progress.md`.
- Accepted intermediate hash: `5da2e407b89521627ba4c31cb7a742eab423cef60155b49c97d9a8b541bdb140`; frozen source: `/private/tmp/disk-steward-522-notification-candidate.6FMZZT`. Canonical source and disposable execution tree `/private/tmp/disk-steward-522-lifecycle-dev.9CYz1T` match. No source changes after verification.
- Hash recipe: `rg --files --no-ignore -0 Package.swift Sources Tests Config Scripts DiskSteward.xcodeproj Integrations Schemas Fixtures Resources Extensions | sort -z | xargs -0 shasum -a 256 | shasum -a 256`.
- Two implementation/test changes in this subpatch: `Sources/DiskStewardApp/Notifications/UserNotificationDelivery.swift` and new `Tests/DiskStewardAppTests/Lifecycle/NotificationDeliveryTests.swift`. Preserve and inventory the six preceding lifecycle/probe/application files when submitting the eventual full TASK-522 result.
- R7 replan adds the exact delivery-adapter path and strengthens the existing AC01 suspended-callback proof. All 32 nodes, 97 edges, seven requirements and seven cumulative gates remain. No change to ordinary-hint AC02, original intent, constraints or non-goals.
- G47 replan: `EVENT-20260917T065220442236Z-30C7CC1A`; G48 impact: `EVENT-20260917T065324493154Z-ED5DE2F2`; G49 claim: `EVENT-20260917T065324802057Z-6F44F67C`, owner codex, task guard `GUARD-TASK-73A06B30BC3A88A3A574153DCB1FE549` at verification. Canonical updates used the runtime, not hand-edited projections.
- Plan/review/assurance candidates: `../notification-boundary-plan.json`, `../notification-boundary-plan-review.json`, `../notification-boundary-assurance.json`. Plan review and helper envelopes validated against plugin schemas using Python with `/private/tmp/millwright-doc-libs` after the default/bundled Python and bundled Node lacked validation packages. No dependency installation or plugin change.

## Boundary and behavior

The controller already cancels its owned sample when pause, sleep, quit or settings invalidation is accepted on MainActor. The old adapter ignored that cancellation after waiting for settings or permission. It could therefore submit a stale alert even while the UI correctly stayed paused.

Delivery now checks cancellation before touching the system center, after asynchronous settings retrieval, after authorization, and immediately before submission. Denied, refused, failed and unknown authorization fail closed. Existing authorized/provisional delivery keeps its title, body, sound, immediate trigger and unique request ID.

The last check and callback-based `UNUserNotificationCenter.add` invocation are synchronous on the same MainActor as lifecycle transitions. There is no suspension between them. System completion is still asynchronous, and the owned sample retains its safety marker until that completion. Shutdown's existing deadline does not pretend a held callback drained. Cancellation does not retract an alert already submitted to macOS; tests explicitly exercise that ordering and suppress the second alert in a two-threshold sample.

The system-center protocol is a narrow test boundary, not a replacement delivery algorithm. Production still uses Apple's shared center; tests inject a fake center and run the concrete `UserNotificationDelivery`. The installed SDK header and [Apple's notification center API](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter) confirm separate submission and completion entry points. The ordering guarantee is derived from our MainActor source and deterministic fixtures, not a claim about when macOS displays an alert.

## Reproduction and verification

- `notification-red.log`: the concrete adapter first received only the injectable center/main-actor seam, retaining the old unchecked authorization/submission flow. Seven tests ran: four failing methods, **26 failed assertions**, three passing methods. Held settings and authorization callbacks reproduced submission after pause, sleep, quit, direct settings pause and other settings invalidation. Already-cancelled entry and denied/refused/error submission also failed. The seam is disclosed: this is not a test of an untouched predecessor binary or actual macOS alerts.
- `notification-focused.log`: all **33** lifecycle/probe/notification tests pass after the checks; 0.946 seconds, session 32920 exit 0. Seven new methods cover fifteen pre-submission stop combinations, authorization failures and normal payloads, submitted-before-stop completion, second-alert suppression and unfinished-drain semantics. Tests hold and release callbacks explicitly, use bounded yield checkpoints and teardown releases, and never invoke a real center.
- `notification-full.log`: same exact source hash, **391 total = 390 passed, 1 native-client opt-in skipped, zero failures**, 28.751 seconds; finished 06:58:26 UTC, session 23066 exit 0. No test session remains live.
- `git diff --check` passes; Pyramid R7 G49 validates.

Full command, run from the disposable tree: `env -u DISK_STEWARD_NATIVE_CLIENT_TESTS -u DISK_STEWARD_PACKAGED_HELPER -u DISK_STEWARD_GATE_EVIDENCE -u DISK_STEWARD_CAPTURE_DIR CLANG_MODULE_CACHE_PATH=/private/tmp/disk-steward-522-lifecycle-dev.9CYz1T/module-cache swift test --disable-sandbox`. Focused command adds `--filter 'NotificationDeliveryTests|MonitoringLifecycleTests|MonitoringProbeCancellationTests'`. The full suite uses scoped host execution for isolated socket/FSEvents fixtures; real-client and packaged-helper opt-ins stay disabled.

## Independent review reconciliation

`helper-notification.json` and `helper-notification-result.json` match task guard, immutable hash, parent, phase and budgets (zero findings, seven evidence items, 4,404 compact JSON characters). Both schemas validate and change declarations are empty. One helper slot ran alongside the coordinator's full suite; no nested agents or helper mutations occurred.

The helper found no actionable defect in the bounded delta, traced the actual actor/submission path and confirmed that the held-completion fixture records submission before it waits. The coordinator independently inspected the same source, verified all three source hashes, reviewed the test output and accepted that static reasoning for this intermediate candidate. Raw output remains pending/ineligible as returned; it is not presented as independently executed tests or whole-task audit evidence.

## Remaining work and limits

TASK-522 remains working, not implemented. Ordinary file-change receipt, bounded callback delivery, durable invalidation/publication ordering, stream-generation fencing, and end-to-end pause/sleep/restart/persistence-failure evidence for AC02 remain unfinished. See `hint-publication-design-notes.md` for current code facts and the next design decision; it is not an accepted implementation.

Native permission UI, actual OS display and missing-callback behavior are not verified. The existing five-second quit drain bounds termination waiting; it does not force a missing permission/submission callback to return. Existing threshold edge state advances during evaluation, independent of successful delivery; this patch neither changes nor claims retry/rearming semantics. A packaged acceptance gate must remain separate.

Scale, database headroom, service/export/privacy/configuration audits, public occurrence intervals, rollback/monitoring controls and real overnight tests remain required by INTENT-005. Passing this suite does not close those obligations.

No installed app, real user evidence, watched files, agent configuration, signing identity, Git history or release was changed. No commit, push, installation or release is claimed.

## Follow-through

The R8 core receipt/commit and native-ingress work is recorded in `receipt-core-progress.md`. It preserves this notification adapter but does not complete ordinary-hint integration. This report remains historical evidence for source `5da2e407`.

The subsequent `implementation-handoff.md` records the integrated worker candidate and latest full/optimized verification. It supersedes this report's remaining implementation list, not its historical test results or release limitations.
