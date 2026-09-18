# Nullable provenance checkpoint

Accepted checkpoint input: `9e4fb6a0d145f12d33250d1af0bf9e75f68a1a2e07a2241ecae50705987ca875` (17 September 2026). PLAN-DISK-STEWARD-005 R9, TASK-552. Neither full acceptance criterion is complete. No release, installation, signing, commit or push is implied.

## Reproduction and correction

`nullable-red/` reproduces missing-bound substitution and false discovery-time task attribution: two tests, eleven failed assertions, build successful. A measured event's publication time was also discarded. New inputs and claims now default to authoritative event timing, retain unknown lower bounds, and require a known complete interval before workspace/time attribution. Privileged operation evidence remains a separate path; this patch does not manufacture writer notifications.

Claims retain optional lower bounds through persistence, reopen, presentation, real IPC and decoded export. Schema 12 replaces the provenance table's mandatory lower bound with a nullable one, retaining original historical payload bytes, original lower dates in `legacy_occurred_start`, and supersession links. Legacy payloads expose an unknown lower bound and `legacy-unverified` basis. Copying supersession does not relabel them. Legacy claims remain in history but are excluded from current export attribution and direct task-attribution lookup. Genuine v5/v6 fixtures verify payload preservation and foreign-key integrity.

Public schemas are deliberately versioned: `provenance-claim-v3`, `provenance-chain-v3`, and `provenance-presentation-v3`. Old v2 schemas remain. A v2 presentation decoder upgrades to explicitly unverified v3 rather than emitting an invalid nullable v2 record. Window queries include unknown starts as possible overlaps, not exact occurrences. The chain advertises `window_semantics: possible-overlap`. Existing row caps and cancellation checks remain; this checkpoint is not a scale or allocation-budget proof.

## Review found a regression

The initial candidate `26f68d8082e34e9edcca0738a649db796927469bc386c4ef0e67b4d6f9ce1e0c` passed 471 tests but changed current-export claim precedence from detection time to occurrence-end time. Both coordinator inspection and HELPER-TASK-552-NULLABLE-01 identified it. `nullable-ordering-red/` reproduces an older claim replacing a newer one in decoded export. The corrected query restores detection-time/claim-ID precedence. Initial green evidence is superseded, not acceptance evidence.

HELPER-TASK-552-NULLABLE-02 reviewed the corrected immutable candidate and reported no concrete defect in that narrow delta. The coordinator reconciled the job/result identity, guard, snapshot and budgets. The earlier whole-patch review and this delta compose only for this patch; both are static review, not independent runtime validation or whole-task approval.

## Verified evidence

- `nullable-corrected-green/candidate.json` binds all six successful isolated verifier stages and logs to the corrected input hash.
- 20 Python harness tests; 472 Swift tests, four intentional opt-in skips, zero failures.
- The sentinel and required historical migration checks passed. New cases cover missing/measured timing, false workspace attribution, nullable persistence/reopen, earlier-window inclusion, later-window exclusion, legacy payload bytes and supersession, presentation compatibility, real-IPC basename/hashed serialization, and decoded-export claim precedence.
- `nullable-source-manifest.json` and `nullable-source/` preserve the twelve changed inputs relative to the preceding measured-event checkpoint. No product inputs were deleted.

## Exact continuation and limitations

1. `AppEvidenceQueryBackend.taskImpact` still feeds `TaskImpactCorrelationEngine` point-in-time `CorrelationObservation`s. Correct that path using the actual interval, without silently attributing unknown first sightings. Reproduce through isolated real IPC. Its range selection and aggregation also need a coordinated possible-overlap versus observed-window contract.
2. Complete public compact projections, effective roots/exclusions/policy, private query/revision-bound cursors, pre-materialization row/byte budgets, typed errors and explicit freshness. Exercise all ten tools and two resources, not just the two covered here.
3. Prove bounded overlap behavior under representative cardinality and query/response budgets; the existing 25,000/100,000 related-row caps are not sufficient allocation/performance proof.
4. The preview-v10 timing test removes v11 flags from a current synthetic store. After schema12 it retains an unrelated newer provenance-table shape. Reconstruct that unrelated table from frozen pre-v12 DDL before claiming full preview-v10 migration coverage. Genuine released v5/v6 claim migration coverage is independent and passed.
5. Keep final resource/scale, overnight, rollback and packaged-app gates open. No live database, watched roots, installed app or real agent configuration was touched.
