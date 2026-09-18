# TASK-522 — receipt/commit core and bounded native ingress

17 September 2026. Intermediate implementation evidence; TASK-522 and INTENT-005 remain incomplete. The preceding user-status turn recovered the previously unseen test failure but made no implementation change. This continuation reran the same failed check with fixture socket access, strengthened concurrency testing, bounded native ingress, reproduced a review finding and repaired it.

## Identity and scope

- Parent: PLAN-DISK-STEWARD-005 R8 G53, owner codex, task guard `GUARD-TASK-22D0081DF53D051CF5A58CA0A88D3A0D` during execution/review. R8 scope/impact was explicitly approved through runtime replan G51, impact G52 and claim G53. The historical scope warning in `hint-publication-design-notes.md` describes R7, not the current contract.
- Predecessor: `notification-progress.md`, source/test hash `5da2e407b89521627ba4c31cb7a742eab423cef60155b49c97d9a8b541bdb140`.
- Initial reviewed publication snapshot: `97393b69e4cabbe88a27715d32456f58f583730d5b234ca890a0c80b810b08d4`, frozen at `/private/tmp/disk-steward-522-publication-candidate.CIOxRx`. It passed 397 tests with one skip, but review subsequently identified a cancellation error-classification regression; that green suite was insufficient.
- Combined verified source/test hash: `0bc06c388195bfb255a75ddd985ee39d51f3047c6c89df55b82d0f1976ad2b0d`, frozen at `/private/tmp/disk-steward-522-receipt-core.PBVfDl`. Canonical source and disposable execution tree `/private/tmp/disk-steward-522-lifecycle-dev.9CYz1T` match.
- Hash recipe: `rg --files --no-ignore -0 Package.swift Sources Tests Config Scripts DiskSteward.xcodeproj Integrations Schemas Fixtures Resources Extensions | sort -z | xargs -0 shasum -a 256 | shasum -a 256`.

Six source/test files changed relative to the notification predecessor:

1. New `Sources/DiskStewardCore/Monitoring/ScanPublicationFence.swift`.
2. `Sources/DiskStewardCore/EvidenceStore/EvidenceStore.swift`.
3. `Sources/DiskStewardCore/EvidenceStore/SQLiteConnection.swift`.
4. `Sources/DiskStewardCore/Monitoring/TargetedFSEventsCollector.swift`.
5. New `Tests/DiskStewardCoreTests/Monitoring/ScanPublicationFenceTests.swift`.
6. `Tests/DiskStewardCoreTests/Monitoring/MonitoringTests.swift`.

All are inside R8 scope and map to STORE/SCANNER. No schema, public export contract, app wiring or Xcode project change in this subpatch. Preserve/inventory the preceding lifecycle and notification files in the eventual complete TASK-522 result. Existing unrelated edits remain untouched.

## Publication ordering

`ScanPublicationFence` serializes receipt acceptance against only final publication COMMIT. A UUID revision, not wall time, fences stale permits. Pending receipts prohibit new permits. Acknowledging an older revision cannot clear newer pending state. The owner must durably persist the cumulative pending receipt set before acknowledging its latest revision; this class is not a durable inbox.

`recordScanSlice` accepts an optional permit, validates before admission, and passes it to both final reconciliation transaction branches. An accepted receipt during preparation rejects final COMMIT and rolls back changes to authoritative current state, event history and observation. Earlier separately committed staging/snapshot work may remain: the owner must invalidate/reconcile it. Nil-permit callers retain prior behavior; the app does not yet supply a permit.

The receipt lock is not held across traversal or reconciliation preparation. A fixture accepts a receipt on another queue at each of three transaction checkpoints; a two-second bound turns an accidentally enlarged critical section into a failing test rather than a deadlock. Guarded COMMIT disables SQLite busy retries, then restores the existing cancellation-aware handler. This prevents the reproduced 6.8-second reader-lock retry while holding the receipt fence, but does not promise a hard disk-I/O/auto-checkpoint latency bound.

