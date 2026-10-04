# TASK-621: bounded review walker and object index

Candidate input `1839084be106b156ad9778e4146b178175205bef51d1da6a7faa42fba44335c6` (uncommitted on main after `dbdc2c3`). Nothing has
been installed or published.

## Change

All in `Sources/DiskStewardCore/Review/`.

- **`DirectoryReader`** reads one directory level with `getattrlistbulk`.
  - Each entry carries its name, type, device, file ID, link count, allocated
    size and modification time.
  - There is no per-file `stat`, and no symlink is followed.
  - It uses a fixed packed layout (`FSOPT_PACK_INVAL_ATTRS`) and unaligned
    loads, so an entry the file system returns with an error is counted and
    skipped.
  - Tests substitute their own reader for trees the file system cannot make,
    such as a cycle.
- **`ReviewWalker`** is one depth-first walk of a scope.
  - **Classification.** The TASK-611 classifier is asked only about
    candidate names (`node_modules`, `target`, `.git`, …) and about folders
    whose listing holds `pyvenv.cfg` or `CACHEDIR.TAG`.
  - **Objects.** A classified object is one entry. Its allocated size comes
    from a size-only pass in which nothing inside is classified, listed or
    stored, and hard links count once within the object.
  - **Scope total.** Hard links count once across the whole scope, so the
    total matches `du -sk <scope>`, and each object matches
    `du -sk <object>`.
  - **Budgets.** The walk enforces:
    - 120 s of wall time;
    - 5 M entries, counting those inside objects;
    - 256 MiB growth of the physical footprint.
  - **Stops.**
    - More than twice the last complete review's entries stops the review
      (`growth`).
    - A directory identity seen twice also stops it (`revisit`).
    - Excluded folders and other volumes are not entered and are listed.
    - Unreadable folders are counted and make coverage partial.
  - **Report.** It names the top-level folders covered completely and those
    not. It keeps up to 50 unresolved candidates (output names without
    evidence), and records each project's newest source activity outside its
    objects.
- **`IndexedRepositoryOracle`** answers the classifier's repository
  questions without one git process per folder.
  - Tracked folders come from one `git ls-files -z` per repository.
  - Ignore questions go to one long-lived
    `git check-ignore --stdin -z -v --non-matching` per repository, so every
    answer is git's own for that path, including negated patterns.
  - At most four checkers are open at once.
  - Its answers equal `GitRepositoryOracle`'s, the TASK-611 reference, on a
    fixture that has tracked, ignored, collapsed-ignored, nested and negated
    paths. TASK-611's oracle is unchanged.
- **`ReviewIndex`** keeps the review in `steward.sqlite`, under the
  CONTRACT-602 tables.
  - **Objects.** At most 20,000 objects are kept, the largest first, with
    the omission stated.
  - **Projects** are capped at 2,000.
  - **Reports.** One `review_reports` row per review, holding coverage,
    status and limitations that fit the column.
  - **No per-file row is ever written.**
  - **Replacement.** A complete review replaces its scope's objects; a
    stopped one adds what it measured.
- **`ReviewService`** runs one review at a time on its own utility-QoS
  dispatch queue, never on the Swift cooperative pool.
  - A stop sets a 24-hour cooldown for the scope, kept in
    `review-state.json`, so it survives a relaunch.
  - Only a complete review sets the growth baseline.
  - No frontier is ever stored, so nothing resumes after a relaunch.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 50 tests pass: the walker, index, service and indexed oracle, plus the classification, bounded-store, journal, growth, quiet-guard and legacy suites. On a real fixture every object and the scope total equal `du`, including a hard-linked pair inside `node_modules`, a symlink and a sparse file |
