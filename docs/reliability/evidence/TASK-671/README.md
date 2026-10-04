# TASK-671: agent tools on the review report

Candidate input `03fef5873c78802ad54c51d1d9bce3aedabef6aa3c37ccf5ec76e6c4bf6bbffe` (on main after `0e7c272`, replan R8). Nothing has
been installed or published.

## Change

The MCP catalogue is rebuilt on the capacity ring, the change journal and
the review report. It lists ten tools, all read-only, idempotent and
non-destructive:

| Tool | Answer |
| --- | --- |
| `get_storage_summary` | Kept: live capacity, the comfort reserve and the history from the ring. |
| `get_health` | New, replaces `get_evidence_lifecycle`: the steward and capacity file sizes against the 32 MiB ceiling, each table's rows with its row and byte caps, the latest review of each scope (state, coverage, total), a running review, the journal's coverage and gaps, growth attribution, kept sessions and legacy evidence sets. The `disk-steward://status` resource returns it on the retired build. |
| `explain_growth` | Kept, with TASK-661's measured attribution. |
| `list_review_items` | New, replaces `find_cleanup_candidates`: the latest review of a scope (a configured folder, or `caches`; the newest review when none is named), ranked and paged, with the report state, item count and worth-reviewing total, each item's size, evidence state, recreate class, origin, rebuild command and the owning tool's cleanup command. |
| `get_review_item_evidence` | New: one item's reasons it may be disposable, reasons to keep it, its commands, whether its size is a lower bound, and a live check. |
| `list_largest_objects` | New, replaces `list_current_consumers`: the object index, largest first, optionally under one scope, with each object's last measurement. |
| `measure_path` | New (invariant 7): one folder inside the configured scopes or opted-in caches, at most 15 s and 500,000 entries. See below. |
| `list_active_agent_sessions` | Kept (TASK-672). The `list_active_writers` alias is dropped. |
| `get_task_impact` | Kept (TASK-672). |
| `export_evidence` | Kept, re-pointed (`evidence-export-v2`). It returns the steward evidence for the window: capacity change, changed folders and gaps, up to 5 reviews with their top 25 items, growth attributions and sessions. It adds the legacy evidence read-only from a clone when it fits the answer (`included`), and otherwise says `too_large` with the file-export route, or `none`. |

### Rules behind the new tools

- **One source with the window.** The window's stored-item logic (evidence
  state, reasons to keep, lower bound), the report state and the
  worth-reviewing total now live in Core
  (`Sources/DiskStewardCore/Review/ReviewPresentation.swift`). The window
  and the tools both call it, so an agent quotes the window's numbers by
  construction, and a test proves it.
- **`measure_path`** goes through `ReviewService` as the one walk in flight.
  - If a review is running, the measurement joins it: it waits within its
    own budget, reports `joined_review`, and then measures with the time
    left. If the review outlasts the budget, it answers
    `joined-review-running` with the review's progress.
  - It never writes the index or a cooldown, and it runs on the review
    queue off the backend actor.
  - A folder outside the scopes is refused (`outside_scope`) before any
    walk.
  - A stopped measurement is `partial` and its size is a lower bound.
- **Timeouts.** The app's socket deadline is raised to 25 s. The helper
  sends `measure_path` alone through a client with the same 25 s deadline;
  every other tool keeps 10 s.
- **`get_provenance`** would be listed only while an Endpoint Security
  bridge is active. The app runs none, and `tools/list` is static
  (`listChanged: false`), so it is not listed. An active bridge would make
  the count 11.
- **Published lists agree.** The inventory fixture, the contract schema's
  name enum, the Codex fragment and fixture, and the installer's own
  `enabled_tools` line all equal the catalogue, and a test reads every one
  of them. README, `docs/architecture/mcp.md` and
  `docs/operations/privacy-and-retention.md` describe the new tools and the
  stores. This closes FIND-R4-DOCS-STALE.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 100 tests pass |
