# TASK-542 — bounded owned command execution

## Scope and source identity

Accepted source copy: `/private/tmp/disk-steward-542-accepted.xRV6DE`.
Aggregate input SHA-256: `57dd89b23864d4115dd909bd224db2eaa0f92f0a56f55de119c205bf6f20324a`.
The verification manifest defines the hash inputs; Extensions are copied and compared separately.

Only three product/test files differ from the accepted TASK541 snapshot:
- AgentIntegrationInfrastructure.swift: typed admission-limit and incomplete-cleanup errors.
- CodexClientSupport.swift: single-owner spawned command lifecycle, bounded pipes/admission/deadlines.
- CommandRunnerRegressionTests.swift: 13 scoped regressions and finite synthetic fixtures.

No app installation, real client configuration, production evidence, signing, publishing or Git mutation was performed.

## Engineering invariants

The runner creates its process group atomically with posix_spawn. One GCD worker owns the PID, descriptors, reads, group signals and exact-child reap; Swift cancellation only sets a latch. Read EOF means zero bytes, not EAGAIN/EINTR. Both pipes get fair 64KiB quanta; their combined captured data is capped (default 2MiB, maximum 4MiB). This is intentionally tighter than the old per-stream allowance.

The unreaped leader anchors the PID/PGID until the last group signal. TERM gets 150ms grace before KILL. A descendant seen in the group requires the KILL phase before a zombies-only probe can establish completion, avoiding a fork/exit race between enumeration and status inspection. Never signal after ECHILD or successful reap. Only the owned group is queried; no global process enumeration or name-based killing occurs.

A cancellable watchdog bounds the caller even if spawn preparation or OS cleanup stalls. Completion is delivered once outside the invocation lock. The worker/admission slot remains retained until cleanup actually finishes; a returned error does not release ownership. Four admitted workers globally bound exceptional cleanup. The timer is cancelled on completion, avoiding accumulation of completed-command watchdogs. Spawn begins only if cancellation/deadline checks still permit it; successful spawn is always owned even if cancellation raced it.

stdin is /dev/null, executable arguments/environment and working directory are preserved without process-wide chdir. Unrelated descriptors close at exec. Group probes use proc_listpgrppids' PID count, not proc_listpids' byte count; this was corrected against Apple's source after a failing development run.

## Acceptance-to-evidence mapping

| AC-TASK-542-01 requirement | Accepted regression |
| --- | --- |
| 1MiB stdout and stderr; fast exit/status preserved | testDrainsOneMiBFromEachPipeAndPreservesFastExitStatus; exit7 and exact byte counts |
| Pipe capacity and EOF vs temporary lack of data | testDrainsMoreThanPipeCapacityWithoutDeadlock; testEnvironmentWorkingDirectoryStdinAndDelayedOutputArePreserved |
| Parent exits before descendant; child retains or closes pipes | Both testParentExit variants; TERM-ignoring closed-pipe child included |
| Cancellation, TERM resistance and direct-child reap | testCancellationStopsTermIgnoringChildAndItsDescendantBeforeReturning |
| Cancellation just before/after spawn | testCancellationAtBothSpawnBoundariesHasOneCompletionAndReapsOwnedLeader; ten repetitions of each boundary per run |
| Never-exit and huge output stop owned group | testHugeOutputAndNeverExitStopAndReapTheOwnedProcessGroup; finite head/sleep producers |
| Output/time limits and spawn failure | testTimeoutAndOutputLimitsAreEnforced; testSpawnFailureAndAlreadyCancelledCallRecover |
| Global admission and exceptional cleanup ownership | testFourOwnedCommandsAreCountedUntilCleanupAndRefuseAFifth; four stalled owners stay counted after watchdog return |
| Deadline includes spawn preparation | testSpawnDelayIsIncludedInOverallDeadlineAndDoesNotLaunchAfterExpiry |
| Descriptor and zombie cleanup over repeated calls | testRepeatedSuccessAndSpawnFailuresDoNotLeakDescriptorsOrZombies; 50 success/failure pairs and non-reaping waitid/ECHILD checks |

The initial six-test run failed two live-descendant assertions on the old runner (runner-red.log). Final tests use stronger/safe fixtures: no raw signalling of historical PIDs, no unbounded yes process, inspection errors cannot masquerade as absence, and ECHILD proves direct-child reap. The final 13-test suite passed five consecutive times. One complete accepted-candidate run executed 302 tests, one native-client opt-in skip, zero failures.

## Review and residual risk

Independent static review found two test-safety/oracle issues, both corrected and re-reviewed at the accepted hash. See the helper envelopes and reconciliation. Helper review is not presented as independently executed tests.

Process groups are not adversarial containment. A descendant deliberately escaping with setsid/setpgid is outside this runner's group guarantee. Signal permissions and OS scheduling/kernel cleanup can delay termination; the caller receives a bounded incomplete-cleanup error while ownership/capacity remain retained. macOS13 and Intel were not exercised here (host macOS15.6.1 arm64, Swift6.2.4). No global child-reaper/SIGCHLD auto-reap is installed by this source; adding one would invalidate ownership proof.

## Discovered endpoint ordering failure (unresolved)

An intermediate candidate's full suite failed `DiskStewardEndpointTests.testFixtureRuntimeFiltersNormalizesAndDeliversWithoutAuthorizationEvents`: confidence was unknown rather than exact (endpoint-order-failure.log:370). Endpoint source and its test did not change in TASK542. Ten separate scoped runs on the pre-TASK542 snapshot passed; this does not disprove the intermittent failure.

Static inspection identifies an ordering hazard: Extensions/DiskStewardEndpoint/EndpointSecurityObserver.swift:43 creates an independent unstructured Task for every sequential runtime callback. ProtectedEndpointBridge.swift:28-30 checks sequence in actor arrival order. If excluded sequence2 reaches the actor before sequence1, the latter is incorrectly marked discontinuous. A fixed 20ms test sleep also does not establish deterministic delivery. This causal explanation is an inference, not yet a deterministic reproduction.

Keep the failure open for a bounded ordered-delivery/lifecycle regression and repair. Do not accept a subsequent green run as resolution. This is outside TASK542's declared product scope and must be mapped into the remaining reliability graph before final closure.

## Primary references

- [Apple libproc wrappers](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c): proc_listpgrppids returns a count of PIDs.
- [Apple process-group spawn attributes](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/posix_spawnattr_setpgroup.3.html).
- [Apple wait implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exit.c): WNOWAIT and WNOHANG handling.
- The preflight helper result preserves additional Apple/Swift references. These support API choices, not a claim of arbitrary descendant containment.

