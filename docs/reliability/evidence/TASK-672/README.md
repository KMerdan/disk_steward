# TASK-672: task impact from sessions and dirty sets

Candidate input `0298de379e3dcdd03515a952a50a9e268ea9a447956e3409e381a40fe641d843` (on main after `5ce87fc`). Nothing has been
installed or published.

## Change

Before this task, the shipping (retired-scanner) build could not answer
`get_task_impact` at all:
- for a session registered during the current run it returned
  `detail_unavailable`, because impact still read the retired per-file
  store;
- after any relaunch every session returned `session_unavailable`, because
  sessions were kept only in memory.

The steward file's `sessions` and `session_impacts` tables (CONTRACT-602)
existed, but nothing wrote them.

- **Sessions are kept in the steward file**
  (`Sources/DiskStewardCore/Sessions/SessionImpact.swift`, `SessionStore`).
  - When it is written: on register, heartbeat and end.
  - What a row holds: one row per session ID and start, with the client,
    the workspace roots and the time it ended or its lease ends.
  - IDs longer than the 64-byte column are stored as a hash; the catalog
    still accepts 256 bytes.
  - Roots are stored as JSON within the 1 KiB column. Roots that do not fit
    are dropped whole, and the answer says so.
  - The store holds 500 sessions, oldest dropped first. The in-memory
    registry is now capped at 500 too: the oldest ended or expired sessions
    go first, and active ones stay.
- **Impact comes from the change journal's dirty sets.**
  `ChangeJournal.changes(from:through:relatedTo:limit:)` returns only rows
  related to the session's roots, so a busy volume cannot crowd them out.
  Each changed directory is related to a workspace root in one of three
  ways:
  - `at`: the root itself;
  - `inside`: within the workspace;
  - `contains-workspace`: an ancestor of the workspace. The journal
    collapses changes two levels below its watched root, so the change may
    lie outside the session's folders. It is labelled
    `coarser-than-workspace`.

  A row at a watched root itself (the journal's per-interval overflow
  collapse) contains every workspace. It is reported under `overflow`, not
  as the session's directory.
- **Shared, never exclusive.** Each directory states how many other
  sessions' workspaces and windows also cover it (`also_active_sessions`,
  `shared`). The answer says what the journal does not know: it records
  that a directory changed, not which process changed it.
- **Objects.** For directories at or inside the workspace, the review index
  gives the containing object or up to 3 objects under it. Up to 20
  `workspace_objects` are listed under the roots, with size, recreate class
  and when each was measured.
- **The answer outlives the journal.** When a session ends, and lazily on
  the first question about an ended session, its directories are kept in
  `session_impacts`, at most 200 per session. The journal keeps only 7
  days; after that, a kept impact answers with change counts but no
  intervals or gaps. `session_impacts` holds 10,000 rows, which is about
  the newest 50 sessions at the full 200 directories. A session leaving
  `sessions` takes its kept impact with it; the bounded store evicts each
  table separately, so `SessionStore` does this itself.
- **`get_task_impact`** on the retired build answers `task-impact-v2` with:
  - sessions (source `registered` or `kept`, state `lease-open` or
    `closed`);
  - directories, at most 200, with the total and `truncated`, sized under
    the 1 MiB ceiling;
  - overflow rows, journal gaps, the journal's coverage start, and
    coverage (`complete`, `partial` or `unknown`);
  - `confidence: inferred` (or `unknown` when nothing is known), the
    method, and limitations.

  Paths are basenames, or relative to the workspace root (`.`, `..`,
  `api/node_modules`); no absolute path is returned. The `.live` engine and
  its `task-impact-v1` answer are unchanged.
- **`list_active_agent_sessions`** keeps `active-agent-sessions-v1` and
  adds, per session, `changed_directories`: the total, the top 3 with
  relative paths, and the number of journal gaps.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 53 tests pass |
