# TASK-532 — Reserve storage headroom and make retention recovery bounded

Actor: `claude` (Pyramid PLAN-DISK-STEWARD-005, R13, guard `GUARD-TASK-49C90C3E5D4C58EAEB5567956CE5E958` after amendment `AMEND-be8767f5…` at G100).
Base: TASK-531 candidate `f55627d8ff97…` (bounded frontier, schema 14). Nothing was committed, pushed, installed, signed or released; no installed-app evidence or client configuration was touched. All runs are isolated verifier snapshots under `/private/tmp`.

## What changed

**One storage accounting** (`EvidenceStorageAccounting`, surfaced on `EvidenceLifecycleStatus.storage`):

| field | meaning |
|---|---|
| `liveBytes` / `reusableBytes` | pages in use / free-list pages (never counted against the cap) |
| `walBytes` / `sharedMemoryBytes` | write-ahead log and shared memory as they count today |
| `stagedRowCount`, `reservedPublicationBytes` | rows waiting in `scan_generation_entries` and the durable growth their publication needs |
| `nextWorkReserveBytes` | one nominal 512-entry slice while a generation is active |
| `publicationLogEstimateBytes`, `availableDiskBytes` | transient log the publication will write, against the volume's free space |
| `walPinnedByReader`, `evictableHistory` | whether an open reader holds log frames; whether retention has anything to evict |
| `admission` | `available`, `retention-required`, `capacity-limited`, `wal-pinned`, `disk-space-limited` |
| `limitations` | the sentence a user or agent needs, e.g. "raise the cap or narrow watched roots. Nothing was evicted." |

**Typed admission** (`EvidenceStore.admit(_:)`) replaces the flat byte check on every write path (events, hints, exports, sessions, scan staging and publication). Work is admitted only when its own bytes *and* the reserve for publishing everything staged fit under the cap, and the volume can hold the transient publication log plus a 64 MiB floor. Refusal is typed:

- `storageCapacityExceeded(currentBytes:capBytes:)` — the store itself is over.
- `storageHeadroomUnavailable(reason:accounting:)` with reason `publication-reserve`, `wal-pinned` or `disk-space` — the store is under the cap but the requested work is not admissible; the accounting says why.

Nothing is evicted at admission. A refusal carries its exact demand (`storageHeadroomUnavailable(reason:demandBytes:accounting:)`), and the caller that holds the refusal passes it to `applyRetention(_:trigger:demandBytes:)`; the store also keeps the largest demand refused since retention last ran (`pendingStorageDemandBytes`, cleared only by retention or by admitting work at least that large, so an unrelated small write cannot erase it). One bounded run therefore targets the refused work instead of stopping at a fixed 16 MiB margin. Generic writes (events, hints, sessions, exports) demand their own bytes plus the publication and next-slice reserves, so they cannot consume the room the next slice needs; a staging slice is the next work itself and demands its bytes plus the publication of everything staged.

**Cost model** (`StorageCostModel`), measured on the 1,000,000-file run of TASK-531 (3.3 GB final database, 2.98 GB peak log) and rounded up: 1,024 B per staged row, 2,304 B per newly published row, 768 B per republished row (rows current state already holds), 3,072 / 1,024 B of log per new / republished row, 64 KiB fixed per publication. Republished rows are those within the current-state count, so a steady-state re-scan of a tree that fits does not reserve as if it were new. Sizing guidance that follows: about 3.4 KB of cap per watched file on first publication.

**Write-ahead log**: `PRAGMA journal_size_limit` (16 MiB default, `walJournalSizeLimit:` on init) truncates a checkpointed log when SQLite restarts it, so the 2.98 GB publication peak no longer persists as a file between samples. The accounting probes the log only when it is decisive (past its bound, or when counting it would push the demand over the cap): a PASSIVE checkpoint that leaves frames behind means an open reader pins them (`wal-pinned`, reclaimed when the reader closes, never by eviction); one that moves everything is followed by a non-blocking TRUNCATE.

**Retention**: eviction is judged on the same live-plus-log bytes that admission counts; `retentionCheckpoint` stages (`after-tier-compaction`, `after-eviction-batch`) make interruption reproducible; the target is `cap − max(16 MiB, refused demand, publication reserve)`. Authoritative `current_file_state` is never evicted; when nothing evictable remains the run records "remains above its cap because no evictable history remains; live current-state truth was preserved."

