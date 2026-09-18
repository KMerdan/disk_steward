# One-time brownfield transition compatibility

The user directed: “finish tasks by following pyramid workflow and stop asking for approval.” The existing repository was incorrectly initialized with greenfield metadata. Installed Pyramid 3.7.1 overrides explicit `new-intent --mode brownfield` with that inherited metadata, and `upgrade` returns up-to-date without changing mode. `assess` correctly refuses greenfield projects.

To retain, rather than bypass, brownfield safeguards, the coordinator copied the 2.2 MB runtime to `/private/tmp/disk-steward-pyramid-runtime.RRD14Q` and applied the adjacent narrow patch. The installed plugin was not changed. Explicit mode is now passed through the existing hash-bound preview/archive/reset interfaces. Switching away from existing brownfield assurance is refused. No canonical state or history is hand-edited, and no audit/schema/ownership check is disabled.

Disposable test project: `/private/tmp/disk-steward-transition-check.AlScGt`, copied from completed PLAN-004 graph 34. Its transition generated PLAN-005 graph 1 in brownfield mode and a restorable PLAN-004 archive. The unmodified installed runtime successfully validated it and reported a valid 11-record, 6-chronicle history chain, with no errors or pending transaction. Assurance correctly remains blocked on incomplete baseline, missing impacts, rollback and monitoring controls. An explicit downgrade preview exits 2 with “A new intent cannot discard existing brownfield assurance”.

The compatibility runtime is needed only for this transition. All subsequent `take`, `assess`, `impact`, `update`, `audit`, and history operations use the installed runtime. Record the real transition's hash and approval provenance separately; disposable test approval is not product approval.

The source candidate retains all seven reliability requirements and cumulative gates. Already implemented patches are starting evidence, not automatically passed nodes. The final gate still requires 100k/1M scale checks, real-time overnight stability and migration/rollback evidence. Early gates require their own scoped evidence; they do not depend circularly on future overnight work.
