# Reliability foundation — observed baseline and safety contract

## Identity and scope

Assessment: 17 September 2026 JST. Canonical work is PLAN-DISK-STEWARD-005. Starting source is dirty `cf313e4527a3bd30dae217d2c1ff68d7a7a87b60`, with Sources/Tests/Config/Scripts/Xcode aggregate SHA-256 `8c8c8aa07395c51f4e1e88bb0929e30cc772c180c72f9fd864b73d253b21a5d7`. Frozen source: `/private/tmp/disk-steward-candidate.LsZIbw`. The source hash was recomputed for both trees and matched. Earlier patches are inputs requiring appropriate current acceptance, not automatically passed PLAN-005 tasks.

PLAN-004 graph 34 reclosed after 238 tests, unsigned Xcode build and seven embedded-helper integration tests. It is now archived at `.pyramid/archives/PLAN-DISK-STEWARD-004-R1-G35-20260916T233322Z`. The installed Pyramid runtime validates the brownfield transition and an 11-record, six-chronicle ledger with no pending transaction. Exact Git binding remains pending. No install, signing, publication or production-state mutation is part of this foundation.

## Observations, not completion claims

- The user's supplied incident account described 19 MB to 40 GB in 98 seconds, earlier 78–81 GB pressure, and a forced restart. These figures are **reported**, not independently remeasured here; deliberately reproducing OOM is prohibited.
- `docs/incidents/evidence-database-budget-deadlock-2026-09-16.json` records a 1638 MiB database, 4,398,152 history rows and foreign-key retention failure under a 512 MiB default cap. Current source includes recovery fixes; near-cap and rollback behavior must be tested on the final candidate.
- `DirectoryMetadataScanner.scanSlice` retains a frontier array; appending discovered directories can grow independently of the 512-entry slice. `boundedDirectoryBatch` reopens and enumerates the whole directory per lexical batch. `EvidenceStore.reconcileCompletedScanGeneration` still loops inside one publication transaction. These are current scale risks, not resolved by a bounded returned array.
- `PersistentMonitoringProbe.sample` combines capacity sampling, detail, reconciliation and retention. The lifecycle now requests continuations sooner, but independent volume scheduling, fair stalled-root handling and bounded work interruption still require proof.
- `AppEvidenceQueryBackend.init` sweeps children of shared `DiskStewardIPCExports` before opening its database. Fixture databases do not isolate that cleanup. This confirmed safety defect belongs in TASK-511 before further full-suite execution.
- `SnapshotIncrementTests` can remove an environment-selected `export-fixture`; capture tests write fixed filenames to an inherited directory; the packaged-helper assertion does not throw before executing an invalid override. These must be confined before execution, including canonical-path and symlink escapes.
- Non-smoke support-directory override alone still leaves production preferences, roots, integrations and notification defaults. Smoke does use ephemeral preferences, paused empty roots, no collector and no integration descriptors, and `main.swift` removes its generated directory. Full process-level sentinel preservation remains missing.
- The lifecycle's omitted safety-state parameter already inherits `settingsStore.persistence`; that is **not** a remaining standard-preference leak when settings are ephemeral. Some lifecycle tests still rely on real notification defaults, and the circuit-breaker test supplies real-home default roots; replace those conditional escape routes.
- Weak count/max-date query revisions, pre-materialization allocation bounds, exclusion visibility, native approval UX and real session lifecycle remain explicit inspection questions. No false claim that setup establishes writer attribution is permitted.
- The distribution runbook predates the standard non-Endpoint-Security app target. Keep signing/notarization checks; do not infer that an Endpoint Security grant is mandatory for the standard app from that stale document.

## Isolation contract for all remaining execution

1. Use a fresh owned temporary fixture or disposable source snapshot. Test writes, databases, settings, receipts, roots, exports and endpoints must resolve inside that fixture (after symlink resolution), or use explicit in-memory fakes. Never point a test at installed application support, real agent profiles, user Documents/Downloads, or a live socket.
2. Pass explicit test dependencies for preferences, roots, notification delivery, FSEvents, export staging, access state and helper endpoint. A support-directory override is not sufficient. Clear or validate inherited output/profile/helper variables before executing anything that can write or spawn. Unsafe inputs must throw **before** execution, replacement or removal; XCTest assertions alone are not a guard.
3. Seed fake-production sentinel files and a live fixture socket beside the test target. Record byte hashes, inode/mode and endpoint liveness before/after; no check should read or alter actual personal state. Unknown endpoints must not be probed or removed. Cleanup may remove only paths created and still owned by that fixture/instance.
4. Default foundation tests use recording clients only. Real installed-client tests remain opt-in with isolated documented profiles, cwd and socket; preserve unrelated profile sentinels. No credentials, model calls, unsolicited notifications or implicit MCP enablement.
5. Do not rerun the full suite until TASK-511 isolation and TASK-512 ownership acceptance pass. Targeted validation that could trigger the shared sweep also waits for its fix. Static inspection and fixture-only harness checks may proceed.
6. Freeze candidates before tests. Record exact commands, environment, hashes, actual results and limits. Do not silently compare an older frozen candidate against new source. No production rescan or deliberate resource exhaustion.

