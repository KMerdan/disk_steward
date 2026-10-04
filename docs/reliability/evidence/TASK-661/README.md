# TASK-661: measured growth attribution

Candidate input `61c4648a069bd485a42e53b777a2f9b9c44409697404925fd5297d9fb3aa0d60` (uncommitted on main after `d00345e`). Nothing has
been installed or published.

## Change

- **`GrowthAttributor`** (`Sources/DiskStewardCore/Review/GrowthAttribution.swift`)
  joins the change journal's dirty directories to objects, re-measures those
  objects with the review walker's size-only pass under a review budget, and
  attributes the volume delta to them.
  - **The join.** A changed directory can relate to stored objects in three
    ways:
    - it lies at or inside a stored object, which marks that object;
    - it lies *above* stored objects, which marks every object under it;
    - it is object-named (`node_modules`, `.venv`, …) with no stored object,
      which makes it a new candidate.

    The second case is the common one. Without an object name on the way,
    the journal collapses a change two levels below a watched root: with
    the home folder as a root, a change in `~/code/web/node_modules` is
    journaled as `~/code/web`. A target inside another target is dropped,
    because the walker stops at a revisit.
  - **Each object's basis:**
    - `measured`: the delta from its last stored size, with both
      timestamps;
    - `created`: the birth time falls inside the window, so it was empty
      before;
    - `no-baseline`: it was measured now but never before; its size is
      recorded and its change is *not* counted as zero;
    - `gone`: its delta is minus its last size;
    - `not-measured`: the budget ran out first.
  - **Totals.** The attributed total is the sum of measured deltas. The
    unexplained remainder is the volume delta minus that total. It covers
    System Data, purgeable space, APFS snapshots, files outside measured
    objects, and anything outside the monitored folders. No cause is ever
    claimed for it.
- **`GrowthAttributionService`** runs attributions and advances the
  stored object sizes after each one, so consecutive windows are
  contiguous and growth is never counted twice. It keeps the last 8
  attributions in `growth-attributions.json` beside the steward file. The
  file is capped at 512 KiB, oldest dropped first.
  - **Threshold.** Every capacity sample feeds the trigger. When used space
    has grown by the Settings growth threshold (`growthThresholdMiB`, 5 GiB
    by default) above its lowest point since the last attribution, the
    dirty objects are measured under the full review budget (120 s, 5 M
    entries, 256 MiB). The trigger waits while a review is measuring.
  - **On request.** An `explain_growth` window that ends within 10 minutes
    of now gets a fresh attribution, measured under a 4 s request budget
    inside the 10 s IPC deadline. An attribution under two minutes old is
    reused instead. A window in the past only gets the stored attributions
    it overlaps.
- **`explain_growth`** gains `measured_growth`: per-attribution windows,
  volume delta and sample times, attributed and unexplained bytes, what the
  remainder covers, per-object rows, unmeasured directories, journal gaps,
  completeness and limitations. A changed directory is marked `measured`,
  with the summed delta, when an attribution measured objects at, inside or
  under it.
- **`ReviewIndex`** gains `objectsContaining`, `objectsUnder` and
  `updateMeasurements`. An updated row keeps its project; a gone object is
  removed. `CatalogTarget.cleanupCommand` is now optional, because an
  attribution target has no cleanup command.

### Decisions

- **No new table.** `BoundedStoreContractTests` pins the steward file's
  tables (CONTRACT-602). Reusing `review_reports` would have let frequent
  attributions evict the user's reviews, because its 20-row cap is shared
  across the table. Attributions therefore live in a bounded file beside
  the steward file, like `review-state.json`.
- **No `measure` argument.** The MCP catalogue rejects unknown arguments,
  and `Sources/DiskStewardMCP` and `Schemas/` are outside this task's write
  scope. "On request" is therefore a question whose window reaches the
  present. An explicit argument belongs to TASK-671's catalogue rebuild.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 71 tests pass |
