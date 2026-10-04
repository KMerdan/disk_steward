# TASK-653: retire the always-on scanner; legacy evidence

Candidate input `2d09000ebcb2b374e07d888244dc997113d8ea1c7bdb40359774f370559293b5` (uncommitted on main after `9e31917`). Nothing has
been installed or published.

## Change

- **Quiet guard at idle (AC-01).**
  - `StatusItemController` composes `MonitoringComposition.quietGuard()`:
    a `QuietGuardProbe` that measures capacity only, and **no** per-file
    change collector.
  - The app no longer constructs `PersistentMonitoringProbe`,
    `DirectoryMetadataScanner`, `TargetedFSEventsCollector`,
    `RetentionSchedule` or the capacity-only fallback anywhere. A source scan
    test enforces this.
  - Scan staging, publication, object convergence and pressure retention are
    therefore unreachable from the app. Their code stays only for the
    existing tests until the rung-3 removal.
  - At idle, only capacity sampling (written to the ring) and the TASK-652
    change journal run.
  - The observation says `detailRetired`, and the status is **Active**:
    "Capacity is current, and changed folders are journaled. No files are
    scanned while idle." It is not the degraded "File detail unavailable".
- **Legacy move (AC-02).** `LegacyEvidence.migrate` runs at launch, after
  the instance lease and before anything is composed. It renames
  `evidence.sqlite` to `legacy/evidence-<date>.sqlite`:
  - `-wal`, `-shm` and `-journal` move under the same name. The log moves
    first, and the main file moves last.
  - `scan-convergence.json` moves alongside it.
  - A manifest (`legacy/<name>.json`, `legacy-evidence-v1`) records each
    file's size and SHA-256 before the move. It is written with status
    `moving` and switched to `migrated` once every file is in place, so an
    interrupted move resumes under the same name on the next launch.
  - A second store moved on the same day gets `-2`.
  - With nothing to move, no `legacy/` directory is created.
  - Smoke runs never move anything.
- **Export only, from a clone.** Neither the board's **Export Legacy
  Evidence** (menu and settings) nor MCP `export_evidence` opens the legacy
  file with SQLite.
  - Both clone the set (an APFS clone, which is free and leaves the original
    untouched) into `legacy/.export-clone-<uuid>/`. They open the clone with
    the normal store, export, and remove the clone. Stale clones are removed
    on the next launch.
  - This is stricter than a read-only open. A read-only SQLite open of a
    WAL-mode file without its `-shm` fails (`SQLITE_CANTOPEN`, observed on
    the capture). Even when it succeeds, it can create sidecars beside the
    legacy file.
  - The MCP backend runs in `fileDetail: .retired`:
    - It never opens or creates `evidence.sqlite`, and sessions are kept in
      memory.
    - File-level tools answer `detail_unavailable` with "File-level scanning
      is retired…", which is not retryable.
    - `get_storage_summary` and `explain_growth` give reasons ending
      "file-level scanning is retired".
    - `export_evidence` reads the legacy clone, or answers
      `no_legacy_evidence`.
    - A legacy set whose current state exceeds the 2 MiB inline budget
      answers `legacy_export_too_large`, pointing to the file export.
      Previously this surfaced as a *retryable* `request_too_large`.
- **Settings.**
  - **Review scopes.** "Detailed evidence roots" become **Review scopes**;
    the journal follows them.
  - **Reserve.** The percentage threshold is no longer offered. The reserve
    suggestion derived from it (TASK-651) is what a user without a reserve
    gets.
  - **Removed controls.** "Keep raw events" and "Evidence database limit"
    controlled only the retired store, so they are gone. The investigation
    window is also removed, because it had nothing left to intensify. The
    stored settings keys are unchanged, so a rolled-back 1.3.0 reads the same
    settings.
  - **Legacy evidence section.** It shows the set's date and size, with
    **Export Legacy Evidence…** and **Delete Legacy Evidence…**.
  - **Delete needs confirmation.** Delete asks for confirmation and moves
    the files to the Trash. `LegacyEvidence.delete` refuses without
    `confirmed: true`.
- **Rollback.** [`Scripts/Distribution/restore-legacy-evidence`](../../../../Scripts/Distribution/restore-legacy-evidence):
  - It refuses while Disk Steward runs, if `evidence.sqlite` exists, or if any
    file's SHA-256 differs from the manifest.
  - Otherwise it renames the newest (or a named) set back, moving the log
    first, and keeps the manifest as `<name>.restored.json`.
  - Then install the previous version. `EvidenceStore.swift` is unchanged
    since `v1.3.0`; the only store-directory changes are the additive
    `BoundedStore.swift` / `changeCount()` and the new `LegacyEvidence.swift`.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 92 tests pass: legacy move, clone export, confirmed delete, rollback script, quiet guard, retired backend, journal, growth, lifecycle, board, menu labels and the increment suites |
