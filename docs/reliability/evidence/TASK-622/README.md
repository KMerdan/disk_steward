# TASK-622: rank objects by reclaim value

Candidate input `b584a8c21e8f5a9954704ca85f461e7dd0b66d7965a24741896f553cbdde5bbc` (uncommitted on main after `bd5ac82`). Nothing has
been installed or published.

## Change

- **`ReviewRanking`** (`Sources/DiskStewardCore/Review/ReviewRanking.swift`)
  is a pure function of a recorded `ReviewReport` and a time `now`. The same
  inputs always give the same order.
  - **Score.** The score is allocated bytes × an idle factor × a recreate
    factor.
  - **Idle factor.** It rises from 0.2, for a project changed now, to 1.0 at
    180 days. It uses the **owning project's** newest source change outside
    its objects, never the object's own timestamp, which a rebuild refreshes.
  - **Monorepos.** The owning project is the nearest project at or above the
    object, so a package inside a monorepo is judged by its own activity.
  - **Recreate factor.** It is kept narrow on purpose: re-download 1.0,
    rebuild 0.92. Idleness decides, and a project idle for 30 days or more
    always outranks an equally sized object in a project changed within a
    day.
  - **Order.** Ties break by size, then path. Repositories are measured but
    never ranked.
- **Rebuild commands** come from the object's name and the project's tool
  hints.
  - **Tool hints.** The walker now records them from the project folder's
    own listing (`pnpm-lock.yaml`, `Cargo.toml`, `uv.lock`, …), and they
    include enclosing projects, so a monorepo root's lockfile names the
    package manager.
  - **Examples.** `node_modules` gives `pnpm install`, `yarn install` or
    `npm ci`/`npm install`. `target` with Cargo gives `cargo build`, `.build`
    gives `swift build`, and `.venv` gives `uv sync`, `poetry install`, …
  - **Caches** are recreated by their tool, and Python bytecode
    automatically.
  - **Unknown.** Anything without a known command says "Unknown: … check the
    project's own instructions before removing it". Nothing is guessed.
- **Every item is `review-required`.** There is no safe-to-delete state.
  Each item's reasons state the evidence, the project's idle time and how
  the item is recreated.
- **Revalidation.** `ReviewRanking.revalidate` checks each item against its
  live path. Still a directory means review-required, re-verified at that
  time; otherwise the item is `missing`.
- **Storage.** `ReviewService` stores the ranked items of every review in
  `review_items`: at most 2,000 per report, in rank order, with the command
  and reasons as JSON in the reasons column. `ReviewIndex.items(reportID:)`
  reads them back.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 33 tests pass |
| `full-suite/` | `verify_candidate.py` on the same input: 674 tests, 0 failures, 10 skipped, candidate `passed` |
| `object-timestamp-red/` | Reading idleness from the object's own timestamp fails `ReviewRankingTests.testAFreshlyRebuiltObjectNeverOutranksAnEquallySizedLongIdleOne`, `ReviewRankingTests.testEveryItemCarriesACommandOrAnExplicitUnknownAndStaysReviewRequired`, `ReviewRankingTests.testRankingIsReproducibleFromRecordedInputs` |
| `no-idle-factor-red/` | A score that ignores idleness fails `ReviewRankingTests.testAFreshlyRebuiltObjectNeverOutranksAnEquallySizedLongIdleOne`, `ReviewRankingTests.testRankingIsReproducibleFromRecordedInputs` |
| `unknown-hidden-red/` | Hiding an unknown command behind an empty known one fails `ReviewRankingTests.testEveryItemCarriesACommandOrAnExplicitUnknownAndStaysReviewRequired` |
| `not-review-required-red/` | Items leaving the review-required state fails `ReviewRankingTests.testEveryItemCarriesACommandOrAnExplicitUnknownAndStaysReviewRequired`, `ReviewRankingTests.testTheReviewStoresRankedItemsWithTheirCommands` |
| `repository-ranked-red/` | Ranking repositories as candidates fails `ReviewRankingTests.testEveryItemCarriesACommandOrAnExplicitUnknownAndStaysReviewRequired`, `ReviewRankingTests.testRankingIsReproducibleFromRecordedInputs` |

## Acceptance notes

- **"Reproducible from recorded inputs".** The ranking reads only the
  recorded report (objects, projects with activity and tools) and `now`. The
  test ranks the same recorded inputs twice and checks the exact expected
  order. The stored items carry the time they were ranked (`verified_at`).
- **"A freshly rebuilt object never outranks an equally sized long-idle
  one".** This is tested over every pairing of a project changed 0, 0.5 or 1
  day ago with one idle 30, 90 or 365 days, across both recreate classes.
  One case has the idle project's object rebuilt this morning, which shows
  that project activity, not the folder's timestamp, decides.
- **Revalidation** is a function used before items are shown. The review
  window (TASK-623) calls it.
