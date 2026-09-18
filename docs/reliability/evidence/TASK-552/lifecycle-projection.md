# TASK-552 — bounded public lifecycle projection

Checkpoint: 18 September 2026 JST. Parent PLAN-DISK-STEWARD-005 R10 G82, task guard `GUARD-TASK-B8E1C2F9F0B506B7FC5D3E59FF469274`. This is partial implementation evidence, not task completion or gate approval.

## Change and evidence chain

The public lifecycle, storage and growth endpoints previously loaded the private traversal checkpoint through `lifecycleStatus`. The new `lifecycleSummary` reads a bounded scalar projection in a read transaction. Schema 13 adds derived generation counters; existing progress blobs are neither decoded nor backfilled during this migration. Historical unknown counters stay null. Counter updates share the generation transaction and deletion cascades with generation ownership. The public read does not refresh or mutate user export inventory.

Metadata row/byte preflight rejects oversized summaries before Swift string/JSON materialization. It is not yet a demonstrated SQL-work bound at production cardinality. The internal scanner's private progress loading is unchanged and remains part of the broader resource work.

1. `lifecycle-projection-fixture-error/`: initial regression had an invalid export fixture (available without creating); retained as an unsuccessful test attempt.
2. `lifecycle-projection-red/`: corrected fixture reproduces false complete coverage on an empty store, export inventory mutation during a read, and private-checkpoint decode dependence.
3. `lifecycle-projection-compile-errors/`: three unsuccessful Swift actor-isolation attempts, followed by a private actor-isolated transactional read method. These are not successful verification.
4. `lifecycle-projection-focused-green/`: 31 focused tests, no failures. Subsequent formatting/schema changes mean this is historical, not the final candidate.
5. `lifecycle-projection-green/`: candidate `b1ea72b2fdfa9f501daea648376874c16f5ebf9f7e3eef5960e358385f21c155`, 494 Swift tests (4 skipped), no failures; 20 verifier tests. Review then found a coverage regression despite that green suite.
6. `lifecycle-projection-review-{job,result}.json`: static review identified that `explain_growth` lost synthetic active-scan gaps when switching to the new scalar summary. Raw helper identity/schema/guard/snapshot/budgets were validated; the superseded snapshot remains advisory and ineligible as final evidence.
7. `lifecycle-projection-coverage-red/`: coordinator independently reproduced the finding over real IPC: 3 tests, 1 failure; an overlapping active generation reported complete instead of partial. Input `b6f28f382df580d4c72b3ce019b20ac8a0dea6ea8f3b2a4cc795e69eb89e2179`.
8. `lifecycle-projection-coverage-focused-green/`: scalar active-start merge repairs the open-ended overlap without loading progress. Four IPC tests pass, including a populated disjoint historical interval, equality at the overlap boundary, and a window after scan start.
9. `lifecycle-projection-coverage-green/`: corrected candidate `81170d0e5d8a4d102a4ecc7e0558e40d94a4a0ad73014ec0b2ec570832b2a4c7`; all six verifier stages passed. 495 Swift tests, 4 skipped, 0 failures; 20 Python harness tests. The production-sentinel fixture was preserved. No real app/database/client configuration was used.
10. `lifecycle-projection-coverage-review-{job,result}.json`: narrow static rereview found the original coverage finding resolved, with no new delta finding. It did not run tests and is not independent runtime validation. Coordinator validated job identity, guard, exact candidate, schema and result budgets. Raw pending/ineligible status is preserved.

The nine product-file deltas versus prior timing checkpoint `74bd38987ebb54a77a7dd87a683d6339523607a0386f6cf4038c3216f1d00d92` are archived in `lifecycle-projection-coverage-source/`, with hashes in `lifecycle-projection-coverage-source-manifest.json`. At checkpoint acceptance, current files, immutable test snapshot and archived copies matched.

## Verification boundaries

The tests cover invalid private progress as an access sentinel, pre-decode refusal, no inventory mutation, empty lifecycle coverage, generation counter write rollback/pruning, unknown historical counters, schema-12-shape forward interruption recovery, and WAL read-snapshot semantics. They do not establish recovery from corrupt scanner progress or old-binary rollback.

AC-TASK-552-01 remains incomplete: all-tool/resource privacy, current policy/exclusion changes, revision-bound cursors, missing/stale evidence and pre-materialization budgets require broader integration proof. AC-TASK-552-02 still needs representative-cardinality query work and complete composition evidence. Scale, native-client, packaged-app, overnight and rollback gates remain unverified; no material finding or assurance gate is closed by this checkpoint. No install, signing, commit, push or release occurred.
