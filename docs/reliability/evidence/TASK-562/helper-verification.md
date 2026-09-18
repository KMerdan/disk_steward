# TASK-562 — Verified means the configured helper answered, and a session belongs to a live agent process

Actor: `claude` (TASK-562 taken after TASK-561's audit; amendment `AMEND-a305a58b…` for the doctor socket fix, guard `GUARD-TASK-44233EF787EA9CBD00688B2ED878E6EC`). Base: the pre-task isolated snapshot `ds552-check-v9fe28sb` (input `f987812c…`, the TASK-561 accepted candidate; copies of every changed product file in `base-source/`, delta in `helper-verification-source-delta.diff`, hashes in `helper-verification-source-manifest.json`). Final candidate input `5ecd49a31717…` (after the static review's F1 fix); the pre-review candidate was `019559cfa4a8…`. Nothing was committed, installed, signed or released; no real client configuration was opened. All runs are isolated verifier snapshots under `/private/tmp`.

## What changed

**Verification runs the configured command and trusts only its self-check report** (`Sources/DiskStewardApp/AgentIntegrations/`):

- `AgentCommand.inheritsEnvironment` (default `true` for setup/repair/remove commands) is `false` for the self-check: the runner spawns it with only `PATH=/usr/bin:/bin` and `HOME`, so an inherited `DISK_STEWARD_*` override in the app's environment cannot redirect the helper to another socket.
- `HelperSelfCheckReport` (`disk-steward-self-check-v1`: `helper.path`, `helper.identity`, `socket`, `app`, `evidence.observedAt/ageSeconds`, `error`) is parsed from the last report line of stdout; `HelperSelfCheck.evaluate` returns `failed` when there is no report, `failed` when `helper.identity` differs from the receipt's `helperIdentity`, `failed` for `app-off` / `access-off` / `insecure-socket` / `error` with the matching recovery sentence, `stale` when the app answered but the newest persisted observation is older than `staleEvidenceThreshold` (3 600 s) **or nothing has been persisted yet** (`evidenceAge == nil`, "no evidence has been persisted yet"), and `verified` otherwise. An exit code is never evidence.
- Both adapter families (`CursorJSONIntegrationSupport` for JSON clients, `CodexClientSupport` for CLI-driven clients) read the command the client's configuration actually names (`readDefinition()` / `mcp get`), require its executable identity to equal the receipt's identity **before** executing it, run `HelperSelfCheck.command(for:)` on that path, and record `verified` / `verified-stale` / `configured` on the receipt (`AgentVerification.stale(at:evidenceAge:)`, `AgentIntegrationStateKind.stale`); a failed test never stamps a verification. A moved or replaced helper is `broken` until Repair reinstalls the bundled helper, even when the process at the configured path answers.
- The helper (`Sources/DiskStewardMCP/main.swift`) answers `--self-check` by connecting to its socket, sending `initialize` and one bounded lifecycle query, and printing the report: its own executable identity (`dev:ino:size:mtime:ctime` of `Bundle.main.executablePath`, the same function the app uses), the socket path, `connected` / `app-off` / `access-off` / `insecure-socket` / `error` derived from the IPC error cases, and the age of the newest persisted observation read from `persisted_state_as_of`. The wire names are declared once in `StorageSummaryContract` (`Sources/DiskStewardCore/IPC/`) and used by both the app's `storageSummary()` and the helper, so the freshness field cannot be renamed on one side only (review finding F1: the first candidate read `observed_at`, which the real summary never carries, so `stale` could never occur in production). Neither `initialize` nor the self-check registers a session.

**Session contract** (`Scripts/Integration/session`, `doctor`, `docs/integrations/README.md`):

- `register` requires `--process-pid` (exit 64 without it); the process must be alive (exit 65 "is not running"), must not be the session command itself, and must be an ancestor of it (exit 65 "not an ancestor"); a wrapper shell is warned about. Refusals happen before any request reaches the app. The registration carries `process_pid`, and `heartbeat` carries `lease_seconds` explicitly; nothing is registered automatically from MCP traffic.
- The default socket is the app's own `~/Library/Application Support/Disk Steward/disk-steward.sock` in `session`, `doctor` (one-line fix, previously the misspelt `Support/DiskSteward/`) and `UnixSocketDiskStewardIPCClient.defaultSocketPath()`; `doctor --socket` now reaches the connector's self-check too (review observation).
- README documents Verify (verified / stale / not running / access off), `disk-witness-mcp --self-check`, and the `--process-pid` contract.

## Proofs (AC-TASK-562-01)