| `full-suite/` | `verify_candidate.py` on the same input: 708 tests, 0 failures, 11 skipped, candidate `passed`. Earlier attempts on the same input: 1, 3, 4 and 5 stopped on the supervisor's classification race (FIND-R4-SUPERVISOR-RACE); 2 failed only the known `ObjectConvergenceTests` seed race in the retired scanner path (FIND-R4-OBJECT-CONVERGENCE-FLAKE). Attempt 6, with nothing else running, is the record |
| `baselines-not-advanced-red/` | An attribution does not store its measurements as the next baselines fails `GrowthAttributionTests.testASecondAttributionCountsOnlyTheNewGrowth`, `GrowthAttributionTests.testGoneCreatedAndUnknownObjects` |
| `changed-directories-unmarked-red/` | Changed directories never say they were measured fails `ExplainGrowthAttributionTests.testAQuestionReachingThePresentIsAnsweredWithMeasuredDeltas` |
| `gone-ignored-red/` | A removed object's shrinkage is not attributed fails `GrowthAttributionTests.testGoneCreatedAndUnknownObjects` |
| `nested-targets-kept-red/` | A target inside another is measured twice fails `GrowthAttributionTests.testATargetInsideAnotherIsMeasuredOnce` |
| `no-baseline-as-zero-red/` | An object with no earlier measurement is taken to have been empty fails `GrowthAttributionTests.testGoneCreatedAndUnknownObjects` |
| `past-window-measures-red/` | A question about the past measures the present fails `ExplainGrowthAttributionTests.testAnEarlierWindowUsesOnlyStoredAttributions` |
| `request-ignores-budget-red/` | A question measures under the full review budget fails `GrowthAttributionTests.testAQuestionReusesARecentAttributionAndMeasuresAfterIt` |
| `threshold-never-lowers-red/` | The threshold counts from the first sample, not the lowest point fails `GrowthAttributionTests.testTheThresholdTriggersOnceFromTheLowestPoint` |
| `under-join-dropped-red/` | Objects under a changed directory are not joined fails `ExplainGrowthAttributionTests.testAQuestionReachingThePresentIsAnsweredWithMeasuredDeltas`, `GrowthAttributionTests.testATargetInsideAnotherIsMeasuredOnce`, `GrowthAttributionTests.testChangesJoinToObjectsAtAboveAndBelowThem`, `GrowthAttributionTests.testGrowthInTwoObjectsAndOutsideTheScopeIsAttributedAndTheRestUnexplained` |
| `unexplained-ignores-attributed-red/` | The unexplained remainder ignores what was attributed fails `ExplainGrowthAttributionTests.testAQuestionReachingThePresentIsAnsweredWithMeasuredDeltas`, `GrowthAttributionTests.testGrowthInTwoObjectsAndOutsideTheScopeIsAttributedAndTheRestUnexplained` |
| `unmeasured-counted-red/` | Objects without a measured delta are counted as attributed fails `GrowthAttributionTests.testABudgetStopLeavesObjectsNotMeasured`, `GrowthAttributionTests.testGoneCreatedAndUnknownObjects` |

### AC-02: two objects and growth outside the scope

`testGrowthInTwoObjectsAndOutsideTheScopeIsAttributedAndTheRestUnexplained`:
- Fixture: a reviewed scope whose `node_modules` and `target` grow by 6
  and 9 MiB, plus 20 MiB written outside the scope.
- The journal is rooted above the projects, so both changes collapse to the
  project folders and the objects are found under them.
- The capacity ring carries the combined growth.
- Result: the attributed bytes equal the `du` growth of the two objects,
  within the 5% the criterion allows (exact in practice). The unexplained
  remainder equals the outside growth, also within 5%.
- `testAQuestionReachingThePresentIsAnsweredWithMeasuredDeltas` checks the
  same through `explain_growth` over the real IPC socket: a 5 MiB object
  delta, 12 MiB unexplained, the journal gap stated, and the changed
  project folder marked `measured`.

## Limitations

- The volume delta comes from the capacity ring's first and last samples
  inside the window, taken every 5 minutes. When those samples cover only
  part of the window, the attribution says so. Used space is
  `total - available`, which on APFS includes other volumes in the
  container and changes in purgeable space. That is part of why the
  remainder exists.
- The first attribution's baselines come from reviews taken at different
  times. An object measured before the window can carry earlier change, and
  one measured during it can miss some; the attribution counts both cases.
  Later attributions start where the previous one ended.
- Changed directories with no stored object, such as source edits or new
  folders that are not object-named, are not measured. They are listed (a
  sample of 24 plus a count) and their change is in the remainder.
- Objects found under a changed directory are measured even when they did
  not change: they get a delta of 0, and the measurement costs time within
  the budget. At most 200 objects per changed directory and 500 per
  attribution are considered.
- A question that reaches the present measures directory metadata and
  updates Disk Steward's own index and attribution file. It reads no file
  contents and changes nothing else.
- The threshold attribution is not shown on the status board yet;
  `explain_growth` is where it is read.
