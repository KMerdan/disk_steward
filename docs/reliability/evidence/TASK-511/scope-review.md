# TASK-511 isolation repair

The candidate prevents verification from inheriting live application dependencies. The scope is test/smoke isolation, not a claim that every monitoring or MCP defect is repaired.

## Evidence

- Both startup paths reproduced the foreign-export deletion in an explicitly injected disposable directory. The previous implementation also swept before a failing database open.
- The fixed backend uses database-relative staging and an exclusive private workspace per request. Cleanup checks the directory identity and no longer walks shared user temporary exports. Sibling/replaced workspace tests and overlapping exports pass.
- Smoke startup uses ephemeral settings/safety state, empty roots, paused detail sampling, no collector, no notifications and Agent Access off. Two actual subprocesses preserve fixture file bytes, file/socket/lease inodes, an exclusive lease and the endpoint response. The smoke directory is removed after shutdown.
- A support-directory override on non-smoke startup is now rejected before mutation, rather than being mistaken for complete isolation. Normal startup without this test override retains its original live dependencies and support location.
- Notifications and collectors are required constructor arguments. The standalone dashboard fallback explicitly selects inert dependencies. The compiler exposed that call site; PLAN-005 revision3 records its additional path without changing acceptance or graph dependencies.
- Verification artifact paths require a new leaf under an existing, current-user-only canonical temporary parent. Existing destinations are never replaced. Packaged helper overrides throw before execution on invalid paths. These are path/type guards, not authentication of executable contents.
- The actual release script's smoke gate is tested with valid, missing and unsafe fields. Signed artifact/notarization verification was not run or weakened.

Forty-one scoped tests passed on the content-hashed disposable candidate. Static independent candidate validation found no ordinary reproducible in-scope regression. The full test suite is not represented as run on this candidate. See verification.json and targeted-tests.log for the sequence, including failed harness attempts and their corrections.

## Remaining boundaries

Crash-orphan export recovery and bounded materialization remain TASK-551. Duplicate application, uncooperative endpoint, replacement and stale-owner edge tests remain TASK-512. Path/inode prechecks do not constitute an atomic sandbox against hostile same-user racing processes. Scale, real overnight, rollback and signed release acceptance remain outstanding.

## Assurance follow-through

The revision3 scope replan reset TASK-511 from working to planned and cleared its claim. The first completion submission correctly refused with `codex does not own TASK-511`; no implementation event was written. The coordinator reclaimed the ready task at graph11, retained the unchanged source, and refreshed candidate validation against the new guard. Future scope replans must check ownership as well as the guard before continuing.

Implementation completion is not audit completion. The current baseline maps broad modules to multiple findings; the runtime applies high-severity findings by asset overlap, so TASK-511's query/lifecycle/distribution impacts also encounter later query, service, scale and rollback findings. Do not mark those repaired from isolation tests or silently accept/downgrade them to pass an early gate. Preserve the pending audit and reconcile the assurance/dependency model explicitly before advancing OUTCOME-510. The first next independently ready task is TASK-512. The unrelated completed intent archives remain unchanged.
