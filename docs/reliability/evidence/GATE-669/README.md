# GATE-669: audit rung 3, bounded review

**Candidate 1.5.0 (12).**
- Commits: `52c206e` (version bump) and `4cdbe93` (TASK-664), on top of
  TASK-621, 622, 623, 631, 661, 672 and 671.
- Verified input:
  `03e80c743d0ce97b1e6c5dd49d0b0670fc4cf6452d49efd421fb60815490947b`.
- Installed locally at the user's request on 2026-10-04, **not notarized**
  (the user chose not to upload it). It has not been published: there is no
  tag, GitHub release or cask change.

## Candidate verification (isolated)

| Evidence | Result |
| --- | --- |
| [`../TASK-664/consecutive/`](../TASK-664/consecutive/) | Three consecutive `verify_candidate.py --xcodegen` runs on the candidate input, with no retries and no supervision race. Runs 1 and 2 passed 727 tests (11 skipped, 0 failures) and built the packaged CI app; the retained Xcode worker was stopped with cleanup verified (FIND-R4-XCODE-WORKER). Run 3 failed only the known `ObjectConvergenceTests` seed race in the retired scanner path (FIND-R4-OBJECT-CONVERGENCE-FLAKE) |
| [`release-1.5.0-12.json`](release-1.5.0-12.json) | Signed release build from a frozen copy whose digest equals the verified input. Universal app and helper, Developer ID signature, signed-app smoke (the menu leads with Review Storage…) and the helper protocol (the ten-tool catalogue) all pass. The archive stage retained the same Xcode worker, with cleanup verified |
| [`candidate-03e80c74/synthetic/`](candidate-03e80c74/synthetic/) | The synthetic million-file tree, under the default budget, completes 1,046,750 entries in 6.6 s. With a 300,000-entry budget injected, it stops with a partial report naming the 151 of 530 top-level folders it covered |
| [`candidate-03e80c74/rehearsal/`](candidate-03e80c74/rehearsal/) | The opt-in captured-store rehearsal passes on the candidate input. The 405 MB legacy store moves, exports and rolls back byte for byte |
| Window states | `ReviewWindowTests` run inside every candidate run: every design state in light and dark appearance, OCR-checked, plus the reopened and finished-with-unreadable states. The screenshots are in [`../TASK-623/screenshots/`](../TASK-623/screenshots/) |
| Attribution fixture | `GrowthAttributionTests` and `ExplainGrowthAttributionTests` run inside every candidate run |

## Installed candidate (user-equivalent, on the maintainer's Mac)

**Install** ([`installed-1.5.0/install.txt`](installed-1.5.0/install.txt), [`pre-install-hashes.txt`](installed-1.5.0/pre-install-hashes.txt)):
- 1.4.0 (11) was quit.
- Its steward files were hashed and APFS-cloned to `Disk Steward Backups/steward-1.4.0-11-before-1.5.0-…`.
- 1.4.0 was moved to the Trash, and 1.5.0 (12) was copied in.
- `codesign` reports the app valid. `spctl` reports
  `rejected source=Unnotarized Developer ID`, and there is no quarantine
  attribute, so the app runs. Gatekeeper evidence is therefore missing (see
  Limitations).

**localGit review** ([`cold`](installed-1.5.0/cold-localgit-health.json), [`warm`](installed-1.5.0/warm-localgit-health.json), [`du and candidates`](installed-1.5.0/cold-localgit-check.json)):

| Run | Seconds | Items | Worth reviewing |
| --- | --- | --- | --- |
| Cold, right after `sudo purge` | **54.0** | 2,000 | 62.68 GB |
| Warm | **44.8** | 2,000 | 62.68 GB |

- **Sizes match `du`.** Across 4,071 indexed objects, the review counts
  70,347,538,432 bytes and `du -sk` counts 70,347,472,896 (ratio 1.000001).
  No object above 1 MiB differs by more than 5%.
