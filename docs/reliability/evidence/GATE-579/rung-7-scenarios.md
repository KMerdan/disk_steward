# GATE-579 — Regression-assured repair candidate (rung 7, final)

Actor: `claude`. Independent exercise of the integrated final candidate for OUTCOME-570 on top of every earlier verified rung. Nothing was committed, installed, signed, released or published to Homebrew; every run is an isolated snapshot under `/private/tmp`.

## Exact candidate

`docs/reliability/evidence/TASK-562/candidate-2/candidate.json`: source input `5ecd49a317171e493451894bcc082cd8d4516d2922c29564107baace9d21dd68`. Stages: harness ok, toolchain ok, manifest ok, entitlements ok, build ok, tests ok, package-generator ok, package-toolchain ok, package-system-temporary ok, package-project ok, package-build ok, package-architecture-app ok, package-architecture-helper ok, package-smoke ok, package-helper ok. 547 tests, 5 opt-in skips, 0 failures; `sentinelPreserved: True`; packaged unsigned app, architecture, smoke and bundled-helper stages passed. Git revision `cf313e4527a3bd30dae217d2c1ff68d7a7a87b60` with a dirty worktree (the candidate is uncommitted by design).

`docs/reliability/evidence/audits/scoped-all-rungs-final-green/tests.log`: every rung's scoped suites in one isolated snapshot on the same input: 423 tests across 60 suites, 0 failures, 1 opt-in skip.

## Final acceptance evidence (AC-GATE-579-01, revision 17)

- **Scale matrix**: 100k wide on the final candidate in 27.8 s, one enumeration pass, no restarts (`docs/reliability/evidence/GATE-539/scale-runs/wide-100k/`); 100k wide/fanout and 1M wide from TASK-531 (`docs/reliability/evidence/TASK-531/scale-runs/`); 100k under the storage cap from TASK-532.
- **Migration and rollback rehearsal**: `docs/reliability/evidence/TASK-572/rollback-rehearsal.md` (baseline schema 6 ↔ candidate schema 14, interruption at every checkpoint, old binary refuses the newer schema, negative oracle fails); FIND-ROLLBACK resolved.
- **Real-time soak evidence (≥ 1 h)**: `docs/reliability/evidence/TASK-572/soak-runs/soak-3h/` — 112 min, 321 cycles, status `external-stop`, peak RSS 456 MiB, family 113 MiB, 9 descriptors, 0 forced evictions, 0 mismatches, 16 retention runs; `soak-final-candidate/` — 43 min, 123 cycles on the exact final input, peak RSS 420 MiB, 0 mismatches. Real wall-clock throughout; no accelerated clocks. An overnight run is not a release requirement (R13, owner direction: long-run behaviour on real machines comes from user feedback and crash reports).
- **Earlier rungs inherited**: rung notes 1–6 (`GATE-519/rung-1-scenarios.md` … `GATE-569/rung-6-scenarios.md`), all audited on this candidate or on candidates whose product sources it contains.
- **Isolated CI workflow (TASK-571)**: `docs/reliability/evidence/TASK-571/inspection-20260918/` — pinned actionlint passes, 20 harness tests, runbook matches the workflow.

## Findings

All material findings resolved: FIND-ISOLATION, FIND-SCALE, FIND-SERVICE, FIND-ENDPOINT-ORDER, FIND-EXPORT, FIND-QUERY, FIND-ROLLBACK, FIND-OCCURRENCE, FIND-OVERNIGHT. Medium findings FIND-ATTRIBUTION and FIND-DISTRIBUTION-DOC remain open and documented; neither is material to this rung's claim.

## Limitations

- Fixture endpoint adapter only; no native EndpointSecurity activation or entitlement; native client profiles opt-in.
- Fake-clock lifecycle proofs for sleep/wake; unsigned disposable-copy packaging; host macOS 15.6.1 arm64.
- Multi-day behaviour on real machines is deliberately left to post-release feedback; the CI workflow is the regression proof.
