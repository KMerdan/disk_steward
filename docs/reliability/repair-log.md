# Reliability repair ledger

Baseline: `cf313e4527a3bd30dae217d2c1ff68d7a7a87b60` (2026-09-16 review).
User authorized implementation without Pyramid on 2026-09-17, with history reconciliation after verified repair.

The prior completion of `PLAN-DISK-STEWARD-004` remains historical; its affected assurance is now reopened. Its generated views were refreshed by `doctor` before this cycle; no product changes predated this ledger. The proposed `PLAN-DISK-STEWARD-005` was **not applied** because the runtime retained greenfield mode despite explicit brownfield selection. Do not retrospectively mark these repairs as previously verified.

## Checklist

- [x] R1 correctness patch: isolated smoke/test startup, exclusive app/socket lease, identity-checked unlink, legacy endpoint refusal, idempotent enable.
- [x] R2 reproduced defect: invalidate superseded staged membership and descendant cursors; keep per-slice metadata observation times distinct from publication.
- [ ] R3: healthy-root progress, continuation scheduling and honest freshness.
- [ ] R4: bounded frontier/enumeration/publication and headroom/maintenance recovery.
- [ ] R5: bounded IPC/CLI I/O, deadlines, cancellation and revocation.
- [ ] R6: complete configuration ownership, conflict-safe reversible mutations.
- [x] R7 correctness patch: bounded empty-safe decompression, throwing JSONL decode, shared fractional timestamp parser.
- [ ] R8: compact privacy-correct projections, opaque cursors, actual policy and typed errors.
- [ ] R9: exact configured-helper connectivity; honest optional session identity.
- [x] R10 correctness patch: epoch-fence late completion during pause/sleep/quit; preserve separate interrupted-process recovery.
- [x] Isolated full suite and unsigned Debug compilation for this correctness increment.
- [ ] Scale/soak, migration/rollback and packaged-candidate acceptance.
- [x] Reconcile this increment's evidence and remaining limitations through supported Pyramid history/lifecycle operations; full reliability closure remains open.

## Safety boundaries

Tests use synthetic files/configuration/sockets. Do not run the old unisolated UI smoke test. No real watched files, installed binaries, user evidence or agent configuration will be modified. No user-file deletion tool, budget increase to conceal pressure, implicit task attribution, release, commit or push is part of this cycle.

## Evidence

Record failing regression, implementation, passing checks, affected paths and limitations per repair below. An unchecked item is not verified. Accelerated virtual-time tests do not substitute for an overnight real-time soak.

## 2026-09-17 — First correctness increment

Status: implemented locally; **not installed, committed, signed, notarized, pushed, or released**. The large-scale reliability intent is not complete.

### Demonstrated changes

| Finding | Implementation | Regression evidence |
|---|---|---|
| R1 | Smoke launches always create private temporary state, use ephemeral preferences, pause detailed monitoring and leave Agent Access off. App and socket leases prevent cooperative duplicate owners. Unknown legacy endpoints are refused; stop unlinks only the owned inode. | `SocketOwnershipRegressionTests` originally failed on live endpoint replacement/removal (2 tests, 4 failures at 04:48 JST); now all 4 tests pass, including unsafe locks and socket deadlines. Final-product smoke asserts isolation, zero watched roots and MCP off. |
| R2 | A directory restart invalidates its prior staged subtree and obsolete queued descendants. Current-file timestamps use metadata sampling time, not generation completion time; old rows without that field use the conservative generation start. | `testRestartedDirectoryDoesNotPublishDeletedStagedFile`; existing A/B/C, scope-change, restart, hard-link and atomic-publication tests pass. An earlier test was updated because a deleted queued directory can now be correctly reconciled instead of abandoning the healthy root. |
| R3, partial | Unfinished detail gets duty-cycled continuation (at least 1 second, at least 4× the preceding sample duration), not a full five-minute delay each slice. A failed root does not discard completed healthy roots. Failed-root last-known rows become unknown, not deleted. UI no longer claims all file detail is current. | `testUnavailableRootDoesNotBlockHealthyRootOrProveDeletion`; explicit partial coverage, preserved last-complete timestamp and coverage-gap assertions. Separate volume/detail scheduling and a stalled-progress watchdog remain open. |
| R4, partial | Admission accounts for reusable pages, reserves publication space, and retention aims below the cap. Capacity eviction is limited to 8 batches per invocation. VACUUM checks temporary disk headroom; repeated pressure maintenance backs off. Current-state truth is not evicted. | Existing retention/admission/atomic-publication suites pass. Dedicated near-cap, long-reader and low-free-space fault matrices are still required. Unbounded frontier and quadratic enumeration are NOT fixed by this increment. |
| R5, partial | Socket request/response caps, nonblocking deadline-aware I/O, SIGPIPE protection, 4 default connections, endpoint revocation on Off, bounded MCP dispatch and cancellation bookkeeping. CLI pipes drain concurrently with finite output/deadline limits. | Socketpair deadline/oversize/disconnect tests; a 1 MiB producer completes without pipe deadlock; subprocess timeout/output-cap tests. Full process-isolated burst, cancellation and revocation stress still required. Off shuts down existing I/O and refuses new requests; it does not promise immediate interruption of computation already inside an evidence handler. |
| R6, partial | Malformed JSON containers/args fail closed. Relevant extra fields are fingerprinted for ownership without storing their values. JSON mutations recheck the document and receipt, retain unique private backups, and attempt rollback after receipt failure. CLI repair attempts restoration only if the entry remains missing. | Malformed-container/env-modification matrix and moved-helper tests pass; injected CLI add failure restores the original entry. Native multi-client/profile acceptance, concurrent uncooperative writers, all receipt-write failures and unsupported text-format fields remain open. Byte rechecks are not an OS-level compare-and-swap against uncooperative writers. |
| R7 | Shared bounded streaming decoder accepts a finalized empty stream, rejects truncated/corrupt input and enforces an output ceiling. Inline export no longer uses `try!`; fractional timestamps share the existing parser. | `ZlibRegressionTests`; 10 export tests including empty/large/manual export. Inline decoding stays capped at 8 MiB; the known large manual-export verification fixture explicitly allows 32 MiB. Apple's raw-deflate decoder accepts trailing padding; bundle hashes detect file alteration. |
| R8, partial | Query-bound, 10-minute opaque page tokens (at most 256); compact lifecycle status omits traversal queues and duplicate generation detail. App policy is injected; remote error codes survive IPC. | Opaque cursor/cross-query rejection/effective-policy test and read-model tests pass. Strong persistent query revisions and comprehensive pre-materialization bounds remain open. Text/structured duplication remains for compatibility. |
| R9, partial | Verification rejects a moved/missing configured helper before invoking the current one. Helper self-check now makes a real app-backed summary request. The optional session script uses the correct socket path, a caller/explicit ancestor PID and supports heartbeat. | Moved-helper false-verification test passes. Task registration remains explicit, separate from MCP initialization. Actual client approval/loading, evidence freshness and session-script lifecycle acceptance are not established by a helper self-check. |
| R10 | Epoch fences suppress late status/notification publication after Pause/Sleep/Quit. Sleep and shutdown prevent queued follow-ups. Deliberate quit clears the interrupted-process marker without changing the user's pause preference. Test safety state inherits the isolated settings store. | Deterministic gated-completion test for Pause/Sleep/Quit; existing sleep/wake and interrupted-start recovery tests. |

