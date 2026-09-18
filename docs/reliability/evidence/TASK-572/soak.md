# TASK-572 — Real-time soak, scale matrix and rollback rehearsal on the candidate

Actor: `claude` (TASK-572 taken at G104, guard `GUARD-TASK-3B1F5628CC25040B74616A2584DE75EA`). Product files added by this task: `Scripts/Testing/supervise_soak.py` (external supervisor: fixture ownership token, RSS and database-family stop thresholds, bounded capture, samples, stop file), `Tests/PerformanceTests/SoakBenchmarkTests.testOptInProductionSoak` (opt-in, env-driven production soak: churn, exports, retention, per-cycle published-state reconciliation against the fixture tree) and `Scripts/Testing/rehearse_migration_rollback.py` (migration/rollback rehearsal, see `rollback-rehearsal.md`). Hashes in `soak-source-manifest.json`; final candidate input `5ecd49a317171e493451894bcc082cd8d4516d2922c29564107baace9d21dd68`. Nothing was committed, installed, signed, released or published to Homebrew.

## Real-time soak, 112 minutes (`soak-runs/soak-3h/`)

Release test bundle built from the product sources of candidate 019559cf (identical product sources to the final candidate; only test fixtures differ), 20 000-file fixture in 16 buckets, churn 200 per cycle, exports every 10 cycles, retention every 20, 15 s pause, 512 MiB storage cap, 600 MiB RSS stop threshold. Status `external-stop`, supervisor exit 0, 321 cycles in 6724 s.

| measure | peak / total |
|---|---|
| in-process RSS | 456 MiB (supervisor process-group peak 524 MiB) |
| CPU | 52 % peak |
| open descriptors | 9 |
| database family (db+wal+shm) | 113 MiB, WAL 16 MiB |
| committed evidence bytes | 86 MiB |
| exports on disk | 16 MiB (33 exports, 0 typed budget refusals) |
| durable frontier rows | 0 |
| max cycle / publication / query / export / retention seconds | 21.6 / 6.8 / 1.3 / 12.1 / 0.0 |
| mutations | 200 created, 200 modified, 200 deleted per the last cycle's totals |
| published-state mismatches | 0 (mutation mismatches 0) |
| forced evictions | 0; last admission `available`; detail coverage `complete` |

Budgets: RSS stayed under the 600 MiB stop threshold and the database family under the 4 GiB stop threshold; every cycle reconciled the published current state with the fixture tree (0 mismatches). Typed `budgetExceeded` refusals from bounded task-impact/export queries are product behaviour and are counted, never failures. `soak.log` holds every cycle row, `soak-samples.jsonl` the one-second supervisor samples, `result.json` the test's final record and `soak-supervision.json` the supervisor's record.

## Scale matrix

- 100k wide on the final candidate `5ecd49a31717…` (`docs/reliability/evidence/GATE-539/scale-runs/wide-100k/`): 100000 entries in 27.8 s, one enumeration pass, 0 restarts, peak in-process RSS 56 MiB, sampled family 605 MiB (WAL 286 MiB) with the 512 MiB cap in force, status `completed`.
- 100k wide/fanout and 1M wide from TASK-531 (`docs/reliability/evidence/TASK-531/scale-runs/`) and 100k wide under the cap from TASK-532 (`docs/reliability/evidence/TASK-532/scale-runs/wide-100k/`).

## Migration rollback rehearsal

`rollback-rehearsal.md` / `rollback-rehearsal/report.json`: baseline binary (git HEAD, schema 6) writes a synthetic store; the candidate migrates it, interrupted at every exposed checkpoint and recovered; the baseline binary refuses the newer schema on a scratch copy; the restored backup opens with the baseline and migrates forward again; negative oracle fails as required. FIND-ROLLBACK resolved (INSPECT-TASK-572-ROLLBACK).

## Run on the exact final candidate (`soak-runs/soak-final-candidate/`)

Release bundle built from the final input `5ecd49a31717…` at `/private/tmp/disk-steward-final-frontier`, same parameters, stopped by external stop after 123 cycles (43 min): status `external-stop`, 0 mismatches, peak RSS 420 MiB, family 111 MiB, 9 descriptors, 0 forced evictions. Under the R13 criterion (owner direction, `docs/reliability/planning/replan-r13-review.json`) an overnight run is not a release requirement; FIND-OVERNIGHT is resolved by these runs and the scale matrix.

## Not performed

Installed-app release, signing/notarization and Homebrew publication remain unperformed; no real user data or client configuration was touched.
