# TASK-521: root/pass ownership, path reconciliation and historical migration progress

Continued by [sample time and dirty-evidence fence progress](timestamp-progress.md). The results and remaining-work list below describe the earlier candidate and are retained as history.

17 September 2026. This supplements `pass-progress.md`; its earlier red results remain historical evidence. This is **not** a task-completion report, acceptance audit, release or installed-database migration approval.

## Scope and identity

- Plan: PLAN-DISK-STEWARD-005 R5 G34 during implementation. Owner: `codex`; task guard `GUARD-TASK-8D6F2C95AF59DB49E61F216EE1A9094B`.
- Assets: ASSET-SCANNER, ASSET-STORE, ASSET-CONTRACTS. No topology change or drift outside the task scope.
- Current frozen candidate: `/private/tmp/disk-steward-521-binding-candidate.Xgo6wc`; SHA-256 `94a31ee73f4cc102ef01b874946e33527d0f1cc041c079807907d401ec7764c5`. Canonical product/test hash matches.
- Hash recipe: `rg --files --no-ignore -0 Package.swift Sources Tests Config Scripts DiskSteward.xcodeproj Integrations Schemas Fixtures Resources Extensions | sort -z | xargs -0 shasum -a 256 | shasum -a 256`.

Product/test files changed by TASK-521 so far:

1. `Sources/DiskStewardCore/Monitoring/DirectoryMetadataScanner.swift`
2. `Sources/DiskStewardCore/EvidenceStore/EvidenceStore.swift`
3. `Tests/DiskStewardCoreTests/Monitoring/ConvergentScanGenerationTests.swift`
4. `Tests/DiskStewardCoreTests/EvidenceStore/EvidenceStoreTests.swift`
5. `Tests/DiskStewardCoreTests/EvidenceStore/HistoricalEvidenceSchema.swift`
6. `Tests/DiskStewardCoreTests/EvidenceStore/HistoricalMigrationTests.swift`

All other source changes in the dirty worktree belong to earlier work and were preserved, as were the PLAN-004 archive and projected-file changes. Evidence added here consists of this report, the four `helper-{root-path,object-accounting}-candidate{,-result}.json` files, and the logs listed below. Previous TASK-521 evidence remains part of the eventual implementation-result inventory.

## Repairs and their reasoning

### Membership belongs to a root and a producing pass

Schema 8 stages each `(generation, root, path)` contribution independently, with its immediate directory, pass ID and sample time. Completed directory passes are keyed by `(generation, root, directory)`. A fresh completed pass replaces only its own superseded membership. Failed-root cleanup cannot erase another root's successful contribution. Invalidation and bounded validation preserve root ownership, and every staged contribution must join its own producing pass before publication deduplicates physical paths.

Unpublished progress now requires provenance version 2. Older active/payload-completed staging is abandoned when a fresh generation begins; committed current evidence is not rewritten or relabeled as fresh. Successful publication still atomically reclaims transient staging and proof rows.

The previously red overlapping-pass mutation case now passes. A new deterministic regression also establishes the formerly source-only failed-ancestor case: the nested root stages A first, the ancestor stages A second, and a later depth-limit failure in the ancestor must leave the nested contribution intact.

### Physical objects and path bindings have separate lifecycles

Publication reads comparisons from indexed SQLite temporary snapshots of prior current state and open bindings, rebuilding current state inside the same transaction. This removes object-iteration ordering and unique-path collisions during swaps; it does not introduce file-count-sized Swift collections. Admission reserves additional prior-state work. Large-scale cost and transaction restructuring still belong to TASK-531 and are not established by these small fixtures.

Each prior path is closed only on positive replacement evidence, confirmed covered absence with unchanged scope, or explicit scope exit. An unavailable included binding remains open. A wholly unobserved object with such a binding remains unknown and non-actionable, rebased to that uncertain path if its former canonical path was removed or replaced. A healthy observed alias remains present without retiring the unavailable alias.

Replacement byte accounting is per physical object, not per incoming/outgoing path pair. An incoming replacement event adds the new object's logical/allocated bytes; each fully retired old object has one negative replacement event, bound to that old object with `path_after = NULL`. A surviving or unknown old object has no retirement event. Thus one-to-many and many-to-one replacements neither multiply nor omit debits. This intentionally permits multiple inferred replacement records for a multi-object transition; their sum describes physical byte change, not a count of exact filesystem operations.

A move and size change can produce distinct rename and modify/truncate events while inserting one state-observation row. Hard-link canonical-path rebasing is not asserted to be a rename. Incoming replacement provenance explicitly identifies the replaced binding path, rather than borrowing the old object's surviving canonical alias.

### Migration proof uses actual old layouts

