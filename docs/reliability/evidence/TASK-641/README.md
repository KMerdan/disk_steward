# TASK-641: window every lifecycle-summary reader

Candidate input `5b4e533d00fffa93eaf08148fe2da6fb1bce55a4f45e9c60c7b59e4875b60a8b`
(main 345c072 plus uncommitted changes). Nothing is committed or installed.

## Change

- **Retention gaps.** These are ported from `hotfix/lifecycle-gaps-1.2.4`
  (worktree evidence `docs/reliability/evidence/HOTFIX-1.2.4/`, input
  19a921db). The status lists the newest 128 gaps and carries
  `retention_gap_count`. The pre-decode budget measures only that window.
  `get_evidence_lifecycle` adds a limitation when the list is truncated.
- **Observation (coverage) gaps.** These use the same window
  (`observationGapProjectionLimit` = 128), plus `observation_gap_count`.
  Coverage verdicts no longer come from the listed array:
  - `open_observation_gap_count` counts every open gap, plus the active
    generation's incomplete roots, for lifecycle and storage-summary
    coverage.
  - `lifecycleSummary(_:at:gapWindow:)` answers, in the same read snapshot,
    whether any gap overlaps the requested `explain_growth` window.
  - A truncated list therefore cannot turn into a "complete" claim.
- **Unchanged.** No rows are deleted and the schema is unchanged.
  Retention-gap rows stay bounded by the 1,500-run cap through
  `ON DELETE CASCADE`. Coverage gaps are listed newest-first with a
  `gap_id` tie-break, so the validator and the reader measure the same
  window.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 89 tests, 0 failures. Covers lifecycle projection (core + IPC), EvidenceStore, MCP read model, status board, volume presentation, helper verification, export, IPC and query suites |
| `gap-budget-red/` (`mut-whole-table-gap-budget.json`) | Whole-table coverage-gap budget restored. Both open-gap tests fail with `budgetExceeded` / `query_budget_exceeded` |
| `prefix-verdict-red/` (`mut-prefix-coverage-verdict.json`) | Verdicts judged from the listed prefix. Lifecycle coverage and growth coverage for the old window are wrong; the IPC test fails at both assertions |
| `retention-budget-red/` (`mut-whole-table-retention-budget.json`) | 1.2.3 retention budget restored. Both forced-eviction tests fail with the user-visible refusal |

All runs used snapshots outside the repository (`repositoryUnchanged:
true`) after `bootstrap_supervision.py` passed on main the same day
(`../REPLAN-006-R4/bootstrap-main.log`).

## Acceptance

- **AC-TASK-641-01.** Checked at the live store's shape: 1,500 forced-eviction
  gaps, and 601 coverage gaps with one old open gap behind 600 newer ones,
  then all 601 open. `get_storage_summary`, `get_evidence_lifecycle` and
  `explain_growth` answer. Each list is newest-first within 128, carries its
  total, and adds a limitation when truncated. One oversized listed retention
  gap still refuses before decode.
- **AC-TASK-641-02.** No deletion path was added. Retention-gap growth stays
  bounded by the existing run cap.

## Limits

- Other tools still read `coverageGaps()` unbounded for their coverage
  verdicts: `list_current_consumers`, `find_cleanup_candidates`,
  `get_provenance` and `get_task_impact`. They do not use the summary
  budget, so they cannot lock out, but their memory grows with open gaps.
  TASK-671 replaces those tools.
