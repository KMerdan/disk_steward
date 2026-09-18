# TASK-521: directory-pass repair in progress

17 September 2026. This is an intermediate progress record, **not** an implementation-completion report, acceptance audit, release, or migration approval.

Later continuation and current candidate: see `root-path-progress.md`. The red results below remain historical reproduction evidence, not the current test status.

## Identity and scope

- Plan: PLAN-DISK-STEWARD-005 R5 G33 when work began; task claim belongs to `codex`.
- Task guard: `GUARD-TASK-3ED6D927EF9784D42284DD07C7A9561A`.
- Unchanged base product snapshot: `/private/tmp/disk-steward-523-accepted.8oZqwJ`, SHA-256 `e408ff149419ace16c04932147f8f635852ed011c8a8182d9126e27cf36220e8`.
- Intermediate product candidate: `/private/tmp/disk-steward-521-pass-candidate.DHnXpb`, SHA-256 `7f728d0e9bbb7de7588545b7f7a941905d7d198d8fa66c30fec99487e4310f5e`.
- Hash recipe, run from each root: `rg --files --no-ignore -0 Package.swift Sources Tests Config Scripts DiskSteward.xcodeproj Integrations Schemas Fixtures Resources Extensions | sort -z | xargs -0 shasum -a 256 | shasum -a 256`.
- Product/test files changed by this portion: `Sources/DiskStewardCore/Monitoring/DirectoryMetadataScanner.swift`, `Sources/DiskStewardCore/EvidenceStore/EvidenceStore.swift`, `Tests/DiskStewardCoreTests/Monitoring/ConvergentScanGenerationTests.swift`, `Tests/DiskStewardCoreTests/EvidenceStore/EvidenceStoreTests.swift`.
- Assets: ASSET-SCANNER, ASSET-STORE, ASSET-CONTRACTS. All edits remain in the task's declared scope. Earlier dirty worktree changes and historical Pyramid archives are preserved.

These changes remain one scan-publication correctness boundary. The separate TASK-531 traversal/publication performance redesign is not being substituted or claimed complete.

## Reproduction and implementation

Seven new regression tests ran against the previous product with only the test additions in `/private/tmp/disk-steward-521-red.8RtyH2`. All seven failed: 21 assertion failures, zero unexpected errors. See `provenance-red.log`.

The four directory/progress failures were:

1. Delete the only file after its final batch is staged, before the generation publishes.
2. Delete a file in a completed nested directory while another directory is still being scanned.
3. Interrupt publication at `before-finalize`, delete A/create B, reopen, then resume.
4. Resume an old lexical cursor after B with no directory signature; A is skipped.

The candidate now retains completed directory passes in SQLite schema 7, keyed by generation and physical directory. Each pass contains its signature and start/end observation interval. The store rechecks at most `min(512, maximumEntries)` proofs per call after traversal, retaining only that bounded batch in Swift. Changed-directory staging and descendant proofs are invalidated and affected completed roots are requeued. Empty-directory proof output also consumes slice budget. Directory signatures are checked after child metadata sampling, not only after name enumeration.

An in-process validation cursor is deliberately not trusted across reopen. Legacy unpublished progress without the provenance version and SQL-active/progress-completed records left by interrupted publication are abandoned without altering committed evidence. Compatible active traversals retain their staged work. All schema guards and shadow validation now target schema 7; genuine old-schema fixture coverage remains pending below.

Overlapping roots exposed a candidate defect: the same physical directory's newest proof could be attributed to a different configured root. The failing test is retained in `pass-boundaries-before-overlap-correction.log`. Proof eligibility now uses completed covering roots rather than treating the emitting root as exclusive ownership. The final intermediate candidate passes that test.

This is still an interval observation, not an atomic filesystem snapshot. The patch does not claim that a filesystem cannot change after an individual validation check.

## Verification actually run

Final intermediate candidate command (working directory above):

```sh
env -u DISK_STEWARD_NATIVE_CLIENT_TESTS -u DISK_STEWARD_PACKAGED_HELPER -u DISK_STEWARD_GATE_EVIDENCE -u DISK_STEWARD_CAPTURE_DIR swift test --disable-sandbox
```

Result at 03:38:15 UTC: **326 tests; 322 passed, 1 skipped, 3 failed (16 assertions), zero unexpected errors; 26.418 seconds.** Exit status 1. See `pass-candidate-full-tests.log`.

The three failing tests are intentionally visible and still require product fixes:

- `testHealthyHardLinkDoesNotCloseBindingInFailedRoot`
- `testMissingHealthyHardLinkDoesNotDeleteObjectWithFailedRootBinding`
- `testReplacingHealthyHardLinkDoesNotDeleteObjectWithFailedRootBinding`

