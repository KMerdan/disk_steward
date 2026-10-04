# TASK-631: cache catalog with recreate classes

Candidate input `79ebe7eef4142c7004427395451c8e7f82f1ab5ce137aeace1ad223e929bf27e` (uncommitted on main after `1af138a`). Nothing has
been installed or published.

## Change

- **`CacheCatalog`** (`Sources/DiskStewardCore/Review/CacheCatalog.swift`)
  lists ten caches. Each entry has its candidate locations, a recreate class
  and the owning tool's own cleanup command, which is shown as text and
  never run.

  | Cache | Recreate class | Cleanup command |
  | --- | --- | --- |
  | uv (`~/.cache/uv`) | re-download | `uv cache prune` |
  | npm (`~/.npm`) | re-download | `npm cache clean --force` |
  | pnpm store | re-download | `pnpm store prune` |
  | `~/Library/Caches` | re-download | Quit the app first, then remove its own folder inside `~/Library/Caches` |
  | CoreSimulator | expensive to recreate | `xcrun simctl delete unavailable` |
  | Xcode DerivedData | rebuild from source | Xcode › Product › Clean Build Folder, or remove a project's folder |
  | Xcode Archives | expensive to recreate | Xcode › Window › Organizer › Archives |
  | Ollama (`~/.ollama`) | expensive to recreate | `ollama rm <model>` |
  | Docker Desktop disk | expensive to recreate | `docker system prune` |
  | act cache | re-download | Remove `~/.cache/actcache`; act downloads actions again |

  Live state (`.git`) is never a catalog entry. "Expensive to recreate" is a
  new `RecreateClass`, ranked with a factor of 0.85.
- **Opt-in.** Settings gain **Cache review**, with one toggle per cache;
  caches not found on this Mac are disabled.
  - `MonitoringSettings.reviewCatalogOptIns` is optional and empty by
    default, so settings written before it still decode, and 1.4.0 ignores
    it.
  - `ReviewService.reviewCatalog(optedIn:)` measures only opted-in caches
    whose location exists. Each is one object (rule `catalog`), sized by the
    review's size-only pass under the same budgets, cooldown and storage.
  - A cache that was not opted in is never read.
- **Ranking.** A cache has no project, so its idleness is its own last use.
  Its item carries the cleanup command, and an expensive cache says so.
- **Unreadable folders inside an object** are now counted on the object and
  stated in its reasons. The size covers the readable rest, and coverage is
  partial. Before this change, one locked folder dropped the whole object;
  the real `~/Library/Caches` has 11 TCC-protected folders.
- **No review source starts a process** other than the two read-only git
  oracles. A test scans the review sources for this.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 39 tests pass |
| `full-suite/` | `verify_candidate.py` on the same input: 684 tests, 0 failures, 11 skipped, candidate `passed`. A first full run failed only the known `ObjectConvergenceTests` seed race (FIND-R4-OBJECT-CONVERGENCE-FLAKE, in the retired scanner path) and was rerun |
| `benchmark/` | The opt-in catalog benchmark and its `du` comparison (below) |
| `ignores-opt-in-red/` | Measuring caches that were not opted in fails `CacheCatalogTests.testOnlyOptedInCachesAreEverRead`, `CacheCatalogTests.testTheServiceStoresCatalogItemsWithTheirCleanupCommands`, `CacheCatalogTests.testUnreadableFoldersInsideACacheAreStatedNotFatal` |
| `no-cleanup-command-red/` | Dropping the owning tool's cleanup command fails `CacheCatalogTests.testCatalogItemsRankByLastUseAndCarryTheToolsCleanupCommand`, `CacheCatalogTests.testCatalogSizesMatchDu`, `CacheCatalogTests.testTheServiceStoresCatalogItemsWithTheirCleanupCommands` |
| `simulators-redownload-red/` | Labelling simulators as cheap to download again fails `CacheCatalogTests.testCatalogItemsRankByLastUseAndCarryTheToolsCleanupCommand`, `CacheCatalogTests.testTheCatalogNamesEveryRequiredCacheWithAClassAndACommand` |
| `unreadable-drops-object-red/` | Dropping a cache because one folder inside is unreadable fails `CacheCatalogTests.testUnreadableFoldersInsideACacheAreStatedNotFatal` |
| `catalog-idle-from-project-red/` | Reading a cache's idleness from a project fails `CacheCatalogTests.testCatalogItemsRankByLastUseAndCarryTheToolsCleanupCommand` |
| `default-opted-in-red/` | Opting a cache in by default fails `CacheOptInSettingsTests.testNothingIsOptedInByDefaultAndChoicesPersist` |

## The opted-in catalog on the maintainer's Mac (AC-02)

The opt-in benchmark ran on input `79ebe7ee` in an isolated snapshot, with
`du -sk` run from the shell on the same paths
([`benchmark/catalog-du.json`](benchmark/catalog-du.json)). It measured
1,195,909 entries in 20.3 s.

| Cache | Review | `du -sk` | Ratio |
| --- | --- | --- | --- |
| `~/.cache/uv` | 60,164,964,352 | 60,164,964,352 | 1.000000 |
| `~/Library/Caches` | 12,495,646,720 | 12,495,646,720 | 1.000000 |
| `~/Library/Developer/CoreSimulator` | 9,830,395,904 | 9,830,395,904 | 1.000000 |
| `~/.ollama` | 8,054,947,840 | 8,054,947,840 | 1.000000 |

`~/Library/Caches` has 11 folders that neither the review nor `du` can read
under this identity. Both skip the same folders, and the review states the
count on the item.
