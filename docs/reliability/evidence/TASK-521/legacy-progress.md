# TASK-521: shared legacy reconciliation progress

Subsequent interval/alias fixes and exact-candidate acceptance mapping are recorded in interval-progress.md. This file preserves the earlier G38 progress state and its then-open questions.

17 September 2026. Continues timestamp-progress.md. This is progress evidence, not task completion, an acceptance audit, or release approval.

## Candidate and scope

Implementation started from PLAN-DISK-STEWARD-005 R5 G36, actor codex, task guard GUARD-TASK-B003AB2C2E5CA83767E2EFF94C9DDF10. The claim expired at 05:14:17 UTC and was reclaimed through the runtime at 05:15:10 UTC, G37, task guard GUARD-TASK-731A15271692D0AA63D88B1C83495EB2. No source work was performed while ownership was expired.

Initial frozen candidate: /private/tmp/disk-steward-521-legacy-candidate.UwUGtK, SHA-256 c253f99916117353c064612cecf907a0138d2955c6b855951b778479d8474c49.
Whitespace-clean frozen candidate: /private/tmp/disk-steward-521-legacy-clean.DusclS.
Product/test SHA-256: 9c16bd2d2abcaf56683ac4a3d5084c0505d0e7a608cc05b2cce8dcb5e81803e5.
The canonical product/test source matched this hash after testing. Hash recipe is the same as timestamp-progress.md.

This increment changes:

- Sources/DiskStewardCore/EvidenceStore/EvidenceStore.swift
- Tests/DiskStewardCoreTests/EvidenceStore/EvidenceObjectLifecycleTests.swift

The complete TASK-521 source/test inventory additionally includes:

- Sources/DiskStewardCore/Monitoring/DirectoryMetadataScanner.swift
- Tests/DiskStewardCoreTests/Monitoring/ConvergentScanGenerationTests.swift
- Tests/DiskStewardCoreTests/EvidenceStore/EvidenceStoreTests.swift
- Tests/DiskStewardCoreTests/EvidenceStore/HistoricalEvidenceSchema.swift
- Tests/DiskStewardCoreTests/EvidenceStore/HistoricalMigrationTests.swift

Assets remain ASSET-SCANNER, ASSET-STORE and ASSET-CONTRACTS. Earlier changes and archived Pyramid history are preserved. No new schema migration is introduced by this increment; prior unreleased schema-9 caveats remain.

## Behavior

Both ingestion paths now call one indexed object/path reconciliation kernel. Generation input still requires validated producing directory passes and retains its bounded inline result window. Legacy metadata is adapted into a transaction-local indexed temporary table, without fabricating directory proofs or changing active-generation staging.

Legacy positive partial observations are retained. Missing data under failed/partial coverage stays unknown with its last-known observation. Replacements reconcile each physical object once, retain surviving or uncertain aliases, and support path swaps without current-state uniqueness collisions. Rename plus growth emits both kinds of evidence. Scope changes do not imply rename/deletion.

Actual sample timestamps are preserved in current state, path bindings and history. The legacy observation envelope starts at its earliest supplied sample and ends at the caller's observation completion time. Without an explicit sample time, its single-snapshot observation time remains the fallback. Complete generation absence still uses directory-pass evidence.

The legacy full-array return contract is intentionally preserved and tested above the generation's 2,048-row inline window. It is not claimed to be a streaming interface. Replacement event cardinality deliberately changes: incoming and retired objects each have their own event, rather than one ambiguous path-pair delta.

A partial legacy observation can no longer close a global event-loss gap. Durable dirty evidence is reflected in its event-gap flag and cannot be resolved by a legacy snapshot with no generation proof.

## Reproductions and checks

All commands used disposable copies and unset native-client/packaged-helper opt-ins. No real user files, evidence stores, app endpoints or client configurations were used.

| Log | Actual result |
| --- | --- |
| legacy-regressions-red.log | Six new regression methods failed, 17 assertions/errors, including the swap uniqueness error. |
| legacy-initial-tests.log | Six reproduced defects passed after consolidation; 57 tests ran with one old replacement-cardinality expectation failing. |
| legacy-boundaries-red.log | 19 tests, two assertions failing in the newly added partial-gap test; rollback, mixed roots, scope and full-result compatibility passed. |
| legacy-envelope-red.log | Three timestamp/gap tests failed, five assertions, before the envelope corrections. |
| legacy-compile.log | Swift throwing-operator compile error; no tests ran. Corrected by performing pending-state lookup before boolean combination. |
| legacy-corrected-tests.log | 66 convergence, legacy lifecycle and historical migration tests passed. |
| legacy-full-tests.log | Frozen c253f999: 359 tests, 358 passed, one native opt-in skip, zero failures; 29.468 seconds, ended 05:13:17 UTC, exit 0. |
| legacy-clean-tests.log | Frozen 9c16bd2d: 359 tests, 358 passed, one native opt-in skip, zero failures; 27.931 seconds, ended 05:17:14 UTC, exit 0. |

The updated replacement oracle asserts both object deltas (-50 and +75) and net +25, not merely an event count. Rollback is injected after observation, after present objects, after missing objects and before finalization. Tests check current state, observation/event/snapshot/binding rollback, successful retry, active-generation identity/token preservation and reopen/replay.

git diff --check initially found one trailing space in the extracted helper call. The c253-to-9c16 source delta removes exactly that space; the final check passes and canonical source matches the new frozen hash. The full suite was rerun in a fresh disposable copy for the exact final source, not inferred from formatting equivalence.

The schema-valid c253 read-only review returned no distinct actionable finding in the consolidation/envelope delta. Its 4,041-character result is within the 6,000-character budget. It remains raw/pending/ineligible under the former claim guard and snapshot. The schema-valid 9c16 refresh confirms exactly the one-space correction and unchanged tests under the renewed guard. The coordinator matched its identity, guard, hash, scope, budgets and evidence, and combined that narrow review with independent exact-candidate full-suite execution. Raw helper results remain pending/ineligible as whole-task acceptance artifacts; neither review proves TASK-521 completion. One coordinator and one read-only helper used two of four slots, with no nested delegation.

## Remaining work

- Finish the interval-contract review; point observations do not establish exact filesystem creation/write times. In particular, inspect the internal change-event lower bound when no previous object observation exists, and add multi-alias sample/rename-bound checks. These are open questions, not newly reproduced failures or accepted semantics.
- Coordinate ordinary FSEvents dirty-signal routing with TASK-522; this core-only change does not prove end-to-end app integration.
- Complete TASK-521 acceptance and brownfield assurance. Scale/resource, API/service, setup, recovery and overnight gates remain required for the overall goal.

TASK-521 remains working and unverified. No installed app/user evidence/client config changes, signing, commit, push, install or release were performed.

## Canonical progress record

Runtime progress event EVENT-20260917T052039008833Z-C36BA7AA records this increment at PLAN-DISK-STEWARD-005 R5 G38, retaining working/unverified/at-risk state. Project validation passed; history doctor reports a valid ledger with 11 records, six chronicles, zero commit bindings and no pending transaction. No chronology or provenance was rewritten. Current task guard after the progress transition: GUARD-TASK-DF3C078CCDB9D39E4D2718BCC19B95FB; lease expires 07:15:10 UTC.