**Probe** (`PersistentMonitoringProbe`): the cap from settings is synced to the store before every sample (`updateStorageCap`), so raising it takes effect without a retention run. A storage refusal is recoverable work, never an error loop: when evictable history exists one bounded pressure retention run is tried and the same work retried once; otherwise, and after a failed retry, the sample returns an observation with `scanStalled = true` (the controller backs off to its regular interval), `needsScanContinuation` reflecting the still-active generation, the volume snapshot, and explicit limitations. The database dimension of the circuit breaker is judged on the accounting (`committedBytes`) and applies only while the accounting says `available`; every other admission (retention-required after the scheduled run, capacity-limited, reader-pinned, disk-limited) is reported through limitations and handled by typed admission and bounded retention instead, so an over-cap store with only authoritative state keeps sampling volumes. SQLite's own `SQLITE_FULL` (code 13) is treated as a refusal with its transaction rolled back.

**Scanner desync (found by the fixtures, amendment at G100)**: a slice the store refused or failed had already consumed names from the in-process directory stream; the durable cursor had not advanced, and the next slice continued from the stream's position, silently skipping those names (688 of 1,200 files published in `headroom-red-2`). `MetadataScanDirectoryCursor.consumedNames` now records how many names the stream had served; a stream ahead of its committed cursor is treated exactly like a lost stream and restarts only that pass. The same defect applied to any failed commit inside one process.

## Fixtures and evidence (`StorageHeadroomTests`, `StorageRecoveryIncrementTests`)

| fixture (AC-TASK-532-01) | test | proof |
|---|---|---|
| below cap, insufficient reserve | `testStagingIsRefusedWhenThePublicationReserveWouldExceedTheCap` | reason `publication-reserve`, zero rows staged, generation stays open, accounting `retention-required` with negative headroom |
| retention targets the refused demand | `testOneRetentionRunTargetsTheRefusedDemandAndTheScanThenCompletes` | forced evictions > 0 after one `.pressure` run; the same work is admitted; 1,200 files published; accounting `available` |
| above cap, no history | `testAboveCapWithoutEvictableHistoryPreservesCurrentStateAndRefusesExplicitly` | 8,000 published files > 10 MiB cap; retention evicts only snapshots and records the limitation; `capacity-limited`, "Nothing was evicted"; inserts and new generations refused; current state intact; integrity ok |
| WAL reader | `testReaderPinnedWriteAheadLogIsReportedAndReclaimedWhenTheReaderCloses` | a reader holding a snapshot grows the log past 1 MiB: `walPinnedByReader`, refusal `wal-pinned`; after the reader ends: log truncated, committed bytes fall, the same insert is admitted |
| interruption | `testInterruptedRetentionIsRecoveredOnReopenAsAnExplicitFailure` | crash image taken at `after-tier-compaction`; within the 6 h window the run stays `started`; afterwards it is recorded `failed` with "The process stopped before this retention run completed; no completion result is inferred.", bytes-after not inferred, history intact, later runs complete |
| disk full | `testDiskFullDuringStagingRollsBackAndTheGenerationResumesOnceSpaceReturns` | `PRAGMA max_page_count` yields `SQLITE_FULL` mid-staging; the failed slice is rolled back whole; the generation resumes from committed progress and publishes all 3,000 files once space returns |
| disk space preflight | `testInsufficientVolumeSpaceIsRefusedBeforeAnyWrite` | 1 MiB free: reason `disk-space` before any write; accounting `disk-space-limited`, "Nothing was written" |
| no uncontrolled maintenance loop | `testCapTooSmallForTheTreeYieldsExplicitNonProgressUntilTheCapIsRaised` | 6,000 files under a 10 MiB cap: sample 1 stages until refused and stalls; sample 2 tries exactly one pressure retention and reports "could not make enough room"; sample 3 refuses without retention (one pressure run total); cap raised to 64 MiB: one sample completes 6,000 files; cap lowered again: `capacity-limited`, volume sampling continues, nothing thrown, current state intact across two more samples |

Runs (all `/private/tmp/ds552-check-*` snapshots, result.json carries the exact input hash):

