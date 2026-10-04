# GATE-649: rung 1, live capacity and a self-stopping scan

Exact candidate: committed input `887d62f1b8f523965103606ef9c4dbd430a53fff54b721cb3c3648028225eb7d`
(main `062a8d5` + `f70c820`), released and installed on the maintainer's Mac
as **Disk Steward 1.3.0 (10)**. The release was authorized by the user's
decision to ship main as 1.3. Nothing has been pushed, tagged or published.

## 1. Constructability and packaged candidate

- **Full supervised suite.** `verify_candidate.py --xcodegen` on `887d62f1`
  ran 618 tests: 7 intentional skips, 0 failures
  (`candidate-887d62f1/candidate.json`, `tests.log`).
- **Packaged CI build.** It ended with xcodebuild exit 0, but one Xcode worker
  outlived the launcher. The supervisor sent TERM and verified cleanup, so the
  stage is recorded as `launcher-exited-with-descendants`, not as a pass. This
  is the same pattern as the 1.2.2 and 1.2.3 releases (FIND-R4-XCODE-WORKER).
- **Signed release archive** (`build/releases/1.3.0/verification-10/`, local,
  ignored):
  - the archive exited 0, with the same retained worker stopped and cleanup
    verified;
  - signature verification, Developer ID identity and universal
    arm64 + x86_64 app and helper pass;
  - the signed-app isolated smoke and the helper protocol transcript pass.
- **Notarization.** Uploaded once; Apple accepted it and `-exportNotarizedApp`
  succeeded on the first check. `verify-release` passed on both the exported
  app and the ZIP-unpacked app: staple, Gatekeeper, entitlements and installed
  launch. `Disk-Steward-1.3.0.zip` SHA-256:
  `7d1d894106931ed6fe34177a19aa55da0e9b90fa6549874f2b3d48004c050657`.

## 2. Captured live store (AC-GATE-649-01)

A read-only `.backup` copy of the live store was taken on 2026-10-04, at
schema 14, with 488.96 M processed and 122,862 staged files. On first open in
an isolated snapshot (`CapturedStoreConvergenceTests`):

- it migrates to schema 15 and stops the stuck generation with
  `processed-far-beyond-staged`, attempting no slice;
- all 44 observations are retained, and the lifecycle summary answers;
- later stopped samples cost 0.4 ms of CPU each (65 ms without the cache;
  that red is archived under TASK-614).

The fault matrix (missing, corrupt, summary refused, over cap, locked)
returns live capacity in every case (`StorageSummaryDetailFaultTests`, inside
the full suite). The built helper's `--self-check` connects through a refused
summary (`SelfCheckDetailFaultIncrementTests`).

## 3. Delivery environment: the installed app on the real store

**First install, 1.3.0 (9)** (`installed-1.3.0/`):

- The live store migrated to schema 15. The stop fired for generation
  `scan-generation-e394ea04…` (489,275,944 processed), and staging was
  discarded (`scan-convergence.json`, `live-store-after.txt`).
- `get_storage_summary` and `get_evidence_lifecycle` answered from the Claude
  Code session. Both had been refused under 1.2.3. The lifecycle listed the
  newest 128 of 1,482 retention gaps, and coverage was `partial`.
- The installed helper's `--self-check` reported `connected`, with evidence
  honestly 21 days old (`self-check.json`).
- **CPU criterion failed.** Over 15 minutes the app averaged 11.4% of a core
  (`cpu-after-1.3.0.json`), and 13.8% in a quiet 3-minute window. The 1.2.3
  app before it sampled at 35–67% (`cpu-before-1.2.3.txt`). A profile traced
  the cost to event-triggered samples recomputing lifecycle status while
  stopped. TASK-614 was reopened (R1), fixed, re-verified and re-audited.

**Second install, 1.3.0 (10)**: CPU over 15 minutes, starting 35 s after
launch, with no operator writes to watched roots and no MCP calls:
**0.40% of one core** (3.64 CPU-s in 900.6 s; highest point sample 1.5%) (`cpu-after-1.3.0-10.json`), below the 2% criterion. The self-check still reports `connected`, and `get_storage_summary` still answers; servicing an on-demand MCP call briefly raises the point sample, which settles back to about 0.4% within seconds.

## 4. Inherited proofs on this candidate (AC-GATE-649-02)

- **TASK-616 containment.** The supervision bootstrap passed on main. Every
  supervised stage of the full run, the release build and the focused runs
  reports `cleanupVerified: true`.
- **Failed-closed runs.** Several runs failed closed with `Cannot classify new
  process` before running anything, and were re-run (FIND-R4-SUPERVISOR-RACE).
- **TASK-617 sequential dashboard.** `LiveStatusBoardTests` (the hosted
  sequential observations), notification, status-board and volume
  presentation suites pass in the 618-test run.

## Findings recorded by this gate

| Finding | Severity | Disposition |
| --- | --- | --- |
| FIND-R4-IDLE-CPU | high | Resolved by TASK-614 reopen R1 and the build-10 measurement |
| FIND-R4-XCODE-WORKER | medium | Open: Xcode leaves one worker after a successful build. Supervision stops it and verifies cleanup. Release stages record it rather than pass it |
| FIND-R4-SUPERVISOR-RACE | medium | Open: process classification fails closed several times an hour. Runs are retried, and no result is relabeled |
| FIND-R4-OBJECT-CONVERGENCE-FLAKE | low | Open: the `ObjectConvergenceTests` seed step flakes on unmodified main as well |
| FIND-R4-LIFECYCLE-RESPONSE-SIZE | low | Open: `get_evidence_lifecycle` returns about 58 KB on this store, too large for an agent's context. Rung 4 replaces it with `get_health` |

## Limits

- The idle measurement covers one 15-minute window on one Mac. Detail
  scanning is stopped, and FSEvents per-file delivery still runs (rung 2
  replaces it).
- No GitHub release, tag, push or Homebrew tap update has been made.
