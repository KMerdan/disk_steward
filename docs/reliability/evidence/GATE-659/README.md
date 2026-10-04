# GATE-659: audit rung 2, the quiet guard

**Candidate 1.4.0 (11).**
- Commit `6271b62`, which is TASK-651/652/653 plus the version bump.
- Verified input `f1dc99e2ea7036291f691849fc382535f63075e03d812a7bc58a92211301add6`.
- Installed locally at the user's request on 2026-10-04. It has **not** been
  published: there is no tag, GitHub release or cask change.

## Candidate verification (isolated)

| Evidence | Result |
| --- | --- |
| [`candidate-f1dc99e2/`](candidate-f1dc99e2/) | `verify_candidate.py --xcodegen`: **658 tests, 8 skipped, 0 failures**. Attempt 1 stopped in the harness stage on the supervisor's process-classification race (FIND-R4-SUPERVISOR-RACE), before any test ran; attempt 2 is the record. The packaged CI build retained one Xcode worker. The supervisor stopped it with cleanup verified (exit 0, nothing remaining), the same accepted pattern as 1.3.0 (10) (FIND-R4-XCODE-WORKER) |
| [`release-1.4.0-11.json`](release-1.4.0-11.json) | Signed release build from a frozen copy whose digest equals the verified input. Universal app and helper, Developer ID signature, signed-app smoke and helper protocol all pass (the archive stage retained the same Xcode worker, with cleanup verified). Notarized through the Xcode account route; `verify-release` passes on the exported app and on the ZIP-unpacked app. `Disk-Steward-1.4.0.zip` SHA-256 `5901eedffd7a03bd1e93109936903e6be784883e24a6779d7a0a8af6722ff2c1` |
| [`rehearsal-f1dc99e2/`](rehearsal-f1dc99e2/) | The opt-in captured-store rehearsal on the candidate input passes. The 405 MB capture moves byte-identically, exports through the board path, gets a `legacy_export_too_large` answer from MCP, rolls back byte-identically through the script, and reopens with `integrity: ok` |
| [`inherited-proofs.md`](inherited-proofs.md) | The suites behind each claim, from the candidate run: reserve alerts with fake notifications, the journal (including the reset gap), the legacy lifecycle, the quiet guard, capacity under every detail fault, the helper self-check, and windowed readers |

## Installed candidate (user-equivalent, on the maintainer's Mac)

**Before the install** ([`installed-1.4.0/pre-install-hashes.txt`](installed-1.4.0/pre-install-hashes.txt)):
- 1.3.0 (10) was quit. Its store was left as:
  - a 405,483,520-byte main file;
  - a **4,120,032-byte `-wal` that a clean quit did not checkpoint**;
  - the `-shm` and `scan-convergence.json`.
- Every file was hashed, then APFS-cloned to
  `~/Library/Application Support/Disk Steward Backups/evidence-1.3.0-schema15-2026-10-04.sqlite*`.
- 1.3.0 (10) was moved to the Trash, and 1.4.0 (11) was installed, which
  Gatekeeper accepts as a notarized Developer ID app.

**The live move on first launch** ([`legacy-move-check.txt`](installed-1.4.0/legacy-move-check.txt), [`legacy-manifest.json`](installed-1.4.0/legacy-manifest.json)):
- The main file, `-wal` and `-shm` in `legacy/evidence-2026-10-04.*` match
  their pre-install hashes byte for byte, and the manifest records the same
  hashes.
- `scan-convergence.json` moved unchanged.
- No `evidence.sqlite` exists at the old path.
- The app created only `capacity.sqlite` and `steward.sqlite`.

**The app answers** ([`self-check.json`](installed-1.4.0/self-check.json), [`mcp-get_storage_summary.json`](installed-1.4.0/mcp-get_storage_summary.json)):
- The helper self-check reports `connected`, with `evidence.persisted: false`.
- `get_storage_summary`, 36 s after launch, answers:
  - live capacity;
  - two ring samples;
  - the reserve of 93 GiB, suggested from the old 90% threshold;
  - 272.6 GB free above the reserve;
  - every detail reason as "file-level scanning is retired".