| case | test | evidence |
|---|---|---|
| exit 0 without a report is not verification | `HelperVerificationTests.testExitZeroWithoutASelfCheckReportIsNotVerification` | `failed`, state `broken`, receipt stays `configured` |
| a different helper answering is rejected | `testADifferentHelperAnsweringTheSelfCheckIsRejected` | a report carrying another executable's identity → `failed` ("A different helper answered the self-check"), `broken` |
| moved / replaced helper cannot become verified | `testMovedHelperCannotBeVerifiedEvenWhenTheNewHelperAnswers`; `AgentIntegrationHardeningTests.testReplacingHelperAtSamePathRequiresRepairBeforeVerification` | the configured path's identity differs from the receipt → `broken` until Repair; after Repair the bundled helper's report verifies |
| clean environment | `testVerificationRunsTheConfiguredCommandWithACleanEnvironment` | the self-check command has `inheritsEnvironment == false`, no `DISK_STEWARD_SOCKET_PATH`, and runs the configured path |
| app-off / access-off / stale / fresh are accurate | `testAppOffAccessOffAndStaleEvidenceAreReportedAccurately` | `app-off` → `broken` "not running"; `access-off` → `broken` "Agent Access is off"; evidence 7 201 s old → `stale`, receipt `verified-stale`; no persisted evidence → `stale` "no evidence has been persisted yet"; 90 s → `verified` |
| CLI clients verify what the client reports | `testCLIClientVerifiesTheCommandTheClientReports`; `CodexAndClaudeCodeAdapterTests.testVerificationRunsBundledHelperSelfCheckAndUpdatesReceipt` | the command from `mcp get` is identity-checked and executed; a user-changed command is `broken`, the bundled one verifies and stamps the receipt |
| helper self-check is real and never registers | `SessionContractTests.testHelperSelfCheckReportsItsIdentityAndNeverRegistersASession` | the built connector against a recording socket server answering with the exact `storage-summary-v1` shape the app publishes: report has the connector's path and identity, `connected`, evidence age > 3 600 s for the days-old `persisted_state_as_of`; with `persisted_state_as_of: null` the report says `persisted: false` and no age; no `sessions/*` method was ever sent; with the server stopped the report says `app-off`, with access off `access-off` |
| session requires a live ancestor pid | `SessionContractTests.testRegisterRequiresAnExplicitLongLivedProcess` | no pid → 64; a dead pid → 65; a live non-ancestor → 65, and no registration reached the server; the test's own ancestor registers and heartbeats with `lease_seconds` |
| canonical socket across entry points | `testDefaultSocketPathsAreCanonicalAcrossEntryPoints` | `session --dry-run` default, `doctor` source, and the IPC client default agree; the misspelt path is gone |

## Non-vacuity (mutation reds)

| mutation | run | result |
|---|---|---|
| identity check disabled (`report.helper.identity == expectedIdentity || !expectedIdentity.isEmpty`) | `identity-mutation-red/` (input `4ae9b8fa…`) | `testADifferentHelperAnsweringTheSelfCheckIsRejected` fails; 5 of 6 pass |
| self-check inherits the app environment (`inheritsEnvironment: true`) | `cleanenv-mutation-red/` (input `507c9314…`) | `testVerificationRunsTheConfiguredCommandWithACleanEnvironment` fails; 5 of 6 pass |
| `register` no longer requires or validates `--process-pid` | `sessionpid-mutation-red/` (input `8414cefb…`) | `testRegisterRequiresAnExplicitLongLivedProcess` fails; 2 of 3 pass |
| helper reads freshness from `observed_at` again (the pre-review defect) | `freshness-mutation-red/` | `testHelperSelfCheckReportsItsIdentityAndNeverRegistersASession` fails; 2 of 3 pass |

The first three reds were taken on the pre-review candidate `019559cf…` and repeated on the final candidate `5ecd49a3…` (`*-mutation-red-2/`).

Each run copied the candidate, applied only the named replacement in the copy, and left the worktree unchanged (`repositoryUnchanged: true` in result.json).

## Runs

- `app-suites-green/` — HelperVerificationTests 6, AgentIntegrationHardeningTests 6, RemainingClientsAdapterTests 10, CodexAndClaudeCodeAdapterTests 12, AgentIntegrationContractTests 6, AgentIntegrationsPresentationTests 4, ConfigurationOwnershipTests 10, MCPAccessTests 7: 61 tests, 0 failures (input `019559cf…`).
- `script-suites-green/` — SessionContractTests 3, IntegrationInstallTests 8, ConfigurationRollbackTests 10, DiskStewardMCPTests 7, MCPAdmissionTests 5, MCPTransportLifecycleTests 6, StdioBudgetTests 4: 43 tests, 0 failures (input `019559cf…`).
- `candidate/` — full fifteen-stage isolated verifier (six package stages plus the packaged unsigned app, architecture, smoke and helper stages) on the pre-review input `019559cfa4a8…`: all stages passed; 547 tests, 5 opt-in skips, 0 failures.
- Static delta review `HELPER-TASK-562-VERIFY-01` (`helper-verification-review-job.json` / `helper-verification-review-result.json`, performed on `019559cf…`): read-only, never final evidence. F1 (P1, freshness read from a key the app never publishes) fixed as described above; the doctor `--socket` observation fixed; the remaining observations accepted with rationale in the result file.
- `suites-green-2/` — after the F1 fix, both groups plus `EvidenceQueryScopeIPCIntegrationTests` (which pins `persisted_state_as_of` on the real backend): 110 tests, 0 failures (input `5ecd49a3…`).
- `candidate-2/` — full fifteen-stage isolated verifier on the final input `5ecd49a31717…` (see candidate.json for the counts).

## Limitations

- The in-app fixtures script the runner; the real helper's report is exercised by `SessionContractTests` through the built connector against a recording socket server, not against the running app.
- Ancestry is proven with the test process as ancestor and `/bin/sleep` as the bystander; the app-side kernel peer-credential check is unchanged by this task.
- Real installed clients are never touched; native lifecycle stays opt-in.