Review identified a cancelled failed COMMIT escaping as a SQLite error. The corrected catch restores the prior `CancellationError` normalization without re-enabling retries. A test-only SQLite commit hook cancels the actual current task inside native COMMIT and rejects it. The next uncancelled actor call verifies rollback and connection reuse. No production injection hook was added.

## Native ingress bounds and lifetime

The production FSEvents callback borrows its native NSArray. It no longer bridges every path or copies every flag/ID into Swift arrays. More than 256 events, inconsistent lengths, non-absolute/invalid paths or paths longer than 4,096 UTF-16 units produce one explicit global reconciliation-gap batch, with no retained hints. Normal bounded batches preserve filtering, event IDs, kinds, flags and uncertainty. Repeated gap flags yield one limitation rather than repeated strings.

These are admission limits, not macOS filesystem limits. The native OS buffer already exists; this patch bounds additional decoded hints and path copies, not OS allocations, configured root count, policy normalization cost or the app's still-unbounded number of per-batch tasks. Overflow is conservative uncertainty, not proof of deletion or writer attribution.

Callback context is retained/released by the stream, with `withExtendedLifetime` covering creation before native retain. This follows Apple's documented context callbacks, confirmed in the installed SDK header. [Apple FSEventStreamContext](https://developer.apple.com/documentation/coreservices/fseventstreamcontext). The existing native temporary-root smoke test and a new handler-lifetime test pass. Arbitrary concurrent public start/stop calls are not newly proven; production lifecycle calls remain MainActor-serialized.

## Reproduction and verification

- `publication-red.log`: four methods, twelve failed assertions before wiring the optional permit into store publication; the API seam was already present. Not an untouched-binary claim.
- `publication-sqlite-red.log`: two methods, four failures before transaction fencing; conflicting-reader retry took 6.8115 seconds, and superseded writes committed.
- `publication-focused.log`: original sandboxed run, 58/59 methods passed, socket fixture failed with `connectionFailed(1)`. Same candidate rerun with scoped host access: all 59 passed, session 44687 exit 0, 2.856 seconds. No code change was needed for that failure. It is consistent with the sandbox restriction, not evidence of a repaired socket defect.
- `publication-full.log`: after concurrent-checkpoint test hardening, 397 total, 396 passed, one native-client opt-in skip, zero failures; session 44895 exit 0, 28.057 seconds. Superseded by the later reviewed candidate below.
- `collector-red.log`: three new methods failed seven assertions on the previous interpreter: 10,000 retained hints, silent malformed-batch loss and oversized path retention. Existing filter/gap test passed.
- `collector-focused.log`: initial bounded-collector candidate, fourteen methods passed. This predates the explicit creation lifetime and handler-release fixture; not final proof.
- `publication-cancellation-red.log`: the native commit-hook regression failed before the catch correction. It reproduced the helper's concrete finding.
- `receipt-core-focused.log`: final hash, all 28 publication/SQLite/monitoring methods passed, session 87393 exit 0, 0.679 seconds. Includes a lazy one-billion count fixture with zero element reads, native adapter malformed paths, native handler retention/release, conflict rollback, reopen recovery and commit-hook cancellation. Compiler emitted one harmless weak-variable mutability suggestion in a test; no build error.
- `receipt-core-full.log`: final hash, **404 total = 403 passed, one native-client opt-in skipped, zero failures**, session 64230 exit 0, 29.213 seconds, finished 07:29:14 UTC.
- `receipt-core-release.log`: same final hash under optimized Swift/ARC, **22 focused methods passed**, session 42167 exit 0, 0.168 seconds after a 41.69-second build with two jobs. Includes both native callback fixtures and all seven publication tests. This is an optimized test build, not a signed/notarized app or packaged acceptance run. The test-only weak-variable suggestion also occurs in a pre-existing endpoint test.