| `full-suite/` | `verify_candidate.py` on the same input: 719 tests, 0 failures, 11 skipped, candidate `passed`. Attempt 1 on the same input failed only the known `ObjectConvergenceTests` seed race in the retired scanner path (FIND-R4-OBJECT-CONVERGENCE-FLAKE); attempt 2 stopped on the supervisor's classification race (FIND-R4-SUPERVISOR-RACE); attempt 3 is the record |
| `absolute-relative-path-red/` | A path inside the workspace is returned absolute fails `TaskImpactJournalTests.testSharedOwnAndOverflowDirectoriesWithObjectsAndGaps` |
| `cap-not-enforced-red/` | More than 200 directories are returned fails `SessionImpactTests.testAtMost200DirectoriesWithTheTotalStated` |
| `contains-labelled-inside-red/` | A directory above the workspace is labelled inside it fails `SessionImpactTests.testOverlappingAndDisjointSessions`, `SessionImpactTests.testRelationsAtInsideAndAboveTheWorkspace`, `TaskImpactJournalTests.testActiveSessionsListTheirChangedDirectories`, `TaskImpactJournalTests.testSharedOwnAndOverflowDirectoriesWithObjectsAndGaps` |
| `gaps-dropped-red/` | Journal gaps are left out of the answer fails `TaskImpactJournalTests.testSharedOwnAndOverflowDirectoriesWithObjectsAndGaps` |
| `impact-not-cascaded-red/` | An evicted session's kept impact stays behind fails `SessionImpactTests.testTheOldestSessionLeavesWithItsImpact` |
| `journal-unfiltered-red/` | The journal returns rows unrelated to the session's roots fails `SessionImpactTests.testTheJournalReturnsOnlyRowsRelatedToTheRoots` |
| `kept-impact-unused-red/` | A kept impact is not used once the journal has forgotten fails `TaskImpactJournalTests.testASessionOutlivesARelaunchAndTheJournal` |
| `kept-session-not-read-red/` | A session kept in the steward file is not read after a relaunch fails `TaskImpactJournalTests.testASessionOutlivesARelaunchAndTheJournal` |
| `outside-root-attached-red/` | A directory outside every workspace is attached to the session fails `SessionImpactTests.testOverlappingAndDisjointSessions`, `SessionImpactTests.testRelationsAtInsideAndAboveTheWorkspace`, `TaskImpactJournalTests.testSharedOwnAndOverflowDirectoriesWithObjectsAndGaps` |
| `overflow-attached-red/` | A row at the watched root is attached as a session directory fails `SessionImpactTests.testOverlappingAndDisjointSessions`, `TaskImpactJournalTests.testSharedOwnAndOverflowDirectoriesWithObjectsAndGaps` |
| `registry-unbounded-red/` | The in-memory registry keeps every session fails `SessionImpactTests.testTheRegistryKeepsAtMost500SessionsInMemory` |
| `shared-as-exclusive-red/` | A directory another session also covers is reported as this session's alone fails `SessionImpactTests.testOverlappingAndDisjointSessions`, `TaskImpactJournalTests.testSharedOwnAndOverflowDirectoriesWithObjectsAndGaps` |

## Limitations

- **Correlation, not causation.** A directory in a session's answer
  changed inside, at or above its workspace during its window. The user or
  another tool may have changed it.
- **Coarse rows.** With a home-folder root, most rows collapse to project
  folders. A session whose workspace lies deeper sees `contains-workspace`
  rows that other sessions in the same project share.
- **Window boundaries.** The journal works in 5-minute intervals, so a
  window boundary includes its whole interval.
- **Kept impacts.** They are written only for windows the journal fully
  covers. They have no intervals or gaps, and the oldest sessions' kept
  impacts are evicted first.
- **The MCP catalogue is unchanged.** Neither tool takes `path_detail`, so
  every path is a basename or workspace-relative; TASK-671 rebuilds the
  catalogue.
