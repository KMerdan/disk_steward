# TASK-652: directory change journal with replay

Candidate input `57c916cd70425cc181eb3960d762d8e4612db519a745797fbfd2949e0cb7c8b3` (uncommitted on main after `c490369`). Nothing has
been installed or published.

## Change

- **`DirectoryChangeStream`** (`Sources/DiskStewardCore/Monitoring/DirectoryChangeStream.swift`)
  is one FSEvents stream over the configured roots.
  - It uses `UseCFTypes | WatchRoot` and **no** `FileEvents`, so it delivers
    directory paths only.
  - It starts from a stored event ID when one is given.
  - Each delivery becomes a `DirectoryChangeBatch` with the events,
    `historyDone`, and gap signals: MustScanSubDirs, UserDropped,
    KernelDropped, EventIdsWrapped and RootChanged.
  - It also reads the volume's FSEvents journal UUID
    (`FSEventsCopyUUIDForDevice`) and canonical paths. FSEvents reports
    `/private/tmp` where the request said `/tmp`.
- **`ChangeJournal`** (`Sources/DiskStewardCore/Monitoring/ChangeJournal.swift`)
  is an actor on `steward.sqlite`, using the CONTRACT-602 `journal_cursors`
  and `journal_dirty` tables.
  - **Collapse.** Each change collapses to an attribution directory: the
    first object-named component (`node_modules`, `.build`, `target`,
    `.next`, `.venv`, `DerivedData`, ...), else 2 levels below its root. For
    a `~/localGit` root that is the project's subdirectory. Paths are compared
    lexically, with no file-system lookups per event.
  - **Per-interval cap.** Changes are kept per 5-minute capacity interval, at
    most 2,000 directories per interval. Past the cap, a change goes to the
    nearest ancestor already in the set, else to its root.
  - **Gaps.** Gap signals are stored as gap rows. They are never stored as
    "no change".
  - **Retention.** Entries are kept for 7 days. The contract's row and byte
    caps are the backstop, and `coverageStart` reports what remains.
  - **Cursor.** There is one cursor per journal identity, and it never moves
    backwards.
- **`ChangeJournalService`** (`Sources/DiskStewardApp/Lifecycle/ChangeJournalService.swift`)
  follows the active roots and restarts on a change.
  - **Resume.** It resumes from the stored cursor, so a relaunch replays
    until HistoryDone.
  - **No stored cursor.** It records a `journal-started` gap, or
    `journal-reset` when another journal identity had a cursor (a reset or
    erased volume). It takes the cursor *before* starting the stream.
  - **Checkpoints.** Each recorded batch is checkpointed. Each capacity
    sample (`StatusItemController`, on `latestObservation`) persists the
    newest *recorded* event ID, never one that is delivered but not yet
    written.
  - **Smoke runs** create no journal.
- **`explain_growth`** now always answers from the ring and the journal:
  - **`capacity_change`**: the ring's first and last samples in the window
    and `used_delta_bytes`.
  - **`changed_directories`**: `items` with `path`, `changes`,
    `first_interval`, `last_interval` and `measured: false`, plus `total` and
    `truncated`.
  - **`journal_gaps`**, **`journal_coverage_start`** and
    **`journal_limitations`**. The limitations say that earlier changes are
    "unknown, not absent" when the journal starts inside the window.
  - **File-level detail** from the evidence store is added when the store
    can provide it (`detail_status: available`). When it cannot, for example
    because the store is corrupt or lifecycle metadata exceeds the budget, the
    answer says `detail_status: unavailable` with the reason, instead of
    refusing the whole tool.
  - **Client errors** such as an expired cursor or a bad range are still
    refused.
  - **Reads create no files.** Queries never create `steward.sqlite` or
    `capacity.sqlite`; only the app's service and lifecycle do. Without a
    journal, `changed_directories` is `null` with "has not started", so
    unknown is never shown as an empty list. `get_storage_summary`'s ring
    read (TASK-651) uses the same non-creating open.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 80 tests pass across the journal, service, growth, IPC (lifecycle, privacy, scope, cardinality), storage summary, ring, bounded store, MCP read model, lifecycle, backend isolation, recorder and targeted-stream suites. Real FSEvents fixtures replay across a stop and restart until HistoryDone, deliver directory paths only, and hold a 2,050-directory burst at the 2,000 + 1 cap |
