# TASK-521: sample time and dirty-evidence fence progress

17 September 2026. This continues `root-path-progress.md`. It is **not** task completion, an acceptance audit, an installed-database migration or release approval. Subsequent legacy-path work and evidence are recorded in `legacy-progress.md`; the unfinished-work list below is historical to this increment.

## Scope and candidate

- PLAN-DISK-STEWARD-005 R5 G35 during implementation; actor `codex`, task guard `GUARD-TASK-779C0B1C50E50BA52094C33F0D7F7453`.
- Assets: ASSET-SCANNER, ASSET-STORE, ASSET-CONTRACTS. No topology change or scope expansion.
- Frozen corrected candidate: `/private/tmp/disk-steward-521-dirty-candidate.s0tRrn`.
- Product/test SHA-256: `d902a53d01453c3d4f2656df8e9f42277e4f90d85fd2e791034b1cc859e1552b`; canonical product/test hash matches.
- Hash recipe: `rg --files --no-ignore -0 Package.swift Sources Tests Config Scripts DiskSteward.xcodeproj Integrations Schemas Fixtures Resources Extensions | sort -z | xargs -0 shasum -a 256 | shasum -a 256`.

This increment changes five product/test files:

1. `Sources/DiskStewardCore/Monitoring/DirectoryMetadataScanner.swift`
2. `Sources/DiskStewardCore/EvidenceStore/EvidenceStore.swift`
3. `Tests/DiskStewardCoreTests/Monitoring/ConvergentScanGenerationTests.swift`
4. `Tests/DiskStewardCoreTests/EvidenceStore/EvidenceStoreTests.swift`
5. `Tests/DiskStewardCoreTests/EvidenceStore/HistoricalMigrationTests.swift`

The whole TASK-521 inventory additionally includes `Tests/DiskStewardCoreTests/EvidenceStore/HistoricalEvidenceSchema.swift`, authored in the preceding increment. Earlier source changes, the PLAN-004 archive and projected-file changes remain preserved. New evidence comprises this report, six helper job/result files (`helper-legacy-preflight`, `helper-timestamp-candidate`, `helper-dirty-candidate` pairs) and the logs below; the older report now links here.

## Changes established

### Observed time is distinct from publication

Generation reconciliation now uses each positive metadata sample's time for current state, path opening, object observations and change evidence. Alias samples contribute minimum/maximum actual object-observation times while canonical metadata keeps its own sample time. Change detection stays at publication; occurrence upper bounds use the positive sample or qualifying absence evidence. A rename needs both positive destination evidence and old-path absence, whereas its separate size-change event keeps the metadata sample time.

Confirmed absence is dated by the closest completed covering directory pass, not the later end of the complete generation. If an entire parent disappeared, the closest retained ancestor pass supplies that membership bound. Multiple missing bindings combine their qualifying evidence before retiring the physical object. These remain inferred observation intervals, not exact filesystem operation times or an atomic snapshot. An unsignalled change after a directory was validated retains the original sample date; the next generation corrects that prior presence. Cleanup live revalidation is unchanged.

Schema 9 adds nullable `file_state_observations.observed_at`. Historical rows remain NULL because old run completion does not establish their sample time. Migration runs against actual v5/v6 layouts, including interruption/headroom checks; synthetic historical generation payloads explicitly omit the new token. This increment also adds `fsevent_hints.gap_recorded`, default false for historical rows, whose purpose and lifecycle are below. Schema 9 is an uncommitted, unreleased migration under development; no intermediate candidate database was installed or migrated into production.

### Dirty evidence fences in-flight work

A generation now carries a durable optional reconciliation token. New-generation tokens are preserved by every scanner/store copy. Tokenless old unpublished progress is not resumed. Receiving dirty evidence and resetting the intersecting roots is one SQLite transaction: affected staged rows/proofs are removed, independent-root staging is preserved, and the token rotates. Old in-flight slices return the durable reset cursor without publishing or clearing the new signal, regardless of equal/reordered wall-clock timestamps. The in-process validation cursor is keyed by generation plus token, and reopening still starts validation from the beginning.

Invalidation keeps the earliest coalesced gap start. Resolution uses the same intersection predicate as reset and requires all affected watched roots to complete; failed roots and unrelated dirty paths remain pending. Partial publication does not falsely close the global event-loss gap. An idempotent publication path no longer clears arbitrary newly pending invalidations.

FSEvents hint replay must not repeat the new reset side effect. `gap_recorded` durably records whether a hint's gap has already been applied, within the same transaction. A previously stored non-gap hint can still report its first gap. Identical gap-hint replay preserves progress and does not reopen a resolved gap. Hint-free loss signals have no replay identity and conservatively count as new receipts. Receipt state shares the hint's retention lifecycle; no separate growing receipt table was added.

## Executed checks and review reconciliation