| `full-suite/` | `verify_candidate.py` on the same input: 727 tests, 0 failures, 11 skipped, candidate `passed` |
| `codex-list-drifts-red/` | The Codex fragment still enables a dropped tool fails `DiskStewardMCPTests.testEveryPublishedToolListIsTheCatalogue` |
| `dropped-tool-listed-red/` | A dropped tool is listed again fails `DiskStewardMCPTests.testEveryPublishedToolListIsTheCatalogue`, `DiskStewardMCPTests.testInitializationAndToolDiscoveryExposeOnlyReadOnlyCatalog` |
| `evidence-state-fixed-red/` | Every listed item reads Verified now whatever its live check says fails `ReviewToolsTests.testHealthAndTheReviewToolsNeverOpenTheRetiredStore` |
| `export-old-shape-red/` | Export_evidence on the retired build fails without legacy evidence instead of exporting the steward store fails `RetiredDetailBackendTests.testExportReadsALegacyCloneAndLeavesTheSetUnchanged`, `RetiredDetailBackendTests.testExportWithoutLegacyEvidenceSaysSo` |
| `health-opens-retired-store-red/` | Get_health opens the retired per-file store fails `ReviewToolsTests.testHealthAndTheReviewToolsNeverOpenTheRetiredStore` |
| `measure-beside-review-red/` | Measure_path starts a second walk while a review runs fails `ReviewToolsTests.testMeasurePathJoinsARunningReview` |
| `measure-budget-red/` | Measure_path runs under the full review budget fails `ReviewToolsTests.testMeasurePathMeasuresInsideTheScopeAndStoresNothing` |
| `measure-outside-scope-red/` | Measure_path walks a folder outside the configured scopes fails `ReviewToolsTests.testMeasurePathMeasuresInsideTheScopeAndStoresNothing` |
| `measure-short-deadline-red/` | Measure_path goes through the 10 s client fails `DiskStewardMCPTests.testMeasurePathUsesTheMeasurementClientAndDroppedToolsAreRefused` |
| `measure-stores-red/` | Measure_path stores a report and a cooldown like a review fails `ReviewToolsTests.testABudgetStopIsAPartialLowerBound`, `ReviewToolsTests.testMeasurePathMeasuresInsideTheScopeAndStoresNothing` |
| `over-ceiling-red/` | List_review_items ignores the response budget fails `ReviewCatalogIncrementTests.testEveryToolAnswersUnderTheCeilingAtCapsThroughTheRealHelper` |
| `total-differs-from-window-red/` | The agent's review total differs from the window's fails `ReviewCatalogIncrementTests.testAnAgentQuotesTheReviewWindowsNumbersAndStates` |

### Every tool at caps, through the real helper (AC-02)

`ReviewCatalogIncrementTests.testEveryToolAnswersUnderTheCeilingAtCapsThroughTheRealHelper`
fills every table to its cap:
- `journal_dirty` 14,000;
- `projects` 2,000;
- `object_index` 20,000;
- 20 reports × 2,000 `review_items`;
- `sessions` 500;
- `session_impacts` 10,000 (50 sessions × 200);
- the capacity ring's volumes, fine samples and hourly samples;
- 8 growth attributions of 100 objects each.

Every path is long (12 nested folder names). The per-file store is a
corrupt file.

The test drives the built `disk-witness-mcp` helper one request at a time,
so no answer is cut by the end-of-input grace or the four-request admission
limit. It calls all ten tools and both resources. Every answer succeeds,
and none exceeds the backend's 1 MiB ceiling. The largest answers, encoded,
are in [`catalog-caps-sizes.json`](catalog-caps-sizes.json).

### The agent and the window (AC-02)

`testAnAgentQuotesTheReviewWindowsNumbersAndStates` reviews a real project.
It then asks the helper `list_review_items` for that folder, and
`get_review_item_evidence` for the first item, and compares the answers
with `ReviewWindowModel` loaded from the same store. These match:
- the state (`complete-with-items`);
- the worth-reviewing total and the item count;
- every item's path, order, size and evidence state;
- the first item's reasons to keep and rebuild command;
- the review time.

The transcript and the window's view are archived side by side in
[`agent-vs-window.json`](agent-vs-window.json).

## Limitations

- **The legacy engine keeps its handlers.** The backend still answers the
  dropped names for direct socket callers in `.live` mode, where the legacy
  engine's tests use them. The helper refuses them before any call, and the
  retired build answers them `detail_unavailable`.
- **`measure_path` on a real scope is proven at GATE-679.** Here it is
  proven on fixtures: in-scope size like `du`, the budget stop, and joining
  a running review.
- **Joining waits rather than shares.** A measurement that joins a review
  waits for it and then measures. It does not read the review's partial
  totals, because a review's report holds objects, not per-folder sizes.