- `headroom-red-1/` — first run: fixture premises wrong (fresh schema ≈ 1 MB), and the 688/1,200 loss.
- `headroom-red-2/` — premises fixed; the loss reproduced twice (retention fixture and disk-full fixture) → scanner amendment.
- `headroom-green/` — 7/7 store fixtures after the scanner fix (input `a3f04702…`).
- `recovery-red-1/` — probe test red: the stale log made every sample run a retention and admit one more slice (a real, if bounded, loop) → accounting probes the log when decisive; next-slice reserve added.
- `headroom-and-recovery-green/` — 8/8 (input `dc291746…`).
- `candidate-red-1/` — first full verifier (input `dc291746…`): 520/522; the two lifecycle-projection tests failed because the accounting read the active generation through the private traversal checkpoint decoder. Fixed with a scalar `EXISTS` query (the public summary must never decode `scan_generations.progress`).
- `projection-fix-green/` — the two projection suites plus the new fixtures, 17/17 (input `50612d6a…`).
- `candidate-2/` — full six-stage verifier on input `50612d6a…`: 522 tests, 0 failures (the input the static review's fixes were applied to).
- `review-fix-green/` — after the review's F1 fix and observations: the two projection suites plus the new fixtures, 17/17 (input `02fe77cd…`).
- `candidate/` — full six-stage verifier on the final input `02fe77cd43a1b901285a042d07777a72daf25441fd0cabde6de5f6e7bc99a5ce`: harness, toolchain, manifest, entitlements, build, tests all passed; 522 tests, 4 skipped, 0 failures.
- `headroom-mutation-red/` (base `02fe77cd…`): the publication reserve dropped from the admission demand → store fixtures fail. `desync-mutation-red/`: the stream-ahead-of-cursor restart disabled → the retention and disk-full fixtures lose names again. `recovery-mutation-red/`: the old database breaker applied to a capacity-limited store → the probe throws instead of reporting. `*-mutation-red-1/` and `*-mutation-red-2/` are the same mutations against the earlier inputs `dc291746…` and `50612d6a…`, kept.
- `storage-review-{job,result}.json` — read-only static delta review on input `dc291746…` (advisory, never final evidence). Finding F1 (P2): the refused demand lived in one shared actor field that an unrelated successful write could zero between a refusal and the retention it triggered → fixed as described under "Typed admission", with regression assertions in the retention fixture. Observations: generic writes now respect the next-slice reserve; the breaker prose above was reconciled with the code; a dead variable was removed. `storage-source-delta.diff` and `storage-base-source/` (base copies verified byte-for-byte against the TASK-531 candidate manifest) make the review reproducible; `storage-source-manifest.json` records both post-review deltas.
- `scale-runs/` — see "Scale" below.

## Scale

The TASK-531 supervisor (`docs/reliability/evidence/TASK-531/scale/supervise_scale_531.py`) was rerun against this candidate's release bundle (`swift build -c release --build-tests -Xswiftc -enable-testing` on the final input, `candidate-input.txt` in each run directory) with the product default cap of 512 MiB, to show that typed admission adds no amplification on the product path and that a 100,000-file first publication is admitted under the default cap.

| run (wide, 100,000 files, cap 512 MiB) | elapsed | publication | slices | peak db family | peak log | peak RSS | restarts | result |
|---|---|---|---|---|---|---|---|---|
| TASK-531 baseline (input `f55627d8…`) | 24.4 s | 12.3 s | — | 637 MB | — | 54 MB | 0 | 100,000 published |
| `scale-runs/wide-100k-bundle-50612d6a/` | 27.2 s | 12.8 s | — | 635 MB | 301 MB | 58 MB | 0 | 100,000 published |
| `scale-runs/wide-100k/` (final input `02fe77cd…`) | 26.1 s | 12.2 s | 196 | 634 MB | 300 MB | 57 MB | 0 | 100,000 published |

The admission overhead is about 1.7 s over 196 slices (two count queries and one accounting per slice); publication time, database size and log peak are unchanged. The 1,000,000-file case is not rerun here: by the model it needs about 3.4 GB of cap and the store now says so at admission instead of writing a 3.3 GB database under a 512 MiB cap; TASK-531's 1M run (`docs/reliability/evidence/TASK-531/scale-runs/wide-1m/`, 4 GiB cap) remains the bound-scan evidence.

## Limitations

- The cost model is a rounded-up constant per row measured on one machine and one schema; the accounting reports what was reserved so a wrong constant is visible, not silent. Slices that close hundreds of small directories at once can exceed the nominal next-slice reserve; admission itself is exact.
- A fully checkpointed log below 16 MiB is counted at file size between probes; the worst overcount is the bound.
- Volume free space comes from `volumeAvailableCapacityForImportantUsage`; the 64 MiB floor is a policy constant.
- No installed-app, overnight or multi-process run; the reader-pinned fixture uses a second connection in the same process.