| `full-suite/` | `verify_candidate.py` on the same input: 645 tests, 0 failures, 7 skipped, candidate `passed`. It covers CONTRACT-602, TASK-651 and TASK-652 together, including the contract and MCP suites |
| `file-events-red/` | Asking FSEvents for per-file events fails `ChangeJournalTests.testRealStreamReplaysChangesMadeWhileStopped` |
| `no-replay-red/` | Ignoring the stored event ID on start fails `ChangeJournalServiceTests.testRelaunchReplaysFromTheStoredCursorWithoutANewGap`, `ChangeJournalTests.testRealStreamReplaysChangesMadeWhileStopped` |
| `gap-as-change-red/` | Recording gap flags as ordinary changes fails `ChangeJournalTests.testWindowsAggregateAcrossIntervalsReportGapsAndTruncate` |
| `no-cap-red/` | Not enforcing the 2,000-directory interval cap fails `ChangeJournalTests.testDirectoriesAreCappedPerIntervalWithOverflowToAPresentAncestor`, `ChangeJournalTests.testRealStreamBurstStaysWithinTheIntervalCap` |
| `reset-silent-red/` | Reporting a new journal identity as a first start fails `ChangeJournalServiceTests.testANewJournalIdentityIsReportedAsAReset` |
| `filesystem-paths-red/` | Standardizing paths through the file system fails `ChangeJournalServiceTests.testRelaunchReplaysFromTheStoredCursorWithoutANewGap`, `ChangeJournalTests.testRealStreamBurstStaysWithinTheIntervalCap`, `ChangeJournalTests.testRealStreamReplaysChangesMadeWhileStopped` |
| `growth-no-journal-red/` | explain_growth without the journal answer fails `ExplainGrowthJournalTests.testGrowthKeepsFileDetailAndAddsTheJournalWhenTheStoreIsReadable`, `ExplainGrowthJournalTests.testGrowthNamesChangedDirectoriesAndTheCapacityChangeWithoutTheEvidenceStore`, `ExplainGrowthJournalTests.testReadsCreateNeitherTheJournalNorTheRing` |
| `growth-refuses-red/` | Refusing explain_growth when file detail is missing fails `LifecycleProjectionIPCIntegrationTests.testOversizedLifecycleMetadataReturnsTypedNonretryableErrorThroughIPC` |
| `growth-swallows-cursor-red/` | Degrading an expired cursor instead of refusing it fails `ExplainGrowthJournalTests.testGrowthStillRefusesAnExpiredCursorAndABadRange` |
| `read-creates-journal-red/` | A query creating the journal file fails `ExplainGrowthJournalTests.testReadsCreateNeitherTheJournalNorTheRing` |

## Acceptance notes

- **AC-01, "covers the configured scopes".** The stream covers the active
  roots from settings, not the whole home volume. The design's
  "home-volume" stream is narrowed to what the user watches, which is also
  what attribution can name.
- **AC-01, "persisted at each capacity sample".** Persisting happens per
  recorded batch and again at each capacity sample. A sample alone cannot
  move the cursor past events that are still being written.
- **AC-01, gap flags.** Real FSEvents does not produce MustScanSubDirs,
  dropped or wrapped events on demand. Their mapping is tested with
  synthetic flag records (`interpret`). A journal-identity change is tested
  through the service with a stored cursor for another identity.
- **AC-02, "nearest object or project root".** Object directories are
  recognized by name. Project roots are approximated as 2 levels below a
  root until TASK-661 builds the project index.
- **AC-02, overflow.** The design says overflow collapses "to the parent".
  Here it goes to the nearest ancestor already in the set, else the root, so
  overflow never adds entries beyond the cap. The cap holds at 2,000 + 1.
- **AC-03** is in [`tcc/README.md`](tcc/README.md). On macOS 15.6.1 (24G90),
  changes inside Documents, Desktop and Downloads are delivered without
  Full Disk Access. Whether delivery depends on per-folder consent is
  confirmed with the installed app at GATE-659.
- **The old targeted stream.** The per-file `TargetedFSEventsCollector`
  still feeds the old scanner. It is retired with the scanner in TASK-653,
  so after TASK-653 the journal is the only FSEvents stream.
- **Replays can count twice.** A batch is recorded before its checkpoint.
  If the app dies between the two, the batch is replayed and counted again.
  Counts are event counts, not sizes (`measured: false`), so a double count
  never inflates a measured number.
- **The page schema.** `Schemas/MCP/evidence-query-page-v1.schema.json` is
  not enforced: the helper advertises no `outputSchema`, and no test
  validates responses against it. It was also already out of date before
  this task, since it lacks `explain_growth`'s `surviving_*` keys. The new
  keys and `coverage: "unavailable"` are recorded as a finding for the rung-4
  tool rework, outside this task's write scope.
