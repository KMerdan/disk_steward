# TASK-552 — public API matrix and shared pagination budget

18 September 2026 JST. Partial AC-TASK-552-01 evidence, not full task or gate acceptance.

## Resolution addendum — 18 September 2026 JST

Both review findings below are closed by runtime evidence in `linked-session.md`: the unified cursor envelope passes the branch-transition regression on input `c37b843ddc2793d8169d837e6ce776cf4f62036666120df12f85537150fed8f0` (`api-matrix-branch-green/`), and a linked-session `get_provenance` fixture proves basename/hashed withholding and full-detail preservation, with a disposable mutation run showing the test fails when the projection is broken (`linked-session-green/`, `linked-session-mutation-red/`). The corrected candidate `f85e397066ed35742cf1a6ade57c4346a42671660ee48f5bb7bd387ec0bc0b8f` passed the full isolated verifier (`linked-session-candidate-green/`). The addendum below is retained as history.

## Handoff addendum — superseded candidate

The 497-test candidate below is no longer the current worktree. `api-matrix-review-result.json` records two subsequent findings: incompatible provenance cursor formats across raw/object-backed branch changes, and missing linked-session coverage in the provenance privacy test.

The cursor finding was independently reproduced against frozen candidate `223d3eb9adcbd3c966981869e3b3013e7f6e652be7f2714ac5c7ab9f68644052` with only the new test overlaid. `api-matrix-branch-red/` preserves one test/four failures: both branch transitions returned retryable `request_failed` instead of nonretryable `cursor_expired`. Reproduction input: `682f4bc70975183781c84061a59c11db16e566a1528b72239abae46aac58d1c2`. Process 21023 finished with exit 1; no rerun is active.

The worktree now uses one provenance cursor envelope and checks revision before selecting its query branch. The new regression exercises both transitions. **Neither this source correction nor the new regression has been run against the corrected worktree.** Current input `c37b843ddc2793d8169d837e6ce776cf4f62036666120df12f85537150fed8f0` and its two unverified file deltas are preserved in `handoff-current-source-manifest.json` and `handoff-unverified-source/`.

The second review finding is still open: add a retained event claim linked to the session, page to that event, require a nonempty sessions array, and verify basename/hashed withholding plus full-detail preservation through `get_provenance` itself. The existing full export check does not prove that path.

Raw helper schema, identity, old task guard, snapshot and result budgets matched the issued job. Both source and guard have since changed, so it is advisory, not current validation. The expired claim was reclaimed solely to record the user-requested transfer handoff; no task completion or audit was declared.

## Reproductions and changes

The populated three-file fixture exercises the ten published tools and both resource URIs through an isolated Unix socket. Tools with `path_detail` are queried in basename and hashed modes. Session-bearing responses are seeded with unstructured context containing both a workspace path and an unrelated private path. The test verifies that the session was retained, rather than treating absent data as redaction. Cursors are opaque and their continuations are also checked.

- `api-matrix-initial-red/`, input `7bec65a72290d7da3f829c7408c1231499ee96e5768c05535339942951213db4`: two failures reproduce `get_provenance(limit: 1)` returning two items, current state plus event. This run did not demonstrate the session leak and is not counted as its reproduction.
- `api-matrix-session-red/`, input `ba6e4497c8dca3c78017edd340ba72094f1e4fe7ca037889f8b646004f0bac8f`: strengthened populated-session assertions reproduce the free-text disclosure in active sessions, the compatibility writers alias, task impact and basename export, alongside the row-budget failure (11 assertions total).
- `api-matrix-focused-green/`, intermediate input `85b7dab882664fa8cd3f45431bd7ecea47d41c6c30b7cab159de30fae1559e20`: 35 focused tests pass. Later freshness/error assertions are not covered by this intermediate hash.
- `api-matrix-green/`, input `223d3eb9adcbd3c966981869e3b3013e7f6e652be7f2714ac5c7ab9f68644052`: full isolated verifier, six stages pass; 497 Swift tests (4 opt-in skips), no failures; 20 Python verifier tests. Sentinel preserved. Exact five-file delta and copies are in `api-matrix-source-manifest.json` and `api-matrix-source/`, relative to the prior lifecycle coverage checkpoint.

Provenance pagination now shares one item budget across current-state rows and historical events. A revision-pinned two-phase cursor advances through states once, then history; no concatenation beyond the requested limit and no discarded phase. The store reads each page in one read transaction. Tests at limits 1, 2, 3, 4 and 6 reconstruct all six selected items exactly once, maintain matched count and current-state timestamp, and reject an old cursor after a new event with nonretryable `cursor_expired` over IPC. The opaque public cursor envelope and tool names remain unchanged; internally encoded provenance cursors are not a persisted public format.

Free-text task context can mention paths outside a registered root and cannot truthfully inherit basename/hashed privacy by merely shaping structured roots. Redacted projections return `task_context: null` plus `task_context_withheld: true` when text exists. Full-detail provenance/export preserves the context with a false marker. The test checks full-detail exported session text explicitly. Structured session executable/workspace fields in provenance now follow its selected detail mode.

## Limits of this evidence

This matrix covers real IPC, useful populated fixtures, selected row limits, cursor continuation/revision failure, session-context privacy and a 256 KiB fixture response ceiling. It does not establish all-field redaction or pre-materialization admission at arbitrary data sizes. It does not replace end-to-end MCP stdio protocol checks already present elsewhere, nor prove that those checks cover every new case.

Still required for AC-TASK-552-01: immediately effective scope/exclusion and policy changes; arbitrary diagnostic/identifier text privacy; stale/missing cases across all endpoints; bounded session/claim/gap expansion and SQL work; full response-budget/error boundary matrix. Provenance retains its existing 100-identity search bound; honest truncation beyond that limit needs inspection. Active-session enumeration and offset cursor revisions also need review. AC-TASK-552-02 requires remaining occurrence/export composition and representative-cardinality query evidence.

No real files were scanned outside synthetic watched directories, no live evidence or client configuration was opened, and no installed app was replaced. No audit or release readiness is claimed.
