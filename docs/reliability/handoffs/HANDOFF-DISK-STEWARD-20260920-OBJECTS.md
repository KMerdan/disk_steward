# Disk Steward handoff — 20 September 2026, object model

> Historical snapshot, superseded by [the R3 continuation note](HANDOFF-DISK-STEWARD-20260920-R3.md).
> The old "no verifier ... active" assertion below was disproved by an orphaned
> XCTest process. It has been stopped, but runner containment must be repaired
> under TASK-616 before further candidate execution. Retain this document as
> history, not current readiness or permission to run tests.

Development paused mid-plan. `PLAN-DISK-STEWARD-006` is **active** at revision 2,
graph 32, with no task claimed, so the runtime cannot issue a canonical handoff.
This follows the same contract by hand; the machine-readable copy sits beside it.

## Where things stand

| | |
| --- | --- |
| Plan | `PLAN-DISK-STEWARD-006`, rung 1 six of seven verified |
| Verified | RESEARCH-601, CONTRACT-601, TASK-611, TASK-612, TASK-613, TASK-615 |
| Ready | **TASK-614** (capacity guard), TASK-621 (rung 2 sizing) |
| Last full verifier | input `bb08ca1d7776`, 587 tests, 0 failures |
| Repository | commit `8dca762` on main, pushed, worktree clean |
| Installed app | still 1.2.1, still has the stuck scan. Nothing here is released. |

## What now works, in the repository

A build-output directory, a shared cache and a repository are each **one**
object. The scanner records an object and never enters it, so the work a scan
does no longer depends on what is inside one. The store keeps object rows under
schema 15 and can collapse the per-file rows an older version staged. The app
uses all of it: the probe scans with the classifier and converges an existing
store in bounded batches, saying what it collapsed.

The number that matters: a fixture of **1,080,000 entries behind 12 objects**
completes one generation in **0.7 seconds**. The installed app, on the same kind
of tree, had processed 17.4 million entries across 39 hours without publishing.

## Two things worth knowing before continuing

**A hang was found and fixed.** A non-absolute path made the ancestor walk
prepend `..` forever instead of reaching the root, which hung a test for 30
minutes. It was diagnosed from a stack sample of the stuck process, not guessed
at. The walk is now bounded and absolute-only, with a regression test and a
mutation that re-creates the hang. Those paths come from the store, so this was
reachable from real data.

**A gap in the plan was closed by replan R2.** Nothing owned wiring the object
model into the running app, so rung 1 could have passed while an installed
machine behaved exactly as before. TASK-615 now owns that and GATE-619
validation-requires it.

## What is left

1. **TASK-614**, the capacity guard: an impossible scope refuses once with the
   shortfall and the remedies instead of looping, and the default 512 MiB limit
   is justified against the object model's measured cost.
2. **GATE-619 and OUTCOME-610**: re-affirm the stale inspections, add the
   ASSET-BUILD and ASSET-RESOURCE inspections the gate needs, and converge a
   **captured copy of the installed store** end to end. Every proof so far uses
   stores built in tests or synthetic fixtures; the gate is where a real store
   must converge.
3. **Rung 2**: sizing and freshness, reclaim ranking, app and agent surfaces,
   then GATE-629 and OUTCOME-620.
4. **Rung 3**: shared caches behind opt-in, GATE-639, OUTCOME-630, intent audit,
   closure.

## Test harness

`docs/reliability/handoffs/harness/` holds the runner and the mutation specs
that produced every focused suite and every red in this plan. They lived in a
session scratchpad and were lost once to a `/private/tmp` cleanup, so they are
kept with the evidence now. **Never run `swift test` in the worktree**: every run
goes through an isolated snapshot, and each result records
`repositoryUnchanged`, which must be `true`.

## First action when work resumes

Read `CONTEXT.md` and the object contract, then:

```sh
python3 /Users/merdankiji/localGit/pyramid-task/plugins/pyramid-task/scripts/pyramid.py \
  inspect --project . --ready --json
```

and take TASK-614.

## Running resources

Disk Steward 1.2.1 is installed and running. Its evidence database is live and
must never be opened by a test or a measurement; use a captured copy. No
verifier, scale or soak run is active, and this session's scale fixtures were
removed.