## Data and API invariants

- No deletion of monitored user files; cleanup remains review leads plus live revalidation, and MCP remains read-only.
- Absence under complete validated coverage differs from unknown, denied, offline, excluded, interrupted or stale. Preserve last-known observations, real observation intervals and explicit provenance confidence.
- Queries do not trigger scans. Scope changes must immediately constrain visibility without claiming a scan completed. Cursor revisions must detect relevant changes even when row counts and maximum timestamps do not change.
- Current truth, historical detail, scan staging, session leases, temporary exports and user exports have separate lifecycles. Retention cannot fabricate deletion or discard current truth to satisfy a cap; report precision loss before evicting history.
- Bound work **before** allocation and throughout processing, including directory frontier, reconciliation, export views, connections, subprocess output, registry waiters and cancellation state. Preserve default 150 MiB RSS and 512 MiB DB limits; capacity refusal must be honest, never a false completed scan. Refusal does not satisfy the required 100k/1M convergence benchmarks; do not mark scale acceptance passed by refusing the intended workload.
- Pause/sleep/quit and Agent Access Off have distinct semantics. Cancel actual backend work, not merely its response. Independent capacity observations should remain useful while detail is partial or backed off.

## Inspection and acceptance plan

`assurance.json` maps every executable node to narrow impacted assets and a required inspection. Findings stay open until their actual evidence exists. The foundation inspection evaluates this **contract/inventory**, not product correctness. Later task and gate inspections must be performed after their implementation frontier.

| Work | Required inspection / evidence | Recovery boundary |
|---|---|---|
| TASK-511/512, GATE-519 | Sentinel smoke, export-instance isolation, hostile environment/path rejection, endpoint inode/liveness, stale-owner and duplicate-start matrix | Disposable runtime context and owned instance paths only |
| TASK-521/522, GATE-529 | A/B/C create/grow/shrink/delete/replacement/rename/link/exclusion/denial/gap/restart matrix; pause/sleep/quit fences | Old committed view survives incomplete work |
| RESEARCH-530, TASK-531/532, GATE-539 | Measured 100k/1M wide/deep/hot/multi-root work: re-enumeration count, progress, RSS/CPU, descriptors, allocated/live/reusable DB pages, WAL and headroom; bounded near-cap recovery | Consistent DB backup; no current-truth eviction; no destructive live migration |
| TASK-541/542, GATE-549 | Real isolated IPC/MCP slow/nonreading/disconnected peers, backend cancellation, Off, stdout/stderr flood, fast exit, spawn failure and descendant cleanup | Close only owned sockets/children; monitoring stays independent |
| TASK-551/552, GATE-559 | All ten tools/two resources through real fixture IPC; empty/corrupt/truncated/limit exports, privacy, strong cursor revision, effective policy and immediate exclusions | Own temporary files only; preserve user exports and DB truth |
| TASK-561/562, GATE-569 | Complete-entry ownership; failure at each mutation; exact helper query; real lease/register/heartbeat/expire/end; client-owned approval preserved | Exact owned-entry rollback, refuse observed conflicts; no shared profile replacement |
| TASK-571/572, GATE-579 | Credential-free CI, exact packaged candidate, synthetic migration/rollback, real wall-clock overnight with lifecycle/retention/query load; no virtual-time substitute | Separate protected release; prior compatible binary plus consistent backup |

Each gate repeats inherited scenarios on its current candidate. Final inspection resolves remaining scale, migration and overnight findings; a historical 238-test pass or accelerated 72-hour-equivalent test cannot replace those checks.

## Rollback and monitoring controls

Development rollback is ready only within disposable snapshots: canonical user changes remain untouched, fixtures and backups are kept under their unique owner directory, and production stores/profiles remain unopened. Restore code by explicit reviewed patch/revert rather than reset/checkout over user changes. Do not claim production rollback readiness yet.

Before any storage migration is accepted: create a SQLite-consistent backup from a synthetic old schema (include committed WAL via SQLite backup, not a loose main-file copy); validate integrity; inject interruptions before/after copy, validation and atomic switch; demonstrate old-binary compatibility with the untouched backup in a separate directory. Preserve the original fixture and never open a newer schema with an older binary in place. TASK-572/GATE-579 owns the measured rehearsal.

Before any unattended scale or soak execution: use a fixture-only supervisor with explicit process handles, time and storage quotas, bounded log rotation, RSS/CPU/FD/queue/WAL/export measurements and an external stop threshold. Check progress, not only lack of crashes. Stop fixture children promptly on a breach and record refusal/backoff/coverage rather than exhausting host memory. This supervisor and final overnight evidence are **not yet implemented**, so the monitoring control remains missing in canonical assurance until demonstrated.

Foundation completion authorizes scoped isolated repairs, not installation or release. Production rollback and final monitoring remain blocked until their later evidence exists; the baseline can be current while the product remains unsafe to release.