Commands run from the disposable tree: `env -u DISK_STEWARD_NATIVE_CLIENT_TESTS -u DISK_STEWARD_PACKAGED_HELPER -u DISK_STEWARD_GATE_EVIDENCE -u DISK_STEWARD_CAPTURE_DIR CLANG_MODULE_CACHE_PATH=/private/tmp/disk-steward-522-lifecycle-dev.9CYz1T/module-cache swift test --disable-sandbox`. Focused final run adds `--filter 'ScanPublicationFenceTests|MonitoringTests|SQLiteCancellationTests'`. Full/fixture-native checks use scoped host execution for local sockets and FSEvents. No real client, packaged helper or production watched roots are enabled.

The optimized run adds `-c release --jobs 2 --filter 'ScanPublicationFenceTests|MonitoringTests'`. All observed test sessions are terminal. `git diff --check` and Pyramid validation pass. A source/test directory comparison confirms exactly the six listed file changes against the predecessor.

## Helper reconciliation

Both job/result pairs (`helper-publication*` and `helper-receipt-core*`) validate against the plugin schemas. Parent, task guard, phase and snapshot match; result budgets are respected (first: one finding/seven evidence items/5,412 compact JSON characters; second: zero findings/seven evidence items/4,984 characters). Change declarations are empty. One helper slot performed read-only source validation alongside coordinator execution; no helper wrote files, ran native code or mutated Pyramid.

The initial helper's cancellation finding was independently reproduced and repaired. Its scope qualifications are retained above: earlier staging can survive a rejected final publication, acknowledgement must cover cumulative receipts, and native I/O is not hard time-bounded. The initial snapshot/result is historical, not current approval. The final helper confirmed the corrective path and native ingress/lifetime implementation with no new actionable finding. The coordinator checked matching source hashes, code and actual focused/full/optimized results before accepting this limited intermediate patch. Raw helper results remain pending/ineligible as returned; they are not presented as independent runtime tests or whole-task acceptance.

## Next required composition — not implemented

AC02 still requires a bounded coalescing mailbox and one owned drain, synchronous receipt acceptance into this fence, stream-generation identity, durable per-root invalidation, cumulative acknowledgement, persistence-failure retry, and startup/resume uncertainty. Currently the app still schedules a task per batch and only persists gap hints via a swallowing `try?`; the core API alone does not fix that route.

Coalesce by affected configured root, not arbitrary file path: the store's invalidation key is root plus reason, so per-file keys would increase durable rows unnecessarily. Bound the set and fall back to a global gap on overflow. Preserve pending changes that arrive while persistence awaits; never acknowledge a newer revision after persisting an older, incomplete set. The sample and receipt drain need coordinated marker/shutdown ownership, so one finishing job cannot clear another active job's safety marker. A SinceNow stream needs a durable startup/resume gap before resumed staging can publish.

The actual controller/probe/store fixtures still must cover receipt before admission and during preparation, equal-time events, independent roots, pause/sleep/restart, stale callbacks, burst bounds and deliberate persistence failure. Scale, database headroom, MCP/export/privacy/onboarding audits, public occurrence intervals, rollback/monitoring controls and real overnight acceptance remain obligations of the unchanged intent. These 404 tests do not substitute for them.

No installed app, user evidence, real client configuration, signing identity, Git history or release was changed. No commit, push, installation or release is claimed.

## Canonical progress marker

Runtime `update --status at-risk` recorded `EVENT-20260917T073444558734Z-EDAAD3BF`, advancing R8 to G54. Execution remains working, verification unverified, owner codex; no task completion or gate pass was recorded. It links this report and the exact candidate and names the missing app composition. Current task guard is `GUARD-TASK-4C98A07F39E013F9ACF3E7D64B0F2F8A`, context `CTX-2D7C7EA6CF15679907716777FC59959E`. Helper reconciliation happened before this guard transition. No scope drift was introduced.

## Later composition

`implementation-handoff.md` records the completed app receipt integration, recovery-marker reproductions/corrections and exact accepted candidate. Its evidence supersedes the missing implementation list above. This report remains the receipt-core predecessor; its historical G54 state must not be mistaken for current canonical status.
