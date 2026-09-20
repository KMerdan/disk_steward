# Disk Steward continuation — 20 September 2026, replan R3

This is a plan-level continuation note, not a paused-task lease. No task is
claimed or paused. Inspect canonical readiness before starting work.

## Canonical position

- Plan: `PLAN-DISK-STEWARD-006`, active, revision 3, graph 34.
- Context: `CTX-94D76E7CA6CC14FBF11BA98A8DFBF72A`.
- Six verified tasks retained: RESEARCH-601, CONTRACT-601, TASK-611, TASK-612,
  TASK-613, TASK-615. No increment gate has passed.
- Only ready task: **TASK-616 — Contain verification descendants and enforce
  resource budgets**. No code execution or safety fix was performed by this replan.
- Installed app remains 1.2.1. No signing, installation or release is included.

## Why the order changed

An old isolated XCTest survived its runner's 300-second timeout for over 51
minutes and reached an 86.9G reported footprint. The user authorized stopping
that exact PID, and exit was confirmed. The bounded ancestor-walk fix is
already in current source, but its old snapshot process did not receive it.
Process-group killing alone has not established descendant containment.

The user also reported a +5.6 GB notification while the board remained at
+2.1 MB. Source review identified non-observing child views, a separate capacity
cache, a refresh action that does not sample, and discarded negative changes.
The exact redraw failure still needs a hosted sequential-update reproduction.
An older alert and the latest interval are legitimately different measurements.

See [retained diagnosis](../evidence/REPLAN-006-R3/incident-and-dashboard.md).
Do not read the old handoff's clean-process statement as current evidence.

## Execution and acceptance sequence

1. **TASK-616 first.** Bootstrap with small synthetic processes under an
   independent watchdog, finite deadlines, allocation/process ceilings and
   unrelated-process sentinels. Establish owned-descendant tracking, aggregate
   memory/time/output limits, termination escalation and verified exit. Cover
   all runner entry points or refuse unsupported launches. Only then use a
   bounded real Swift/XCTest smoke. Do not reproduce multi-GB pressure.
2. **TASK-617 next by priority.** Prove updates on the visibly rendered board
   across successive observations; unify capacity and signed selected-volume
   changes, make refresh request bounded single-flight sampling, show baseline
   and interval, distinguish volume/detail freshness and preserve one latest
   growth alert per app session. Use fake notifications and isolated fixtures.
3. **TASK-614** completes the capacity guard; **TASK-621** object sizing also
   becomes eligible once TASK-616 is verified. These do not consume the
   dashboard repair, so no artificial dependency serializes them behind it.
   Shared-file conflicts still require coordination.
4. **GATE-619** must verify TASK-616, TASK-617 and TASK-614 alongside the original
   object/scan and captured-real-store migration scenarios. Refresh stale
   inspections and resolve both material findings with current evidence.
5. Rung 2 remains sizing/ranking/object presentation (TASK-621/622/623);
   TASK-623 explicitly inherits TASK-617. Rung 3 remains opt-in shared caches.
   GATE-629 and GATE-639 repeat containment and dashboard proofs on their exact
   integrated candidates. The final intent and non-goals are unchanged.

## Assurance obligations

- `FIND-R3-ORPHANED-TEST`: critical, open, owned by TASK-616.
- `FIND-R3-DASHBOARD`: high, open, owned by TASK-617.
- New impact records are hypotheses. Confirm actual changed assets during
  implementation; do not mistake a planned inspection for a test pass.
- Monitoring control is missing pending external runner containment and
  coherent live presentation. Historical synthetic rollback evidence remains
  scoped to its original rehearsal; captured-store gate obligations remain.
- Existing five stale inspections are not silently re-affirmed by this replan.
- No live user database access, production notification, app restart,
  installation, deletion or broad process-name kill is allowed by these tasks.

## Durable records

- Candidate/review/assurance: `docs/reliability/planning/plan-006-r3-*.json`.
- Replan event: `EVENT-20260920T070319830816Z-C9F98AB0` (graph 33).
- Impact event: `EVENT-20260920T070514724750Z-FBF58AE6` (graph 34).
- Earlier accepted contracts and historical test reports are preserved.
- Planning documents were updated locally; no commit or push was requested.

Use Pyramid inspect/validate, then take TASK-616 through the runtime. Do not
edit canonical `.pyramid` state or generated task Markdown by hand.