### Candidate checks

- `swift test --disable-sandbox`: **227 tests, 0 failures**, 11.485 seconds, 2026-09-17 05:22 JST. Log: `/private/tmp/disk-steward-repair-20260917-verified.log` (temporary, not a permanent artifact).
- Xcode Debug build: passed, `CODE_SIGNING_ALLOWED=NO`, separate derived data at `/private/tmp/disk-steward-repair-xcode-20260917`. This is compilation evidence, not distribution-signature or universal release acceptance.
- The first full run had 222 tests / 3 failures. It caught a default policy provider hopping to a blocked test main actor, the new inline-size limit being applied to a larger manual-export verification fixture, and an obsolete UI assertion that required the misleading freshness sentence. The provider was made async/injectable without a default main-actor hop; the fixture explicitly declares a finite manual-verification cap; the UI test now asserts measured coverage. The three suites then passed, followed by the full 227-test run.
- No production support directory, evidence store, watched root, agent configuration or installed app was mutated by these tests.
- Product-source whitespace checks are separate from generated Pyramid Markdown, whose current renderer emits trailing blank lines. Do not hand-edit generated history to hide that renderer detail.

### Open engineering acceptance

1. R4: persisted bounded frontier units, benchmarked enumeration alternative, resumable reconciliation preparation with atomic publication, resource checks during work, cancellation and WAL-reader pressure handling. No 100k/1M app-scale convergence claim is made.
2. R3: separately scheduled volume sampling, fairness/stalled-progress recovery and hot-root isolation.
3. R5/R6/R8/R9: adversarial IPC process tests, real-client/profile/configuration race and rollback matrix, stronger query revisions, allocation budgets before materialization, exact-helper/session end-to-end checks.
4. Scope changes must promptly remove newly excluded evidence from query visibility; this acceptance contract needs a dedicated regression and complete implementation review.
5. Full mutation matrix, synthetic upgrade/rollback rehearsal and real-time overnight soak before packaging/installing a candidate; signing and publication require their own authorized release step.

### Pyramid reconciliation

The history doctor reports a valid 9-record chain (5 chronicles, no pending transaction). The closed `PLAN-DISK-STEWARD-004` evidence did not cover these newly reproduced failures. Its prior completion report/chronicle remains unchanged.

The supported lifecycle `reopen` operation attached `repair-status.json` to `TASK-502`, producing `EVENT-20260916T202443412515Z-99B9F06D` at graph version **27**, context `CTX-0EED92996CAB92DB7ECCD44E2953049A`. The task is `needs-rework` / `failed` / `at-risk`; the plan is active. Its dependent `GATE-590`, `OUTCOME-420` and `INTENT-004` proof is no longer treated as verified, and closure is blocked. No task completion, audit pass, historical commit binding or release has been fabricated.

Broader scanner repairs remain explicitly outside that onboarding node and are tracked here until a new brownfield reliability intent is established. The unapplied PLAN-005 candidate is not an execution record. Future work should start from the open acceptance list above, not the historical completed report or its earlier 213-test result.

Post-reopen checks: `pyramid.py lifecycle --project <repo> --json` confirms the active, non-closable state; `pyramid.py history --project <repo> --doctor --json` reports `valid` with no errors. `git diff --check -- Sources Tests Scripts docs/reliability` passes.