Tests ran only in disposable copies with native-client and packaged-helper opt-ins unset:

```sh
env -u DISK_STEWARD_NATIVE_CLIENT_TESTS -u DISK_STEWARD_PACKAGED_HELPER -u DISK_STEWARD_GATE_EVIDENCE -u DISK_STEWARD_CAPTURE_DIR swift test --disable-sandbox
```

Development-copy scoped runs used `--scratch-path .timestamp-build --filter …`. The first copied build cache was non-portable; its failure is retained, and subsequent runs used a fresh cache. No failing run below is represented as a pass.

| Log | Observed result |
| --- | --- |
| `timestamp-cache-build.log` | Copied PCH/module-cache path failed to build; no tests ran. |
| `timestamp-regressions-red.log` | Two new timestamp tests failed, 13 assertions. |
| `timestamp-tests.log` | 45 timestamp/path/lifecycle tests passed. |
| `dirty-red.log` | Dirty-during-validation test failed in both reopen variants, six assertions; unsignalled interval case passed. |
| `dirty-compile.log` | Swift actor-isolation compile error; no tests ran. Corrected by keeping pending-state lookup transaction-local. |
| `dirty-tests.log` | 50 convergence/lifecycle/historical migration tests passed. |
| `timestamp-schema-tests.log` | 56 scoped tests passed, including nullable historical times and root-local equal-time fencing. |
| `timestamp-full-tests.log` | Superseded candidate `6e27519fc76b2cf66daaf30817374870ec0acd65bc9a0402a126e42aa207b6bc`: 345 tests, 344 passed, one opt-in skip, zero failures; 28.966 seconds, ended 04:45:57 UTC. |
| `dirty-review-red.log` | Both review findings independently reproduced: ancestor-resolution and gap-replay tests failed, four assertions. |
| `dirty-reviewed-tests.log` | All 63 scoped convergence/store/migration/durable-provenance tests passed after correction. |
| `dirty-full-tests.log` | Corrected frozen `d902a53…`: **347 tests, 346 passed, one opt-in skip, zero failures**, 27.735 seconds, ended **04:53:15 UTC**, exit 0. |

`git diff --check` passed. The eight new test methods also contain failed-root, removed-parent, restart and same-time variants; the count of methods is not the count of covered combinations.

One coordinator and one read-only helper used two of four slots; no nested delegation. All jobs are schema valid. The initial legacy preflight exceeded its result-size budget; it was replaced by the helper's schema-valid 5,270-character compact response within the 6,000-character limit. It remains advisory, not acceptance evidence. The coordinator read the legacy implementation independently and confirmed its separate partial-positive/gap/replay semantics. No legacy-source change has yet been made on that advice.

The timestamp candidate review returned two findings within budget. Both were independently reproduced in `dirty-review-red.log`, then repaired: matching ancestor/root resolution and replay-safe durable gap receipt state. That raw result remains bound to the superseded candidate and is not final validation. The final narrow correction review and its limitations are retained separately; full TASK-521 acceptance is still withheld.

The corrected-candidate review reports no distinct actionable defect in that narrow correction. The coordinator matched its job identity, guard, candidate hash, scope, budgets and references, and combined that source review with the independently executed 347-test run. Raw output remains pending/ineligible as a whole-task acceptance artifact. Its migration caveat is retained: the earlier intermediate, unreleased schema-9 candidate lacked `gap_recorded`. No such intermediate database was installed or adopted as retained user evidence; if that support assumption changes, add an explicit version/shape migration before opening it. The two immutable source snapshots remain available for review, not as interchangeable database formats.

## Remaining work and boundaries

1. Apply equivalent indexed path/replacement reconciliation to legacy `recordObservation`, retaining partial positive evidence, scope/gap/replay semantics, complete legacy result expectations and active-generation independence. Do not fabricate filesystem pass proofs for synthetic/legacy metadata. Add failing legacy matrix cases before changing the implementation, and preserve exact observation time when available.
2. Complete timestamp/dirty-evidence contract review, including tests for multi-alias/rename bounds and compatibility of the completed legacy path. Stored metadata scans are intervals, not exact writer/creation evidence.
3. Ordinary app FSEvents hints currently request another sample but only gap batches call `noteEventGap`. Core dirty-signal fencing is proven here; do not claim end-to-end ordinary-hint integration. Coordinate that routing with the subsequent app lifecycle work (TASK-522), respecting allowed write scope and impact coverage.
4. Review and test the exact completed TASK-521 candidate, then submit its implementation result and required assurance/audit evidence. Later scale/resource, service/API, onboarding, recovery and real overnight gates remain required. The small fixture results here do not waive them.

TASK-521 remains working, at-risk and unverified. No implementation-complete result, acceptance, release or installed-app claim is made. No installed application, user evidence, real client configuration or user file was modified; no commit, push, signing, installation or release occurred.
