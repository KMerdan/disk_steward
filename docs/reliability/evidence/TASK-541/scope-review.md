# TASK-541 — bounded IPC/MCP request lifecycle

## Accepted scope and identity

Six production files and seven test files changed relative to the frozen TASK-512 input (`9546220c27852fa5ce07726087db12e855e6b9818afacc2e063ad723595ba2b2`). The accepted input is `59a1e4eefad005610def6cc04dba836d3e04f98d53a9264c8546c1fb6fdab4f0`, built in `/private/tmp/disk-steward-541-accepted.uaJBzS`. See verification.json for hash scope, command, tests, and exclusions. No installed app, production evidence, real settings or client configuration was accessed by the regressions.

## Engineering boundaries

- One counted socket registry owns accepted descriptors and tasks until actual completion. A 25 ms watchdog independently revokes deadlines and full disconnects. Cancellation occurs outside the registry lock; only the worker closes an accepted descriptor. Off/On reuses the same service and cannot reset the budget around uncooperative work. Stop is the revocation boundary: it shuts down every admitted connection and advances the epoch; old work cannot publish a late reply.
- Poll waits run on a dedicated concurrent DispatchQueue, awaited through checked continuations. At most one operation per counted connection can be queued or executing. Tasks suspend rather than occupy the cooperative executor needed by monitoring. Default four connections, hard maximum sixteen, request cap 1 MiB and response wire cap 4 MiB remain unchanged.
- SQLite progress and busy callbacks observe the executing Swift task's cancellation. Statement wrappers reject interrupted prefixes; cancellation-safe rollback disables the hook temporarily and closes the connection if rollback fails. Backups step 128 pages at a time, finish exactly once, and close destination handles. Cancellation checks surround backend work, cursor wrapping, inline decoding and cleanup bookkeeping.
- MCP registers up to four request tokens synchronously before dispatch. Unknown/finished cancellation IDs do not create tombstones. Duplicate active IDs are rejected, including control requests. Cancelled tokens remain counted until workers finish. A locked terminal claim determines whether cancellation suppresses the reply; cancellation that arrives after completion cannot cancel a future reused ID.
- Stdio has one nonblocking writer, an inclusive 8 MiB/eight-frame queue budget and a two-second output deadline. A 4 MiB JSON payload plus LF is valid. Partial-frame failure ends the transport and cancels workers. Input remains responsive to cancellation while stdout is blocked; oversize lines are discarded without retaining more than 1 MiB. EOF has a one-second worker grace and finite output drain. Self-check uses the same bounded output path; SIGPIPE is ignored before either mode.

## Acceptance-to-evidence chain

