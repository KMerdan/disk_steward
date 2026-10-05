# TASK-712: Xcode's ibtoold daemon is expected in verification

This task resolves FIND-R4-XCODE-WORKER, which was accepted at the close of
PLAN-006.

## What the leftover process was

Every packaged and archive build ended with
`launcher-exited-with-descendants`: `xcodebuild` exited 0 but left one
process behind, which the supervisor then stopped with cleanup verified.

Running the same CI `xcodebuild` and comparing the process list before and
after identified it:
- `/Applications/Xcode.app/Contents/Developer/usr/bin/ibtoold --sending-client-environment`;
- the Interface Builder tool daemon that asset catalog compilation starts;
- re-parented to `launchd`;
- still alive 10 s after `xcodebuild` exits.

It is a deliberate Xcode daemon, not a leak in the build.

## Change

- **The allowance** (`Scripts/Testing/process_supervisor.py`).
  `run_command(..., expected_descendants=...)` takes absolute executable
  paths that may outlive a launcher which exited 0.
  - Each survivor's executable is read with `proc_pidpath`, with an identity
    recheck, through `ProcessTable.executable`.
  - Only when every survivor is on the list is the stage left unfailed.
  - The survivors are still stopped and their cleanup verified like any
    owned process, and the report lists them in
    `supervision.expectedDescendants`.
  - The stage still fails for any other survivor, a survivor whose path
    cannot be read, a relative allowance, or a launcher that failed.
- **The packaged build opts in** (`Scripts/Testing/verify_packaged_candidate.py`).
  Only the `package-build` stage does, and it passes the selected Xcode's
  `usr/bin/ibtoold` (from `xcode-select -p`). Every other stage keeps the
  default empty allowance.
- **Documentation.** `Scripts/Testing/SUPERVISION.md` documents the exception.

## Evidence

| Evidence | Result |
| --- | --- |
| [`green/tests.log`](green/tests.log) | `test_process_supervisor`: 18 tests pass, including four new real-process tests. In those, a launcher leaves a detached `/bin/sleep`. It passes with `/bin/sleep` allowed, and fails without the allowance, with another executable allowed, with a failed launcher, or with an unreadable or relative path |
| [`reds/`](reds/), specs in [`mutations/`](mutations/) | `allowance-ignored` fails `test_an_allowed_daemon_is_stopped_and_the_stage_passes`. `any-survivor-allowed` fails the other-executable and unreadable-path tests. `failed-launcher-allowed` fails the failed-launcher test. `relative-path-allowed` fails the relative-path test |
| GATE-719 full verification | The packaged build stage passes with `ibtoold` in `expectedDescendants`, recorded at the gate |

The reds run the unit tests on a mutated copy of `Scripts/Testing` in
`/private/tmp`; the repository is never modified.

## Limitations

- The release archive stage runs from the out-of-tree release script. That
  script opts in the same way, but its evidence lives with the 1.5.1
  release record.
- If a future Xcode leaves a different daemon, that stage fails again until
  the daemon is identified and named. This is intended.
