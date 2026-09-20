# Verification containment (TASK-616)

Do not run Swift tests in the developer checkout or point tests at live evidence.
The focused/mutation and candidate/package runners copy an exact source manifest
into a private temporary directory. `verify_candidate.run_command` now imports
the single implementation in `process_supervisor.py`; there is no process-group
fallback.

## Contract and bounds

- Root starts behind an execution gate. Register its kernel birth identity before
  allowing the tool to execute. Retain original-parent identities across parent
  exit, reparenting and process-group/session changes.
- A random inherited run marker identifies surviving children of intermediates
  that exit between polls. Inspect only new same-user candidates, discard their
  arguments/environment immediately, and never print those values. Unknown
  inspection/measurement failures stop the run, not silently report zero.
- Measure the sum of `proc_pid_rusage(..., RUSAGE_INFO_V0).ri_phys_footprint`
  across owned live identities, not process-group RSS. Default aggregate stop
  threshold is **2 GiB**, at most **64 live processes**, **8 MiB output**,
  **1 second TERM grace** then KILL and a bounded fresh-inventory exit check.
- Each caller must supply a finite wall limit. Builds default to 600 seconds,
  full tests 300, focused/mutation 1800; no call may exceed 3600 seconds, 8 GiB,
  128 processes or 64 MiB output. Prefer narrower per-suite limits. Swift uses
  two compilation jobs. These are stop thresholds, not target consumption.
- Timeout, excess memory/output/processes, cancellation, telemetry failure and
  early launcher exit with live descendants fail the run and enter cleanup.
  A zero launcher exit or EOF is not cleanup proof. Reports include identities,
  signals, budgets, peak, errors, remaining processes and `cleanupVerified`.

This is containment for reviewed, cooperative direct process trees, **not a
security boundary for hostile source**. Do not run a program that delegates to
launchd/XPC, intentionally hides its lineage, or strips its run marker before
an unobserved multi-generation daemonization. Use a disposable VM for such work.
Apple's fork-event tracking flags are unsupported on current macOS; original
parent IDs cannot reconstruct already-reaped unseen ancestors. Physical memory
is sampled and can overshoot between polls. PID identity is rechecked before
each signal, but check-then-kill is not an atomic birth-ID-targeted kernel call.
Private identity API layout/support is checked before admission; unsupported
platforms fail closed. These limitations must travel with the evidence.

## Bootstrap before Swift

Run `PYTHONDONTWRITEBYTECODE=1 python3 Scripts/Testing/bootstrap_supervision.py`.
Its separate watchdog allows at most 20 seconds per fixture plus a bounded
cleanup wait; each fixture arms a 12-second terminal alarm, forks at most once,
and allocates at most 64 MiB. No old Swift hang or multi-GB allocation is used.
It covers session escape, parent exit, retained stdout, TERM refusal, missing
measurement, memory/output/time bounds, cancellation and identity mismatch.
An unrelated sentinel must survive, and a second observer checks fixture birth
identities after each run. A bootstrap failure does not authorize Swift tests.

After it passes, run the snapshot harness with `AboutVersionTests 240` before
focused or full suites. Record source hash and the supervisor report, not just
the XCTest result. Do not inherit credentials or profiling/stack-logging flags.

## Entry-point inventory

| Entry point | Admission |
| --- | --- |
| Candidate harness, toolchain, manifest, build, tests, git metadata | Shared supervisor |
| Packaged XcodeGen/Xcode/build/inspection, isolated app smoke/MCP | Shared supervisor |
| Focused and mutation harness | Shared supervisor; mutation paths confined to snapshot |
| Legacy soak, rollback rehearsal, object-scale fixture builder | Refused before any work |
| Legacy corpus-measurement CLI | Refused before any work |
| Five explicit Swift scale/soak opt-ins | Fail before fixture/store access; ordinary runs still skip them |

The refused paths need supervised fixture construction, storage quotas and a
live supervisor handshake before re-enabling. Historical passing scale/soak or
rollback reports are not evidence about this candidate. No release/scale gate
may claim those scenarios were rerun. Low-cost source-only rule inspection is
unaffected; do not import a legacy worker to bypass its CLI refusal.

Sources: local Xcode SDK `sys/resource.h`, `sys/event.h`, and Apple XNU
[process identity](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h),
[original-parent identity](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_internal.h),
[resource usage](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/resource.h).
