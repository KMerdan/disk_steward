# Disk Steward redesign: answer in a minute, idle near zero

Status: design proposal, 2026-10-04. Nothing here is implemented.

This document absorbs [quiet-storage-guard-design.md](quiet-storage-guard-design.md).
That proposal's product decision, interface, states and `ReviewReport` contract
still apply. This one adds what it left unspecified: the engine, the storage
rules that make the current class of failure impossible, the data budget,
migration, and an installable delivery ladder. The engine assumptions of
`PLAN-DISK-STEWARD-006` would need a replan before any of this is built
(see [Plan impact](#plan-impact)).

## What the user gets

1. **How much space is left compared with my reserve?** This is always
   answered, instantly, even if every other part of the app is broken.
2. **Where did the space go since a given time?** The answer is a volume delta
   split into the directories and objects that changed, plus an explicit
   unexplained remainder.
3. **What is worth reviewing to get space back?** A list of build output,
   environments and tool caches. Each item has a size, its project, last
   activity, how it gets recreated, reasons to keep it, and the owning tool's
   own cleanup command. A review of `localGit` finishes in under a minute.

An agent connected over MCP reads the same three answers with the same
uncertainty labels.

## Why the current engine cannot work

These were measured on this Mac on 2026-10-04, read-only.

- **Unit of storage.** Every file under a watched root gets rows in
  `current_file_state`, `path_bindings`, `file_state_observations` and
  `file_objects`, with their indexes. That costs about **1.6 KB per file**
  (152 MiB for about 100k files). During a scan, a second copy is staged in
  `scan_generation_entries` at about **1.7 KB per file** (206 MiB for 123,280
  files) until it can be published.
- **Scope.** The watched roots hold **2.15 M entries**: `localGit` has 1.98 M
  and `Documents/Codex` has 173k. At about 3.3 KB per file, a full inventory
  needs about **7 GB**, but the store's cap is **512 MiB**. Collapsing
  recognized objects (TASK-613) does not close the gap. **1.09 M entries**
  remain outside them in `localGit` alone, about 1.7 GB of current-state rows.
- **No convergence.** The scan that started on 2026-09-18 staged 123,280 files
  and then hit the cap. It cannot publish, so it keeps re-walking: it has
  processed **488 M entries** with 1 of 3 roots complete. App CPU was sampled
  at **47% of a core on 09-23 and 67% today**, across a 10-day uptime.
- **Retention thrash.** At the cap, pressure retention ran about 100 times a
  day (1,493 runs since 2026-09-21). Each run evicted the only evictable
  data, which is old history, and recorded a gap row. At 512 gap rows the
  summary budget refused every request. That disabled `get_storage_summary`,
  `get_evidence_lifecycle` and `explain_growth`, and the helper self-check
  failed (patched on `hotfix/lifecycle-gaps-1.2.4`).
- **Result.** Persisted file state is frozen at 2026-09-13. Eviction also
  removed the capacity history: the oldest of the 259 retained volume
  snapshots is from 05:30 UTC today. The app therefore cannot say how free
  space changed since its 09-23 reading of about 418 GiB. Today it reads
  410.7 GiB available for important usage, which includes purgeable space,
  while `df` shows 349 GiB plain free.

This is not a bug to patch. A per-file inventory is the wrong unit of storage
for a developer's home directory.

## The benchmark this design must beat

With a warm cache, plain `find` with pruning plus `du` on this Mac took
**17 s to walk** `localGit` and **13 s to size** the **3,700 objects** it found:

| Found | Size |
| --- | --- |
| `.next` (11 dirs) | 16.1 GiB |
| `target` (63) | 14.4 GiB |
| `.build` (9) | 9.9 GiB |
| `node_modules` (111) | 9.1 GiB |
| `.venv`, `.turbo`, `__pycache__`, `dist`, … | 3.6 GiB |
| `.git` (200 repositories; context only, never a candidate) | 6.9 GiB |
| `~/.cache/uv` | 56.0 GiB |
| `~/Library/Caches` | 11.6 GiB |
| `~/Library/Developer/CoreSimulator` | 9.2 GiB |
| `~/.ollama` (models: expensive to recreate) | 7.5 GiB |
| `~/.cache/actcache`, `~/Library/pnpm`, `~/.cache/codex-runtimes` | 12.3 GiB |

That is about **150 GiB worth reviewing**, not all of it reclaimable, found in
well under a minute. The app currently reports none of it.

**Acceptance benchmark:** reviewing `localGit` plus the cache catalog finishes
in **< 60 s wall time** on this Mac (record cold- and warm-cache runs).
Measured object totals stay within 5% of `du`, and the review persists
**≤ 2,000 report items**.

## Engine

There are three independent parts. Each works without the others.

### A. Capacity guard (always on)

- Sample the volume through the existing `VolumeSnapshotService` every
  5 minutes, on wake and on demand. Store samples in a capacity ring in its
  own file: 5-minute samples for 7 days, hourly for a year. The ring never
  touches the detail store.
- The reserve, its hysteresis and the notification rules are as in the
  09-23 doc. `Capacity unavailable` is shown instead of a stale value.

### B. Change attribution (always on, event-driven, no traversal)

- Use one directory-level FSEvents stream on the home volume. Drop the
  current `kFSEventStreamCreateFlagFileEvents`; directory paths are enough.
- At each capacity sample, persist `lastEventId` and the volume's FSEvents
  UUID. On launch, replay with `sinceWhen` set to the stored ID, so sleep and
  restarts leave no blind interval. A changed volume UUID, or the
  `MustScanSubDirs`/`EventIdsWrapped` flags (already interpreted by
  `TargetedFSEventsCollector`), mark a gap. They never cause silent zeroes.
- Each changed directory is collapsed to its nearest object or project root
  and added to a capped **dirty set** for the current sample interval.
- When the volume shrinks by more than a threshold, or when asked, the dirty
  objects are re-measured within a budget. Their delta from the last measured
  size becomes the attribution, and `volume delta − attributed` is reported as
  unexplained. That remainder covers System Data, purgeable space, snapshots
  and anything out of scope.
- Agent sessions (the existing `AgentSessionRegistry`) intersect their working
  directory and time window with the dirty sets. That answers
  `get_task_impact` at directory and object granularity, with no per-file
  rows.

### C. Bounded review (explicit action, or a bounded MCP request)

- **Walk:** use `getattrlistbulk`. Prune at recognized objects with the
  existing `ObjectClassification` rules: 20 output names confirmed by manifest
  siblings, `CACHEDIR.TAG`, `pyvenv.cfg`, and the git-ignore oracle.
  Allocated sizes are summed in memory. **No file is persisted.**
- **Cache catalog** (new): uv, npm, pnpm, `~/Library/Caches`, CoreSimulator,
  Xcode DerivedData and Archives, ollama, Docker and actcache. Each entry
  carries a recreate class and the owning tool's cleanup command, for example
  `uv cache prune`, `xcrun simctl delete unavailable`, `pnpm store prune` or
  `ollama rm <model>`.
- **Recreate classes:** *rebuild from source* (`target`, `.build`, `.next`,
  `node_modules`, `.venv`), *re-download* (package caches), *expensive* (models,
  simulators, archives that hold dSYMs), and *live state* (`.git`, never a
  candidate).
- **Ranking:** size weighted by the project's last source activity. A
  4 GiB `target` in a project untouched for 90 days ranks above one built
  this morning.
- **Budgets:** 120 s wall time, 5 M entries visited, 256 MiB memory, utility
  QoS. Visiting more than 2× the previous review's entry count, or re-visiting
  a directory, triggers a stop. A stopped review produces a partial report that
  states its covered scope. The same scope then has a 24-hour cooldown, and
  nothing resumes after a relaunch.
- Items are revalidated against the live path before they are shown as
  present, as in the 09-23 doc.

## Invariants (enforced by code and tests)

These rules make the September failures impossible by construction.

| # | Rule | Test shape |
| --- | --- | --- |
| 1 | Capacity and health reads never open the detail store. | Delete, lock or corrupt the detail store: UI and `get_storage_summary` still return live capacity with `detail: unavailable`. |
| 2 | Every table has a hard row cap, enforced in the inserting transaction (oldest evicted). | Insert cap + 1 rows: count equals cap. |
| 3 | Every reader is windowed and returns `items ≤ limit`, `total` and `truncated`. Only a single oversized row may be refused. | Fill each table to its cap: every MCP tool answers under the 1 MiB response ceiling. |
| 4 | No per-file persistence anywhere. | Review a synthetic 1 M-file tree: persisted rows stay within the caps below. |
| 5 | Every job has wall, entry and memory budgets plus a convergence stop. There is no automatic restart or resume. | Feed an ever-growing or cyclic fixture: the job stops within budget and produces a partial report. |
| 6 | Idle cost is event-driven only, with no timer-driven walks. | 1-hour idle sample on this Mac: average CPU below 0.5% of one core. |
| 7 | MCP never starts unbounded work. `measure_path` is limited to 15 s and 500k entries, inside configured scopes, and joins a running review. | Call it on `localGit`: it returns partial within budget. |
| 8 | Total store size is bounded by the sum of its caps, so there is no storage pressure and no pressure retention. | Static check: the cap table times the maximum row size is at most the ceiling. |

## Data model and budget

| Store | Contents | Cap | Size |
| --- | --- | --- | --- |
| Capacity ring (own file) | volume, time, total, available, important-available | 2,016 fine + 8,760 hourly per volume, ≤ 4 volumes | < 1 MiB |
| Change journal | per-volume `lastEventId` and UUID; dirty set per interval | 2,000 dirty entries per interval (overflow collapses to parent), 7 days | < 2 MiB |
| Object index | path, kind, project, recreate class, allocated bytes, file count, measured_at, last source activity | 20,000 | ~8 MiB |
| Review reports | `ReviewReport` header and items | 20 reports × 2,000 items | ~16 MiB |
| Sessions | agent sessions and their dirty-object impact | 500 × 200 | ~4 MiB |
| **Total** | | | **≤ 32 MiB** |

This replaces a 512 MiB store that cannot hold one complete scan.

## MCP contract

| Tool | Fate |
| --- | --- |
| `get_storage_summary` | Kept and rebuilt on the capacity ring plus detail status. It cannot fail because of the detail store. |
| `explain_growth` | Kept. Returns the volume delta, attributed objects and directories, the unexplained remainder, and journal gaps. |
| `list_active_agent_sessions`, `get_task_impact` | Kept, now computed from sessions and dirty sets. |
| `export_evidence` | Kept. Exports the new store, and the legacy store read-only while it exists. |
| `find_cleanup_candidates`, `list_current_consumers` | Replaced by `list_review_items` and `list_largest_objects` over the latest report. |
| `get_evidence_lifecycle` | Replaced by `get_health`: stores, caps, last review, journal state. |
| `get_review_item_evidence`, `measure_path` | New. `measure_path` is bounded (invariant 7). This deliberately revises the 09-23 "no scans from MCP" rule; the budget is what makes it safe. |
| `get_provenance`, `list_active_writers` | `get_provenance` is listed only while the Endpoint Security bridge is active. The `list_active_writers` alias is dropped. |

## Keep and retire

**Keep (about 8k of 22k Swift source lines; 2k more under Rework):**

- `Snapshot/` for capacity and `ObjectClassification` with
  `GitRepositoryOracle` for the recognizers.
- `TargetedFSEventsCollector` for flag and gap interpretation. It changes to
  directory-level events with a persisted `sinceWhen`.
- `IPC/` and the `DiskStewardMCP` transport.
- `AgentIntegrations/` (install, verify, repair).
- `Sessions/`, `Privacy/`, `ResourceControl/`, notifications, settings, and
  the supervised test harness.

**Rework:**

- The evidence-bundle exporter. Its integrity and manifest layer stays, but
  its per-file payloads are rewritten around `ReviewReport`.

**Retire:**

- `DirectoryMetadataScanner`'s generation, frontier and staging machinery,
  plus `ScanPublicationFence`.
- `PersistentMonitoringProbe`'s continuous loop. It is replaced by the
  capacity sampler and a review job runner.
- The per-file schema: `current_file_state`, `path_bindings`,
  `file_state_observations`, `file_objects`, `scan_*`, and the
  event/hourly/daily tiers.
- `retention_runs`, `retention_coverage_gaps`, storage admission and pressure
  retention.

Most of `EvidenceStore/`'s 6.7k lines go. The replacement is a small store of
fixed-cap tables.

## Migration of the existing store

- On first launch of the new engine, stop the scanner. **Rename** (not modify)
  `evidence.sqlite` to `legacy/evidence-<date>.sqlite`, open it read-only, and
  use it only for export.
- Create the new store. Watched roots become review scopes, and the old
  percentage threshold becomes a suggested reserve (09-23 doc).
- Settings shows the legacy size (402 MB today) with **Delete legacy
  evidence…**, behind a confirmation. Nothing is deleted silently.

## Delivery ladder

Each rung is installable on its own and has one measured gate on this Mac.

| Rung | Delivers | Gate |
| --- | --- | --- |
| 1. Stop the bleeding (1.2.4) | Lockout fix (done on the hotfix branch). Capacity in `get_storage_summary` decoupled from the lifecycle summary. Non-convergence stop for the existing scanner (processed > 20× staged, or 6 h → abandon, say `scope too large`, no restart). | After install: helper self-check verifies, and app CPU averages below 2% over 15 minutes. |
| 2. Quiet guard (1.3) | Capacity ring, reserve alert, FSEvents journal with replay, dirty sets. Old scanner off; legacy store renamed. `explain_growth` lists changed directories (unmeasured). | 1-hour idle CPU below 0.5%. The relaunch replay covers the gap, and a journal reset is reported. |
| 3. Bounded review (1.4) | Walker, cache catalog, object index, `ReviewReport`, review window. Attribution upgraded to measured deltas. | The benchmark above, plus a synthetic 1 M-file tree that stops within budget with a partial report. |
| 4. Agents (1.5) | MCP tools and export on the report. Task impact from sessions × dirty sets. | Asked "what can I clean in `localGit`?", an agent gives the same numbers as the review window, and every tool answers with every table at its cap. |

## Limits to verify early

- **TCC:** check whether FSEvents reports changes inside Documents, Desktop
  and Downloads without Full Disk Access. If not, those scopes rely on review
  only.
- **FSEvents gaps:** journals are purged, event IDs wrap, and some volumes
  (network, some external formats) have no journal. Each case is reported as
  a gap, never as no change.
- **System Data, APFS snapshots and purgeable space:** these stay in the
  unexplained remainder. The app never claims to identify them.
- **Cold cache:** the 30 s benchmark was warm-cache. The 60 s gate must hold
  cold, or the budget stops the review with a partial report.

## Plan impact

If accepted, this design is the basis for a replan of `PLAN-DISK-STEWARD-006`.

- **Keep:** CONTRACT-601, RESEARCH-601, TASK-611 and TASK-612 (classification
  and pruning), TASK-616 (containment), TASK-617 (dashboard).
- **Rework:** TASK-613 keeps object rows but drops collapsing into per-file
  rows. TASK-615's always-on probe becomes the review job runner. TASK-614
  becomes rung 1's convergence stop plus rung 2. TASK-621, 622 and 623 map to
  rung 3, and TASK-631 is the cache catalog.
- **Drop:** OUTCOME-610's goal of always-on scans finishing on a real-sized
  scope is replaced by bounded review.

The replan itself, and every install or release, needs your approval.
