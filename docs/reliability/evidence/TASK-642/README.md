# TASK-642: serve live capacity independent of the detail store

Candidate input `ab671524032b9641151d35f01872baf42c1dcdbd1294acf62599734c310b6ff1`
(main 345c072 with TASK-641, TASK-614 and TASK-642 uncommitted). Nothing is
committed or installed.

Process note: the code and the evidence below were produced before the task
was formally claimed. The claim was recorded afterwards, on 2026-10-04. No
other actor held the task.

## Change

- **`get_storage_summary`** (`AppEvidenceQueryBackend.storageSummary`)
  - It measures the volumes first. It then reads persisted state, the
    lifecycle summary and store diagnostics as three independent parts, which
    share a 3-second budget.
  - A failing or expired part becomes null. The response then carries
    `detail_status: unavailable` plus path-free `detail_reasons`, and the
    volumes are still returned.
  - Parts run in a cancellable child task. The store is opened off the
    backend actor inside that task, so a lock wait ends at the deadline (the
    store's busy handler checks for cancellation every 10 ms). Other requests
    are not blocked.
  - Freshness survives a refused summary. On a store like the user's, the
    helper self-check therefore reports the real age of the evidence instead
    of failing.
- **Backend construction.** The backend no longer requires the store at
  construction. It opens the store lazily and retries on every use, so a
  corrupt or unopenable store no longer prevents the Agent Access socket
  from starting. Other tools report the retryable `detail_unavailable` error.
- **Probe.** `PersistentMonitoringProbe.sample` degrades evidence-store
  failures to a capacity-only observation. That observation carries live
  volume figures and `detailUnavailableReason`, and the status line reads
  "File detail unavailable". Resource-breaker, concurrency and cancellation
  errors still propagate.
- **Launch.** If the store cannot be opened at launch, the app uses
  `CapacityOnlyMonitoringProbe` instead of a probe that only throws.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 90 tests, 0 failures, including `StorageSummaryDetailFaultTests` (five faults), `SelfCheckDetailFaultIncrementTests` (the real built helper's `--self-check` through a refused summary) and `CapacityOnlyObservationTests` |
| `coupled-summary-red/` | Detail failures propagate again: the fault matrix fails |
| `probe-fallback-red/` | Probe fallback removed: the capacity-only probe test fails |
| `unbounded-detail-red/` | Detail budget set to 600 s: the locked case exceeds the 10 s request deadline |

### Fault matrix (AC-TASK-642-01)

| Fault | Fixture | Result |
| --- | --- | --- |
| missing | fresh directory | live capacity; detail available; no persisted state |
| corrupt | 8 KB of garbage as `evidence.sqlite` | live capacity; detail unavailable (`detail_unavailable`); coverage `unavailable` |
| summary refused | 600 KB retention-run limitation, with one recorded observation | live capacity; detail unavailable ("lifecycle metadata exceeds the summary budget"); persisted state still reported |
| over cap | 11 MiB ballast under a 10 MiB policy | live capacity; detail available; `storage_admission` `retention-required` |
| locked | exclusive-mode writer holding the store before and during the read | live capacity; detail unavailable within the 3 s budget |

No reason contains a filesystem path.

### Self-check (AC-TASK-642-02)

The built `disk-witness-mcp --self-check` ran against a socket backed by a
refused-summary store. It reports `app: connected` with an evidence age.
`HelperSelfCheck.evaluate` judges the integration by that age (verified or
stale) and never fails it. The board receives capacity-only observations,
not sampling errors, when the store fails during sampling or cannot be
opened at launch.

## Limits

- **Construction on a locked store.** The backend's eager open is now
  `try?`, but it still waits on SQLite locks. This is pre-existing
  behaviour: the open threw after the same waits.
- **Other tools.** Detail tools other than `get_storage_summary` still use
  the actor-isolated store accessor. On a locked store they return the
  retryable deadline error rather than a partial answer.
- **Status line.** The new "File detail unavailable" line is covered through
  the observation it reads. No hosted controller test drives that
  transition. GATE-649 re-runs the sequential dashboard proof.