| Acceptance condition | Executed evidence |
| --- | --- |
| Slow, idle and non-reading peers do not starve independent store work | RequestCancellationTests launches three private xctest subprocesses with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`; four admitted idle, partial-request or non-reading sockets coexist with a successful same-utility-priority EvidenceStore actor query within one second, while all four remain admitted. All three cases failed before the DispatchQueue bridge and pass afterward. This establishes cooperative scheduling, not an overnight whole-product throughput claim. |
| Actual cancellation releases work | Deadline/disconnect/stop observe cancellation after the handler begins; subsequent request succeeds. Real expensive SQLite evaluation is interrupted by socket deadline, and next query succeeds. Busy-wait cancellation, row-prefix rejection, transaction rollback, and backup-page interruption/recovery are separate assertions. |
| Revocation does not permit growing abandoned work | A deliberately uncooperative continuation remains counted across twenty stop/start cycles, replacement calls are refused, its late response is discarded, and capacity returns only after release. MCPAccessTests verifies one factory instance over twenty toggles and real private endpoint refusal when Off. |
| Protocol edges | Raw write-half-close receives a valid response; a full close with 1 KiB queued trailing bytes cancels actual handler work. These both failed with the earlier peek watchdog and pass using write-interest hangup polling. |
| Bounded input/output and request registry | Admission, StdioBudgetTests and real helper subprocesses exercise four-vs-five requests, unknown cancellation flood, active cancellation and ID reuse, all control-ID collisions, exact payload/newline boundary, byte and eight-frame caps, oversize line recovery, and both terminal-race winners. |
| Nonreading/closed stdout, EOF and SIGPIPE | Six disposable-helper tests prove blocked stdout still permits cancellation, output failure exits without further stdin, EOF cancels real backend work after finite grace, closed stdout exits normally with status 1 (not SIGPIPE), and self-check also exits when output is unread. |
| No unrelated regressions found by available suite | Accepted frozen input: 291 tests, one intentionally skipped native-client opt-in, zero failures. Full-suite log retained; this is not signed-release, scale or overnight acceptance. |

## Review corrections and negative oracles

Preflight review identified future-ID tombstones, serial output blocking and unbounded EOF waiting. Initial candidate review found the exact-payload/LF mismatch, control-ID collision gap, missing eight-frame and terminal-race proof, self-check's old blocking output, peek-based half-close/trailer confusion, and missing backup-interruption proof. All were reconciled into code/tests before acceptance. Older snapshots `6640fb5d...` and `ffeeab56...` are superseded, not final runtime evidence.

Coordinator acceptance review additionally found cooperative-pool starvation. An initial default-priority probe did not reproduce it; matching the service's utility priority exposed all three modes. `executor-red.log` is the corrected negative oracle. Similarly, `peer-red.log` uses the corrected 1 KiB-after-handler-start trailer fixture; an earlier oversized trailer attempt was not valid evidence. Intermediate failed experiments are not represented as passing checks.

Static helper reviews are separate from coordinator-executed runtime evidence. Final jobs/results and reconciliation retain the exact accepted snapshot and guard. The helper capacity was coordinator + two read-only helpers = three of four host slots; no graph-task workers or nested agents ran.

## Limits and remaining work

Cancellation is cooperative, not hard preemption of arbitrary synchronous filesystem work. Uncooperative handlers remain counted and may retain slots until they exit. TASK-551 still owns whole-export materialization limits and crash-orphan recovery; an interrupted backup's destination rollback does not prove artifact removal. TASK-542 still owns child-command lifecycle. Full UI monitoring throughput, 100k/1M scale, real overnight run, all native clients, migration/rollback and release packaging remain separate gates. No safety caps were raised. No material finding is closed solely from these tests.

## Post-implementation impact reconciliation

After implementation event `EVENT-20260917T015435374768Z-2E409DE1`, the unchanged accepted snapshot passed 60 scoped tests at 2026-09-17T01:54:53.346Z (`post-implementation-tests.log`). This refresh binds the two request/store inspections to the implementation event.

The runtime surfaced two honest mapping gaps. `Tests/DiskStewardCoreTests/SQLiteCancellationTests.swift` is explicitly allowed by the task but lies outside the baseline's narrower test-directory locator. Its six tests exercise SQLiteConnection and are manually mapped to existing `IMPACT-TASK-541-STORE`, supported by the test source and refreshed log. `Tests/IntegrationInstallTests/MCPTransportLifecycleTests.swift` matches the shared ASSET-CLIENTS locator; add `IMPACT-TASK-541-CLIENTS` plus a narrow subprocess-fixture inspection. That impact covers six isolated helper subprocess regressions, not adapter/configuration correctness or installed native-client acceptance. The generic runbook evidence files are declared evidence-only, not client or product behavior changes. No original material finding or broad control is resolved by this mapping.

## Primary engineering references

- [MCP cancellation](https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/cancellation): ignore unknown/finished IDs, stop work and release resources, suppress a cancelled response.
- [SQLite progress handler](https://www.sqlite.org/c3ref/progress_handler.html), [busy handler](https://www.sqlite.org/c3ref/busy_handler.html), [incremental backup](https://www.sqlite.org/c3ref/backup_finish.html): cooperative interruption, lock retry replacement rules and exactly-once backup finish/rollback.
- [Apple: Visualize and optimize Swift concurrency](https://developer.apple.com/videos/play/wwdc2022/110350/) and [Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/): blocking I/O can exhaust cooperative workers; suspension is required for forward progress. The private constrained-executor regression validates this risk for the actual implementation.
