# TASK-521 implementation result

Result-record correction: the first implementation transition at G39 accepted prose-valued check statuses even though the published agent-result schema requires passed/failed/not-run. The coordinator caught the schema failure, preserved that original result in agent-result-format-original.json, and reopened/re-submitted through the runtime with enum statuses and separate detail fields. No product source, acceptance requirement or test result changed. The original event is not edited or erased.

17 September 2026. Core implementation acceptance for AC-TASK-521-01 and EVREQ-TASK-521-01. This is a worker result, not a passed brownfield audit or release.

## Accepted source and evidence

Final source/test hash: b9154fdc02be7a8912db7285d93eff51e9d55af44a013e0fdbb3beceb94ef555. Frozen directory: /private/tmp/disk-steward-521-core-final.ZAhMFh. Canonical source matches. Use the hash recipe and acceptance matrix in interval-progress.md; this result supersedes that report's earlier 9688186 candidate.

The final fresh-build isolated suite completed at 05:54:46 UTC: 369 tests, 368 passed, one native opt-in skip, zero failures, 29.955 seconds; process 60684 exited 0. Evidence: core-final-full.log. The targeted scanner, lifecycle, store and genuine historical-migration suite passed 88 tests in 4.551 seconds (core-final-targeted.log). No command used real user support/configuration/socket/watch data. The four native/packaged test opt-ins were unset as documented in interval-progress.md. git diff --check passes.

## Review-driven correction

The 9688186 candidate's full suite was green, but a bounded independent static review found two missing cases. Coordinator regressions reproduced both in scope-failure-red.log: two methods failed 25 assertions. The first two attempts had test compilation errors caused by using a nonexistent coverage-gap state member; those failures are preserved in scope-failure-compile.log and scope-failure-compile2.log, and are not counted as product reproductions. The corrected test reads endedAt.

1. A folder that left and later re-entered scope could turn its historical object/path into invented modify, replacement or delayed deletion events. Both ingestion paths now establish scope-entry baselines without monitored growth/debit. Old closed bindings remain history, not live predecessors. An occupied historical path yields its current row without marking the old physical object deleted. A later return of that old identity is also scope entry, using retained file-object lifecycle. That last case was independently reproduced with two failing assertions in return-history-red.log before correction.
2. When every watched root failed, abandonment bypassed failed-coverage publication and left prior rows actionable. A terminal traversal now completes even when its coverage failed, allowing the existing transaction to publish unknown/nonactionable current rows and open root gaps. Detail coverage is unavailable, not complete. Genuine scope/cursor abandonment remains separate. One/two-root failure, all four publication interruption points, reopen and recovery are covered. Old observation identity, bytes and sample time are retained; no deletion event is inferred.

Additional direct acceptance methods beyond interval-progress.md:

- EvidenceObjectLifecycleTests.testScopeReentryDoesNotInventReplacementGrowthOrDelayedDeletion: same identity, replacement and absent reentry, reopen, following scan, zero deltas and unknown scope-entry lower bound.
- DirectoryMetadataScannerConvergentScanGenerationTests.testGenerationScopeReentryUsesFreshBaselineWithoutPhantomChanges: the same matrix with real filesystem identity, plus the displaced historical object returning at another path.
- DirectoryMetadataScannerConvergentScanGenerationTests.testAllFailedRootsPublishUncertaintyAndRecoverWithoutFalseDeletion: single/two roots, four injected publication interruptions, previous truth on rollback, unknown persisted current rows, unavailable coverage and eventual recovery.

## Helper reconciliation

helper-core-candidate-result.json is retained as the failing review of 9688186. Its two findings were independently reproduced and corrected; it is not passing acceptance. helper-core-final-result.json is the exact b9154fd delta review, with zero new actionable findings. Both results validate against helper-result-v1. The coordinator matched helper identity, current TASK-521 guard, immutable snapshot, narrow read scope, finding/evidence/output budgets, empty changed-file lists and referenced source. One coordinator plus one helper used two of four slots, with no nested work. Raw results remain pending/ineligible, as required; this coordinator-owned report reconciles their relevant static evidence with independently executed tests. Neither static review nor green tests prove whole-product correctness.

## Complete product/test change inventory

- Sources/DiskStewardCore/Monitoring/DirectoryMetadataScanner.swift
- Sources/DiskStewardCore/EvidenceStore/EvidenceStore.swift
- Tests/DiskStewardCoreTests/Monitoring/ConvergentScanGenerationTests.swift
- Tests/DiskStewardCoreTests/EvidenceStore/EvidenceStoreTests.swift
- Tests/DiskStewardCoreTests/EvidenceStore/EvidenceObjectLifecycleTests.swift
- Tests/DiskStewardCoreTests/EvidenceStore/HistoricalEvidenceSchema.swift
- Tests/DiskStewardCoreTests/EvidenceStore/HistoricalMigrationTests.swift

All TASK-521 reports, helper envelopes/results and actual red/green logs are listed individually in agent-result.json. Assets: SCANNER, STORE, CONTRACTS. Existing changes in other repair tasks are preserved and are not attributed to TASK-521.

## Meaning and limits of implementation completion

The accepted core evidence covers superseded producing passes, restart/revalidation, overlapping/failed/all-failed roots, staged A/B/C mutation, durable dirty-token fencing and replay, object/path identity and accounting, actual sample/absence bounds, scope transitions, shared legacy reconciliation, atomic publication, transient input reclamation and genuine v5/v6 migration recovery. The interval-progress.md map connects each core acceptance clause to concrete tests in this exact run.

This does not make scans atomic snapshots. Historical timing not recorded at the time remains unknown. Unreleased preview-v9 stores are not supported migration inputs; no such fixture was installed as user state. No safety budget was raised, and legacy full-array return compatibility is not a streaming/scale claim.

integration-handoff.md remains required work: ordinary app hint routing under TASK-522 and public provenance/MCP/export occurrence semantics under TASK-552. Plan refinement makes those explicit instead of losing them in progress prose. Scale/resource work, service/API/setup acceptance, rollback controls, real-client checks and real overnight evidence remain required. OUTCOME-510 and brownfield inspections/findings still prevent calling this task verified. No installed-app changes, user deletion, signing, commit, push or release occurred.
