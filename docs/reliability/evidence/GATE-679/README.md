# GATE-679: audit rung 4, agents on the review

**Candidate 1.5.0 (12)**, the same candidate and installation as GATE-669.
- Verified input:
  `03e80c743d0ce97b1e6c5dd49d0b0670fc4cf6452d49efd421fb60815490947b`.
- Installed locally, not notarized and not published.

## How the proof is split

The acceptance criterion names both isolated snapshots and a
user-equivalent packaged app, so each claim is proven where it can be done
without harming the user's data:
- **At caps and under detail faults:** in the candidate's isolated runs,
  with the built helper. The caps fixture must never be written into the
  user's live `steward.sqlite`.
- **Packaged helper on the installed app's real store:** every tool,
  `measure_path` on localGit, the agent scenario against the window, the
  export, and task impact for a fixture session.

## Isolated (candidate input)

| Claim | Evidence |
| --- | --- |
| Every tool answers at caps under 1 MiB with the detail store unavailable, through the real helper | `ReviewCatalogIncrementTests.testEveryToolAnswersUnderTheCeilingAtCapsThroughTheRealHelper` in every candidate run. Every table is at its cap and the per-file store is a corrupt file. The largest answer is a full 2,000-item report page, 225 KB ([`../TASK-671/catalog-caps-sizes.json`](../TASK-671/catalog-caps-sizes.json)) |
| An agent quotes the window | `testAnAgentQuotesTheReviewWindowsNumbersAndStates` in every candidate run ([`../TASK-671/agent-vs-window.json`](../TASK-671/agent-vs-window.json)) |
| `measure_path` scope, budget and join | `ReviewToolsTests` in every candidate run |
| Task impact rules | `TaskImpactJournalTests` and `SessionImpactTests` in every candidate run |

## Installed (packaged helper, real store)

[`installed-1.5.0/transcript.json`](installed-1.5.0/transcript.json), [`summary.json`](installed-1.5.0/summary.json):

- **The ten-tool catalogue** is listed, and every tool answers. Both
  resources answer.
- **`measure_path` on `~/localGit`** stopped within its budget: `partial`,
  stop reason `entries`, 500,013 entries in 14.4 s. The answer is a lower
  bound of 32.6 GB. A small folder measured completely (130 entries).
  `/private/etc` was refused with `outside_scope`.
- **The agent scenario.** `list_review_items` for localGit answers the same
  report as the stored review the window shows: `complete-with-items`,
  2,000 items, 62,680,481,792 bytes worth reviewing, reviewed
  2026-10-04T20:10:34Z. `get_review_item_evidence` answers for the first
  item. The live window on the installed app shows the same: "62.68 GB worth reviewing in 2,000 items · reviewed Oct 5, 2026 at 5:10" (05:10 JST is 20:10Z), in the user's screenshot [`window-localgit-summary.png`](installed-1.5.0/window-localgit-summary.png).
- **The export round-trips.** `export_evidence` (`evidence-export-v2`) for a
  two-hour window carries the same answers as the direct tools at the same
  moment:
  - the capacity change (+19.9 GB), the journal coverage start, and all 33
    changed folders with their counts, equal to `explain_growth`;
  - the localGit report and its top 25 items, equal to `list_review_items`;
  - the growth attribution.

  The legacy part says `too_large`, with the file-export route.
- **Task impact** ([`installed-1.5.0/task-impact-probe.jsonl`](installed-1.5.0/task-impact-probe.jsonl)):
  - A session was registered with `Scripts/Integration/session` for a
    fixture folder under `~/Downloads`, a watched root, and files were
    written there.
  - `get_task_impact` returns the folder itself (`.`, `at`, 17 changes) and
    its parent (`..`, `contains-workspace`, coarser than the workspace).
    The row at the watched root is reported apart.
  - Coverage is `complete`, confidence `inferred`, and no absolute paths
    are returned.
  - `list_active_agent_sessions` shows the same folders.
  - The session was ended and the fixture removed.

## Limitations

- **The caps proof runs isolated.** It runs on the candidate input with
  the debug-built helper, not against the installed app's store.
- **The first scripted session registration did not register.** The
  script mis-read the wrapped registration answer and never ended the
  session it meant to start, so the scripted impact call answered
  `session_unavailable`. A second registration through the same script,
  run directly, worked and is the recorded proof.
- **This Claude session still runs the old helper.** Its MCP connection
  started the 1.4.0 helper before the install. Every gate call went
  through the installed 1.5.0 helper started fresh.