`HistoricalEvidenceSchema.swift` contains frozen DDL from `b94bf56` (schema 5) and `8918e30` (schema 6 additions). The five predecessor DDL blocks were compared and match. These fixtures do not instantiate the current migrator or merely change `user_version`.

New tests cover v5's three-column staging and v6's ten-column staging with all new backfill columns null, 513 rows spanning the 512-row backfill boundary, absent pass/sample fields, active traversal, completed-root progress and SQL-active/payload-completed progress. They assert committed file/history preservation, no invented sample time, foreign-key integrity, abandonment of unproven staging and idempotent reopen of new-format active progress.

Both schemas are tested at all four migration interruption checkpoints and on insufficient disk headroom. The older three migration tests now use the real schema-5 DDL too; the former current-schema-with-v5-label fixture is removed.

## Tests and independent review actually performed

All commands run in disposable copies, with native-client and packaged-helper opt-ins unset:

```sh
env -u DISK_STEWARD_NATIVE_CLIENT_TESTS -u DISK_STEWARD_PACKAGED_HELPER -u DISK_STEWARD_GATE_EVIDENCE -u DISK_STEWARD_CAPTURE_DIR swift test --disable-sandbox
```

Scoped commands use `--filter` as recorded in their logs. The progression is deliberately preserved:

- `membership-tests.log`: 39 scoped tests, three failed hard-link tests/16 assertions; the old overlapping-membership failure was fixed.
- `membership-review-tests.log`: the new failed-ancestor and surviving-link cases passed; path swapping reproduced a unique-path constraint error.
- `path-reconciliation-tests.log`: all 42 scoped tests passed after immutable-prior/path-aware reconciliation.
- `replacement-accounting-red.log`: strengthened accounting assertions failed in two tests/six assertions before the first accounting correction.
- `root-path-full-tests.log`: candidate `858eab3db676e1275a7b2501b35d9efee78e583165bdd312da11c54ec6a828d0` ran 331 tests, 330 passed/one opt-in skip/no failures, 27.900 seconds, ending 04:08:19 UTC.
- `historical-migration-tests.log`: all three actual-schema migration tests passed across their schema/progress/checkpoint matrix, 0.603 seconds.
- `replacement-review-red.log`: all five review-derived cardinality, overwrite-by-move, move-plus-growth and surviving-link-plus-growth tests reproduced failures (eight assertions).
- `object-accounting-tests.log`: all 50 scoped tests passed after object-level accounting and genuine-fixture changes, 3.174 seconds.
- `object-accounting-full-tests.log`: candidate `433ee44009001437b325841585165d78a29d812eeee5701dc3bec29b8d9447b7` ran 339 tests, 338 passed/one opt-in skip/no failures, 29.819 seconds, ending 04:18:53 UTC.
- `binding-path-red.log`: the final review finding reproduced in the canonical/noncanonical, both-object-orders test (two assertions) before its binding-path correction.
- `binding-full-tests.log`: current candidate `94a31ee73f4cc102ef01b874946e33527d0f1cc041c079807907d401ec7764c5` ran **339 tests, 338 passed/one opt-in skip/no failures**, 27.671 seconds, ending **04:23:10 UTC**, exit 0. This includes both binding-path assertions and all historical-schema tests. `git diff --check` passed, and the canonical product/test hash matched this frozen candidate.

One coordinator and one read-only helper occupied two of four slots; no nested delegation. Both review jobs/results are schema valid and within their budgets. The root/path review's three accounting findings were independently reproduced, then repaired and tested. The subsequent accounting review found the noncanonical binding-path error; the coordinator independently reproduced it and checked the explicit-path correction. Raw helper results remain pending/ineligible and bound to superseded snapshots; they are not promoted as final task validation. No helper tested or wrote source, opened production state, or mutated Pyramid.

## Still required before TASK-521 completion

1. Propagate actual sample/absence-pass intervals through file-object lifecycle, path bindings, event observation times and change bounds, distinguishing detection/publication time. Current records have sample time but other tables still use publication time.
2. Add the same-process counterpart to bounded-pass revalidation after mutation, including known dirty/invalidation evidence received during a generation. Preserve explicit interval semantics rather than claiming an atomic filesystem snapshot; do not resolve newly observed dirty coverage with old proof.
3. Apply equivalent path/replacement safeguards to the older `recordObservation` route, which still has separate reconciliation logic. Inspect production callers and prove compatibility rather than declaring it irrelevant from the generation-only tests.
4. Final candidate review and exact-hash regression verification covering the completed task contract. Continue later lifecycle, resource/scale, MCP/export, onboarding and overnight gates; none is waived by these tests.

TASK-521 remains working and unverified. No implementation result, audit pass or release claim is submitted. No installed application, production evidence, real client configuration or user file was touched. No commit, push, signing, installation or release occurred.
