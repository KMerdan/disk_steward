# TASK-664: transient process inspection in the supervisor

Candidate input `03e80c743d0ce97b1e6c5dd49d0b0670fc4cf6452d49efd421fb60815490947b` (on main after `dd16250`, replans R9 and R10).
This is the 1.5.0 (12) candidate input. Nothing has been installed or
published.

## Why

The verification supervisor (`Scripts/Testing/process_supervisor.py`)
inventories every process owned by the current user, not only its own
descendants. It used to fail the run as soon as one new process could not be
inspected at that instant:
- `Cannot classify new process … (errno 0)`: its arguments were unreadable,
  usually because it was mid-launch;
- `Cannot establish process identity`: its metadata was unreadable.

Ordinary activity on this Mac produces about one such process every few
seconds: the desktop app polling `git`, `rg`, and the user's own commands.
On 2026-10-05, 12 of 13 verifications of the 1.5.0 (12) input stopped on
the race, at the build, tests and package-build stages. That is
FIND-R4-SUPERVISOR-RACE.

## Change

- `ProcessTable.snapshot()` lists a process it cannot inspect in
  `unreadable` instead of raising. Such a process is never counted as
  inspected.
- `Family.discover()` retries an unreadable process, and one whose
  classification failed, on later polls (every 25 ms). The run fails with
  the same errors as before only when the failure lasts
  `INSPECTION_GRACE` (2 s) while the process lives.
- Processes that were already unreadable before the launch are not waited
  on.
- Unchanged: ownership by recorded parent lineage (which never depends on
  reading a process's arguments), the run marker, PID-identity rechecks
  before every signal, and cleanup verification.

## Evidence

| Run | Result |
| --- | --- |
| Unit tests | `python3 -m unittest test_process_supervisor`: 14 tests pass. The harness stage of every candidate verification also runs them |
| `no-grace-red/` | Failing at once on a momentary failure fails the three transient and persistent tests |
| `never-fails-closed-red/` | Ignoring a lasting failure fails the two fail-closed tests |
| `waits-on-pre-run-processes-red/` | Waiting on processes unreadable before the run fails `test_processes_unreadable_before_the_run_are_not_waited_on` |
| `inventory-raises-red/` | Raising on one uninspectable process fails `test_the_inventory_reports_uninspectable_processes_instead_of_failing` |
| `consecutive/` | Three consecutive `verify_candidate.py --xcodegen` runs on this input with the Mac in ordinary use, no retries: **no supervision race** (before the fix, 12 of 13 runs on the 1.5.0 input stopped on it). Runs 1 and 2: 727 tests, 0 failures, the packaged CI app built (exit 0; the retained Xcode worker stopped with cleanup verified, FIND-R4-XCODE-WORKER). Run 3: 727 tests with only the known `ObjectConvergenceTests` seed race in the retired scanner path (FIND-R4-OBJECT-CONVERGENCE-FLAKE) |

The reds run the unit tests on a mutated copy of `Scripts/Testing` in
`/private/tmp`; the repository is never modified.

## Limitations

- A process of the run that stays unreadable for less than 2 s is not
  counted in that interval's memory sample. The sampled footprint was
  already approximate between polls.
- A process that is unreadable both before and after the launch is not
  waited on. Process IDs are compared, so in principle a reused PID could
  hide one; ownership by lineage still applies to it.
- `SUPERVISION.md` is unchanged. The grace is documented in the code
  comment beside `INSPECTION_GRACE`.