**Changed directories across a relaunch, and TCC**
([`live`](installed-1.4.0/mcp-explain_growth-live.json), [`after relaunch`](installed-1.4.0/mcp-explain_growth-after-relaunch.json)):
- A fixture `~/Downloads/.disk-steward-gate-659/` was changed twice:
  - once while the app ran (`live/one/file.txt`);
  - once while it was quit (`offline/two/file.txt`, written between quitting
    at 12:29:33Z and relaunching at 12:29:38Z).
- `explain_growth` lists `…/live` within 15 s, and after the relaunch it
  lists `…/offline` too, replayed from the stored event ID.
- **The only gap is first launch's `journal-started`**, so the relaunch left
  no blind interval. All entries are `measured: false`.
- **TCC (ASM-604, from TASK-652).** `~/Downloads` is one of the user's review
  scopes. Its changes reach the installed app under its own identity.
- The fixture was removed afterwards.
- The fixture name appears as `.di[REDACTED]`. The path privacy filter
  mistakes `sk-steward-gate-659` for an API key. This false positive predates
  rung 2 and is recorded as a finding.

**Successive samples** ([`after 1 h`](installed-1.4.0/mcp-get_storage_summary-after-1h.json), [`growth over the hour`](installed-1.4.0/mcp-explain_growth-1h.json)):
- The ring holds 14 samples an hour after launch, up from 2.
- `explain_growth` over the window reports **+550 MB** used, measured from
  ring samples, alongside 18 changed folders (about 14,600 journaled changes
  from the user's own projects), all `measured: false`.
- `changed_directories` ignored the request's `limit: 10`. It uses its own
  200-item window, which is recorded as a finding.

**Journal reset.** A real FSEvents journal-identity change cannot be induced
on the maintainer's volume. The reset path is proven on the candidate input
by `ChangeJournalServiceTests.testANewJournalIdentityIsReportedAsAReset`. The
installed app shows the same gap mechanism with `journal-started`.

**Idle CPU over one hour** ([`cpu-1h-1.4.0-11.json`](installed-1.4.0/cpu-1h-1.4.0-11.json)):
- **0.06% of one core** on average: 2.02 CPU-s over 3600 s of wall time. The highest point sample was 0.0%. The criterion is below 0.5%: **met**.
- **Method.** As at GATE-649: the cumulative `ps` CPU time of the running app, sampled every 30 s.
- **Conditions.** Sampling started about 45 s after the relaunch at 12:29:38Z, with no MCP calls during the window (`conditionsObserved` in the record).
- **What ran.** The operator wrote seven small evidence files into `~/localGit` during the first ten minutes, then stopped. The user's own projects (for example `localGit/ai-gateway/.data`) kept changing throughout, so the journal recorded real events during the window. No scan, retention or store write runs at idle.

## Findings

| Finding | Severity | Disposition |
| --- | --- | --- |
| FIND-R4-PATH-REDACTION-FALSE-POSITIVE | low | Open. The path privacy filter redacts `sk-…` inside ordinary names (`.disk-steward-…`). This is pre-existing, and it hides rather than leaks. |
| FIND-R4-JOURNAL-LIMIT | low | Open. `explain_growth`'s `changed_directories` ignores the request `limit`; it uses a fixed 200-item window, still bounded by the response ceiling. To fix in the rung-4 tool rework. |
| FIND-R4-PAGE-SCHEMA-STALE | low | Open, for the rung-4 tool contract |
| FIND-R4-SUPERVISOR-RACE | medium | Open. Runs are retried, never relabelled |
| FIND-R4-XCODE-WORKER | medium | Open. Accepted pattern, with cleanup verified |
| FIND-R4-OBJECT-CONVERGENCE-FLAKE | low | Open. The flake is in the retired scanner path, which the app no longer reaches; the candidate run passed |
| FIND-R4-LIFECYCLE-RESPONSE-SIZE | low | Open, for rung 4 |

None of these affects a rung-2 claim.