| `full-suite/` | `verify_candidate.py` on the same input: 658 tests, 8 skipped, **1 failure**. The failure is `ObjectConvergenceTests.testAStoreWithRowsInsideObjectsConvergesAndSaysSo`, the known intermittent seed race (FIND-R4-OBJECT-CONVERGENCE-FLAKE: "change evidence is later than observation publication"). It sits in the retired scanner path, which is no longer reachable from the app. The release candidate's own full run is recorded at GATE-659 |
| `rehearsal-green/` | The opt-in rehearsal on the captured real store passes; `report.json` holds its sizes, counts and timings |
| `checkpoint-before-move-red/` | Checkpointing (opening) the store before the move fails `LegacyEvidenceTests.testAnInterruptedMoveResumesUnderTheSameName`, `LegacyEvidenceTests.testMigrationRenamesTheStoreAndItsLogByteForByte`, `LegacyEvidenceTests.testRestoreScriptRenamesTheSetBackWithItsBytesIntact` |
| `export-in-place-red/` | Exporting from the legacy file instead of a clone fails `LegacyEvidenceTests.testExportReadsAClonedCopyAndLeavesTheLegacyFilesUntouched`, `RetiredDetailBackendTests.testExportReadsALegacyCloneAndLeavesTheSetUnchanged` |
| `delete-unconfirmed-red/` | Deleting without confirmation fails `LegacyEvidenceTests.testDeleteRequiresConfirmation` |
| `no-resume-red/` | Not resuming an interrupted move fails `LegacyEvidenceTests.testAnInterruptedMoveResumesUnderTheSameName` |
| `restore-skips-hash-red/` | A rollback script that skips the hash check fails `LegacyEvidenceTests.testRestoreScriptRenamesTheSetBackWithItsBytesIntact` |
| `composes-scanner-red/` | Composing the scanner probe and per-file collector fails `QuietGuardTests.testNoAppSourceConstructsTheScannerOrThePerFileCollector` |
| `no-migration-red/` | Launching without the legacy move fails `QuietGuardTests.testNoAppSourceConstructsTheScannerOrThePerFileCollector` |
| `retired-opens-store-red/` | A retired backend that opens evidence.sqlite fails `RetiredDetailBackendTests.testExportReadsALegacyCloneAndLeavesTheSetUnchanged`, `RetiredDetailBackendTests.testExportWithoutLegacyEvidenceSaysSo`, `RetiredDetailBackendTests.testFileLevelToolsSayScanningIsRetiredAndNothingCreatesTheOldStore` |
| `quiet-guard-degraded-red/` | Reporting the quiet guard as failed detail fails `QuietGuardTests.testIdleSamplesAreHealthyAndWriteOnlyTheCapacityRing` |
| `legacy-export-retryable-red/` | An oversized legacy export as a retryable size error fails `LegacyRehearsalTests.testCapturedStoreMovesExportsAndRollsBackByteForByte` |

## The rehearsal on the real store (EVREQ-01)

The live 1.3.0 store was captured with a read-only `sqlite3 … .backup`. The
live files were left unchanged: the main file hashed the same before and
after. The capture was placed only in the isolated snapshot
(`.captured/evidence.sqlite`) of `LegacyRehearsalTests`. The test then:

1. leaves committed pages only in `-wal`, as a running app does;
2. moves the set with the launch code;
3. exports through the board path and through MCP;
4. rolls back with the shipped script;
5. reopens the store with the store code that 1.3.0 ships.

Result ([`rehearsal-green/report.json`](rehearsal-green/report.json)):

- **The store.** 405,483,520 bytes plus a 20,632-byte log. It held 99,958 file objects, 100,000 path bindings, 1,500 retention runs and 1,482 retention gaps.
- **The move** took 0.17 s, including SHA-256 of every file. The main file and the log are byte-identical in `legacy/`.
- **The board/menu export** took 7.5 s and wrote a full bundle.
- **MCP `export_evidence`** answered `legacy_export_too_large` in 1.2 s. The current state of about 100,000 files exceeds the 2 MiB inline budget. This store already failed this way on 1.3.0, as a misleading retryable `request_too_large`.
- **The legacy set was not changed by either export.** The hash, the file listing and the modification time are all the same.
- **The rollback script** took 0.87 s. The main file and the log are byte-identical to before the move, and every counted table matches.
- **On reopening**, the store reports `integrity: ok` at schema 15.

## Acceptance notes

- **AC-01, "removed or unreachable".** The pipeline is unreachable from the
  app, which a source scan of `Sources/DiskStewardApp` enforces. It is not
  yet deleted, because its tests are rung-1 regression coverage. Removal is
  for rung 3, once the bounded review replaces it.
- **AC-02, "opens it read-only".** The legacy file is never opened by SQLite
  at all. Exports read an APFS clone, and the clone is what SQLite opens and
  may migrate. Hashes, file listings and modification times prove the set is
  unchanged.
- **AC-02, "only for export".** No query reads legacy evidence. The file-level
  MCP tools answer "retired" instead of serving 3-week-old file detail as if
  it were current. The bounded review (rung 3) brings file-level answers back.
- **Sessions.** These now live in memory and are lost on relaunch.
  - Sessions are registered only through the opt-in
    `Scripts/Integration/session` script, and the live store holds none.
  - After a relaunch, a heartbeat answers `invalid_registration`, and the
    session must be registered again.
  - Persisted sessions move to the steward file in rung 4.
- **The packaged candidate.** A fresh backup of the live store is taken
  before GATE-659 installs the candidate, as was done for 1.2.3 → 1.3.0.