| `full-suite/` | `verify_candidate.py` on the same input: 668 tests, 0 failures, 10 skipped, candidate `passed`. The two new skips are the opt-in benchmarks |
| `benchmark/` | The opt-in `ReviewBenchmarkTests` on `~/localGit` and a 1,046,750-entry synthetic tree, plus the `du` comparison run from the shell on the recorded object list (below) |
| `no-prune-red/` | Walking into a classified object fails `ReviewWalkerTests.testObjectsArePrunedSizedLikeDuAndNothingInsideIsListed` |
| `entries-budget-ignored-red/` | Ignoring the entry budget fails `ReviewWalkerTests.testAnEntryBudgetStopsWithAPartialReportAndACooldownThatSurvivesRelaunch` |
| `cooldown-not-persisted-red/` | Keeping the cooldown only in memory fails `ReviewWalkerTests.testAnEntryBudgetStopsWithAPartialReportAndACooldownThatSurvivesRelaunch` |
| `object-links-double-counted-red/` | Counting hard links inside an object per link fails `ReviewWalkerTests.testObjectsArePrunedSizedLikeDuAndNothingInsideIsListed` |
| `revisit-ignored-red/` | Ignoring a revisited directory fails `ReviewWalkerTests.testARevisitedDirectoryStopsTheReview` |
| `stop-sets-baseline-red/` | Letting a stopped review set the growth baseline fails `ReviewWalkerTests.testAnEntryBudgetStopsWithAPartialReportAndACooldownThatSurvivesRelaunch` |

## The benchmark on the maintainer's Mac

Isolated, supervised snapshot; `~/localGit` read in place
([`benchmark/`](benchmark/)).

| | First run | Second run |
| --- | --- | --- |
| Wall time | **47.9 s** | **47.6 s** |
| Entries / folders | 2,025,415 / 245,562 | 2,025,416 / 245,562 |
| Objects | 4,048 (69.7 GB of a 191.4 GB scope) | 4,048 |
| Git questions / time | 4,624 / 9.9 s (144 processes) | 4,624 / 9.9 s |
| Footprint growth | 37 MB | 13 MB |

**`du` parity** ([`benchmark/du-parity.json`](benchmark/du-parity.json)):
- **Objects:** 4,048 objects total 69,687,042,048 bytes, **exactly**
  `du -sk` of each object, with 0 objects off by more than 5%.
- **Scope:** 191,359,119,360 bytes against `du -sk ~/localGit` at
  191,359,123,456 bytes, a ratio of 0.99999998.
- The 4 KB difference is a file that changed between the two measurements.

**Synthetic tree** ([`benchmark/synthetic.json`](benchmark/synthetic.json)):
- The tree has 1,046,750 entries: 530 projects, each with sources and a
  `node_modules`.
- At the default budgets it completes in 6.5 s, with 530 objects, so a
  million-file scope fits easily (ASM-602).
- With an injected budget of 300,000 entries it stops (`stopped:entries`)
  after 1.8 s. The partial report names 151 covered and 379 uncovered
  top-level folders.
- The default 5 M entries would not stop a million-file tree, so the stop is
  shown with an injected budget.

**How the time came down.**
- The first `localGit` run took 69 s, of which 30 s was git:
  `ls-files --others --ignored` walks each repository's working tree.
- Streaming `check-ignore` brought git to 9.9 s and the review to 48 s.
- An early draft kept one checker per repository (about 107) open. That also
  triggered the test supervisor's process-classification race every time.
  Capping open checkers at four removed both problems. An instrumented copy
  of the supervisor then recorded no transient classification failures at
  all.

## Acceptance notes

- **AC-01, "enforced in the worker".** Every budget is checked inside the
  walk loop, per directory, on the review's own utility-QoS queue.
  Cancellation is a flag that the loop reads.
- **AC-02, "cold and warm cache recorded".** Both runs above are warm. The
  cache had been warmed by earlier runs that day, and a true cold run needs
  `sudo purge`, which this session cannot run. Cold timing stays a recorded
  limitation unless the maintainer runs `sudo purge` and the benchmark
  right after.
- **Scope.** No product surface starts a review yet. The window is TASK-623,
  and agent access is TASK-671. The walker, the index and the service are
  complete and tested on their own.
