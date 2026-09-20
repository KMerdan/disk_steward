# Disk Steward handoff — 20 September 2026

Development is paused here. `PLAN-DISK-STEWARD-005` is **completed** (revision 17,
graph 175, closed 2026-09-18T07:32:26Z) with no owned task, so the runtime cannot
issue a canonical handoff record. This file follows the same contract by hand; the
machine-readable copy is `HANDOFF-DISK-STEWARD-20260920.json`.

## Where things stand

| | |
| --- | --- |
| Plan | `PLAN-DISK-STEWARD-005`, all 32 nodes verified, no claims, no ready work |
| Final report | `.pyramid/reports/FINAL-PLAN-DISK-STEWARD-005-R17-G175.md` |
| Change dossier | `.pyramid/dossiers/DOSSIER-PLAN-DISK-STEWARD-005-R17-G175.md` |
| Released | 1.2.0 (build 5) and 1.2.1 (build 6), both notarized and on the Homebrew tap |
| Installed | 1.2.1, running, Gatekeeper accepted, Agent Access working |
| Worktree | clean and pushed at `0d2da8a`; tap at `de40f13` |

## What happened after the plan closed

Both releases were made **outside** Pyramid. The closed plan's evidence does not
cover them, and must not be presented as if it does. Each carries its own tests,
isolated verifier run and record in `CONTEXT.md`.

- **1.2.0** shipped the reliability repairs plus a fix for the About window, which
  had shown a hard-coded `0.1.0`.
- **1.2.1** fixed two upgrade regressions reported from the installed app: Agent
  Access refused the socket 1.1.x left behind, and the circuit breaker stopped
  monitoring because the in-sample database check counted reusable free space and
  the write-ahead log against the size limit.

## Decisions a later session should not re-litigate

- **No overnight soak gate.** Replan R13 replaced it with bounded real-time soak
  evidence plus the scale matrix and rollback rehearsal, at the owner's direction:
  long-run behaviour comes from user feedback after release. See
  `docs/reliability/planning/replan-r13-review.json`.
- **Notarize through Xcode's upload route**, not `notarytool` credentials. The
  Apple ID app-specific password fails with HTTP 401; the Xcode route needs no
  stored credential and Apple accepted both releases in about two minutes.
- **Post-closure work gets a new intent**, never a reopen of the closed plan.

## Open observations, not proven defects

1. **The live store has no complete scan since 13 September.** The generation that
   started 2026-09-18T11:01Z was still active on 2026-09-20T02:09Z, reporting
   16,805,758 processed entries for roughly 100,000 files, 1,568 directories
   pending, and retention has now forced one eviction. Monitoring itself is healthy
   and bounded; what is unexplained is how much re-enumeration happens before a
   generation completes. Start at the directory cursor and stream-registry restart
   handling, and at the retention pressure path.
2. **`FIND-ATTRIBUTION` and `FIND-DISTRIBUTION-DOC`** remain open medium findings
   inside the closed plan. Both are documented and neither was material to its gates.
3. **Verifier evidence for the 1.2.x releases is gone.** Those directories lived
   under `/private/tmp` and were deleted during cleanup. The archived evidence in
   `docs/reliability/evidence` and the release hashes in `CONTEXT.md` remain.

## First action when work resumes

Read `CONTEXT.md`, then confirm the plan state before planning anything:

```sh
python3 /Users/merdankiji/localGit/pyramid-task/plugins/pyramid-task/scripts/pyramid.py \
  lifecycle --project . --json
```

For a new release, follow the repeatable workflow in `CONTEXT.md`: bump the build
number, verify in isolation, archive, upload, poll `xcodebuild -exportNotarizedApp`,
then publish. For new development, start a new intent with `pyramid-task:new-intent`.

## Running resources

Disk Steward 1.2.1 is installed and running with Agent Access on. Its evidence
database is live: never point tests or the normal app at it. No verifier, soak or
scale run is active, and all Disk Steward scratch under `/private/tmp` was removed.