Each exercises both choices of the canonical prior path and restoration of the unavailable root. The prior suite plus eight new directory/progress tests pass. The 2,500-file bounded-inline-result test now uses actual isolated files and the real scanner/proof path, rather than fabricating completed staging without membership proof. `git diff --check` passed.

Earlier compilation detected a Swift actor-isolation capture of the validation cursor. Capturing its value before entering the SQLite closure corrected that build error; the final result above is a fresh full build, not a reused earlier success.

## Preflight reconciliation and remaining work

HELPER-TASK-521-PREFLIGHT reviewed the immutable base without writes or test execution. The coordinator read the cited scanner/store branches, then independently reproduced the cursor, interrupted-publication and all three hard-link cases. Its five findings were reconciled as follows:

1. Missing legacy pass provenance: candidate repair and payload compatibility tests added; completed legacy database migration coverage remains incomplete.
2. Weak historical migration fixtures: confirmed. Existing tests relabel a current schema as version 5 and must not be represented as genuine v5/v6 migration coverage. Add fixtures generated from the actual old schemas, including 513 staged rows, null-column backfill, committed truth, interruption checkpoints and low-capacity refusal.
3. Per-path failed-root absence: reproduced; all three corresponding tests remain red.
4. Same-path replacement of an object with other links: reproduced for an unavailable root. Also add both object-ID iteration orders with a surviving healthy link before accepting the fix.
5. Publication-time versus sample-time provenance: source-confirmed, not yet repaired. Propagate sample/pass times into object lifecycle, bindings and change bounds; distinguish detection/publication time. Never invent a precise time for unverifiable legacy staging.

Before TASK-521 completion, finish the mixed-root/path reconciliation, timestamp chain, genuine migration/recovery fixtures, overlapping-root mutation/failure cases, candidate review and full regression verification. Do not mark AC-TASK-521-01 passed from the directory-only result. Resource-scale, service, query/export, onboarding and overnight gates remain unchanged.

No installed app was opened/replaced, no live evidence or client configuration was accessed, and no user files were deleted. Test cleanup removed only test-owned temporary fixtures. No commit, push, signing, installation or release was performed.

## Review rejection and current continuation point

The intermediate candidate above was **not accepted**. `helper-pass-candidate.json` and the schema-valid, 4,292-character `helper-pass-candidate-result.json` bind its independent read-only review. One coordinator and one helper occupied two of four slots; no nested delegation occurred. The result remains raw/pending/ineligible, and is not final evidence for the later hash below.

Coordinator reconciliation:

- A new empty pass from an overlapping root can replace a completed proof while retaining staged files from the older pass. The new `testFreshOverlappingPassCannotInheritSupersededMembership` reproduced this on the intermediate product. It is still red and is a load-bearing reason not to accept the patch.
- A failed ancestor can erase a successful descendant root's shared-path observation because staging records only the last root writer. This is source-confirmed; the exact failure-sequence regression remains to be added. Blanket subtree invalidation at every fresh cursor would not safely solve both overlap cases. Bind staged membership to its producing pass and preserve successful root contributions independently.
- Transient proof rows accumulated after successful scans. The new repeated-generation test observed 13, 26, ... 130 retained rows across ten scans. Publication now deletes proofs in the same transaction as staging, including the already-published cleanup branch. The regression now passes, with zero retained transient proofs after every completed generation. `pass-review-red.log` preserves both reproduced review failures before this correction.
- The same-process validation window needs a matching test and honest temporal semantics. A mutable filesystem is not an atomic snapshot. The contract must expose original sample/proven intervals, and observed dirty coverage must not be stamped as newly verified at publication. This remains part of the timestamp/provenance work, not a waived guarantee.

Current frozen continuation candidate: `/private/tmp/disk-steward-521-pass-followup.NV5QSI`, SHA-256 `5fcce93f690eed1f9ecbd2f243328f8a37e1e9e6a82da636dc0002a7278f5120`. Canonical product/test hash matched this copy. It differs from the reviewed candidate by the two new review regressions and atomic proof cleanup.

Fresh full-suite execution using the same isolated command completed at **03:45:09 UTC**: **328 tests; 323 passed, 1 skipped, 4 failed (17 assertions), zero unexpected errors; 26.031 seconds, exit 1**. The four failures are the three hard-link tests listed above plus `testFreshOverlappingPassCannotInheritSupersededMembership`. `pass-followup-full-tests.log` is authoritative for this hash. No unexpected existing-suite regression was observed; this does not establish complete correctness.

TASK-521 remains owned, working, unverified and at risk while these correctness failures are repaired. No implementation result or passing acceptance/audit was submitted. Next work must address pass-bound/root-safe staged membership and per-path absence/replacement, then timestamps and genuine schema compatibility before freezing a new acceptance candidate. The goal and full remaining Pyramid scope are unchanged.