- **Repositories and tracked source are never candidates.** In 87 git
  repositories, no item is a repository or live state, and no item holds a
  file its repository tracks.

**Opted-in caches** ([`caches-du.json`](installed-1.5.0/caches-du.json)):
- 7 caches were measured in 29.9 s, all within 5% of `du`: uv,
  `~/Library/Caches`, ollama, actcache, the pnpm store, npm and docker.
- The largest difference is 1.000214, on `~/Library/Caches`, which changes
  live. Its 10 TCC-protected folders are stated as unreadable.
- The report reads "finished, but some folders could not be read", not
  "stopped".

**Idle CPU over one hour** ([`cpu-1h-1.5.0-12.json`](installed-1.5.0/cpu-1h-1.5.0-12.json)): **0.156% of one core** on average: 5.6 CPU-s over 3600 s of wall time, starting at 20:23:24Z. The criterion is below 0.5%, so it is **met**. The method is the same as at GATE-659: the `ps` cumulative CPU time of the running app, sampled every 30 s. During the window there were no MCP calls, reviews or builds, and no growth attribution ran (the attribution file's last write was at 20:16Z). Other agent sessions were active under the watched roots, and the journal recorded 74,273 changes in one `.claude` folder at 21:00Z. That burst cost about 2.3 CPU-s, the one larger interval in the hour (a 13.2% point sample); every other 30 s interval cost about 0.1 CPU-s. 1.4.0 (11) measured 0.06% in a quieter hour.

**Legacy migration (OUTCOME-650 proof).** The legacy set migrated by 1.4.0
stays where it was, and 1.5.0 creates no `evidence.sqlite`: The three legacy files still match their manifest hashes byte for byte (the same hashes recorded before the 1.4.0 install), and the support folder holds no `evidence.sqlite` ([`legacy-check-1.5.0.txt`](installed-1.5.0/legacy-check-1.5.0.txt)). The migration itself is rehearsed on the candidate input (above). The only addition is the backend's cached read-only clone of the set, `legacy/.export-clone-…`, created by the GATE-679 export call. It is an APFS clone, so it shares the set's blocks.

## Supervision and rollback

**Supervision** ([`bootstrap-supervision-1.5.0.txt`](bootstrap-supervision-1.5.0.txt)):
`bootstrap_supervision.py` passes all 13 independent-watchdog cases with
TASK-664's supervisor, on the first attempt. The cases are success,
timeout, detached, early-exit, retained-stdout, term-refusal, memory,
output, measurement, cancel, identity, gate-close and legacy-oracle.

**Rollback.** Rung 3 and rung 4 changed no store format:
- `git diff v1.4.0..4cdbe93` of `BoundedStore.swift` and
  `SQLiteConnection.swift` is empty.
- The live `steward.sqlite` holds exactly the eight CONTRACT-602 tables.
- The new `growth-attributions.json` beside it is ignored by 1.4.0.

Rolling back is therefore: quit 1.5.0, move it out of `/Applications`, and
move `Disk Steward 1.4.0 (11).app` back from the Trash. The pre-install
steward files are cloned in `Disk Steward Backups/` if an exact restore is
wanted. The legacy set is untouched, and its restore script is unchanged
from 1.4.0.

## Limitations

- **Not notarized.** The user chose not to upload the candidate, so
  Gatekeeper acceptance of 1.5.0 is not shown. The signature and the
  universal build are.
- **The cold run followed a short Codex review.** After the purge, the
  window first reviewed `~/Documents/Codex` (4.2 s) and then localGit,
  23 s later. That is a different tree, so the localGit timing is still
  cold for localGit.
- **No live VoiceOver pass.** The user skipped the hands-on check.
  VoiceOver labels are verified in the model and by a source check.
- **Synthetic stop uses an injected budget.** The synthetic tree fits the
  default budget (5 M entries); the stop with a partial report is shown
  with an injected 300,000-entry budget, as in TASK-621.
