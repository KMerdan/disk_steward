# TASK-561 — Configuration ownership and conflict-safe mutations

Actor: `claude` (TASK-561 taken at G124, guard `GUARD-TASK-5D18F5475F02991BF1D9639E9F9433F4`). Base: the pre-task isolated snapshot `ds552-check-x6c3vj6c` (input `c2e4ad38…`, product sources before this task; copies in `base-source/`). Nothing was committed, installed, signed or released; no real client configuration was opened. All runs are isolated verifier snapshots under `/private/tmp`.

## What changed

**In-app JSON clients** (`Sources/DiskStewardApp/AgentIntegrations/`):

- `AgentIntegrationMutationError` (models): every refusal is typed and names the file, the backup that holds the pre-edit bytes and the recovery step: `notOwned`, `concurrentEdit`, `backupFailed`, `commitFailed`, `restoreFailed`. Adapter messages carry these sentences verbatim.
- `PrivateIntegrationFile.replace(_:at:expecting:)` (infrastructure): the commit is a **check-and-swap**, not a compare followed by a rename. `renamex_np(RENAME_SWAP)` installs the new bytes and hands back the file that was really there; if those bytes are not the ones read at the start, the original is swapped straight back and `concurrentEdit` is thrown. A file that must not exist yet is installed with `RENAME_EXCL`. If even the swap back fails, the other writer's file is preserved beside the client file (`.disk-steward-backups/<config>.<stamp>-concurrent-<uuid>.bak`) and `concurrentEditUndoFailed` names it; no other writer's bytes are ever deleted (review finding F2).
- Backups move from unbounded siblings (`<config>.disk-steward-backup-<uuid>`) to `<dir>/.disk-steward-backups/<config>.<stamp>-<uuid>.bak` (directory 0700, files 0600), indexed by the receipt's new optional `lastBackupPath` (legacy receipts decode with nil) and bounded to ten per file; other files' backups and anything else in the directory are never pruned.
- `persist`/`restore` in the JSON adapter use the typed errors; the restore after a failed receipt write is itself check-and-swap, so a third writer's file is preserved and the report names the backup. Two fault-injection seams (`beforeCommit`, `beforeRestore`) exist for the proofs below.
- Ownership semantics are unchanged: user additions (env, cwd, unknown keys) end ownership and every mutation fails closed; a second profile file is a separate file and is never read or written.

**CLI clients** (`Scripts/Integration/`):

- `json-config.swift`: `set` keeps every user key on an existing `disk_steward` entry (env, cwd, unknown; user args too) and refreshes only type/command/args, reporting what was preserved; a malformed entry (non-string command, non-array args) or root is refused (exit 65) untouched; `remove` refuses an entry with user additions (exit 65); writes are check-and-swap (exit 75 on a concurrent edit); `inspect` reports presence and additions.
- `install` / `uninstall`: a timestamped backup directory with `manifest.json` (per file: existed before, hash before, hash after) is written first; a failure at any later step restores exactly what this attempt changed (`failed-and-restored`) or, when nothing had changed yet, says so (`refused-nothing-changed`); if a restore step itself fails the manifest says `restore-failed` and the message gives the exact rollback command (exit 70, review finding F3); a config file changed between backup and commit is refused (exit 75); only the newest ten owned backup directories are kept, ordered by their embedded stamp across the install/uninstall/rollback families, never by name (`backup-lib.zsh`, review finding F1).
- `rollback` (new): `--list`, `--dry-run`, `--backup NAME`, `--force`. Restores a completed backup only while each current file still hashes to what that operation wrote; a file the user edited since is refused unless `--force`; the state before the rollback is saved into a `rollback-*` backup first, so a rollback is itself recoverable; a failure while applying puts that saved state back and finishes its manifest (`rollback-failed-and-restored`), so it is never left `in-progress`; a backup for another client is refused.

## Proofs (AC-TASK-561-01)

| case | test | evidence |
|---|---|---|
| malformed roots/args | `ConfigurationOwnershipTests.testMalformedRootAndArgsFailClosedWithoutTouchingTheFile`; `ConfigurationRollbackTests.testMalformedRootsAndEntriesAreRefusedWithoutChanges` | array root, string servers, string args, missing command → broken/refused; bytes unchanged; no backup, no receipt |
| env/cwd/unknown additions | `testUserAdditionsAreNeverOverwrittenOrRemoved`; `testClaudeUpgradePreservesUserAdditionsAndUninstallRefusesToDeleteThem` | app: conflict, every action fails naming the file; CLI: upgrade keeps env/cwd/args and reports them, uninstall refuses (exit 65) |
| client profiles | `testSecondProfileAndUnrelatedKeysStayUntouchedAcrossSetupRepairRemove` | a second profile file is byte-identical after setup/repair/remove and is external without a receipt |
| concurrent writes | `testConcurrentWriteBetweenReadAndCommitIsAnExplicitRecoverableConflict`, `testConcurrentCreationOfAMissingFileIsRefused` | for setup/repair/remove the other writer's file wins, the report names the backup, no receipt changes |
| failure at each mutation step | `testBackupFailureChangesNothing`, `testCommitFailureLeavesTheFileAndNamesTheBackup`, `testReceiptFailureRestoresOrReportsTheBackupWhenRestoreIsImpossible` (+ `AgentIntegrationHardeningTests.testJSONReceiptFailureRestoresExactDocumentForAllMutations`); `testFailureBeforeAnyChangeIsReportedAsARefusalWithoutRestoring`, `testMidInstallFailureRestoresWhatWasAlreadyWrittenAndKeepsTheBackup` | backup, commit, receipt and restore failures each leave the user's bytes and say what happened; the CLI restores the plugin it had written and keeps the manifest |
| idempotent, approval-aware | `testSetupAndRemoveAreIdempotentAndBackupsStayBounded`; existing handoff/approval tests | second setup and second remove are `unchanged`; backups bounded to ten; approval-pending receipts untouched by this change |
| recoverable backups / CLI rollback | `testInstallThenRollbackRestoresBothClientsAndRefusesEditedFiles`, `testUninstallBackupIsRestorableAndRollbackRefusesAnotherClientsBackup`, `testBackupsAreBoundedToTenOwnedDirectoriesAndForeignEntriesStay`, `testDefaultRollbackAndPruningFollowTheStampNotTheNamePrefix`, `testRollbackApplyFailurePutsThePreviousStateBack` | rollback dry run, refusal after a user edit, forced restore, undo of an uninstall (config and plugin), wrong-client refusal, bounded owned directories with foreign entries untouched, chronological selection and pruning across name families, a failed apply restored |
| review findings (static review) | `testFailedUndoSwapPreservesTheOtherWritersBytesAndSaysSo`, `testARestoreFailureInsideUndoIsReportedAndKeepsTheBackup` | a failed undo swap preserves the other writer's bytes at a named path; a failed restore inside undo is reported with the recovery command and the backup kept |

Runs:

- `app-suites-green/` (input `5acdfddc…`, 47 tests) and `script-suites-green/` (input `7f3d8527…`, 21 tests) — the runs the static review was performed against.
- `app-suites-green-2/` — after the review fixes: ConfigurationOwnershipTests 10, AgentIntegrationHardeningTests 6, RemainingClientsAdapterTests 10, CodexAndClaudeCodeAdapterTests 12, AgentIntegrationContractTests 6, AgentIntegrationsPresentationTests 4: 48 tests, 0 failures (input `f987812c…`).
- `script-suites-green-2/` — ConfigurationRollbackTests 10, IntegrationInstallTests 8, MCPTransportLifecycleTests 6: 24 tests, 0 failures (input `f987812c…`).
- `candidate-1/` — full verifier before the review fixes (input `7f3d8527…`, 539 tests, 0 failures).
- `candidate/` — full six-stage isolated verifier on the final input `f987812c8ffe637ed7c21c50091587538a7fe5d97863851e2d4ee8a7fa8621a5`: all six stages passed; 543 tests, 5 opt-in skips, 0 failures (see candidate.json).
- `ownership-mutation-red/` (base = final input) — check-and-swap verification disabled in a disposable snapshot → the concurrent-write, restore-failure and undo-swap fixtures fail (3 of 10). `rollback-mutation-red/` — `json-config remove` ignoring user additions and `rollback` ignoring post-backup edits → the upgrade/uninstall-refusal and rollback-refusal fixtures fail (2 of 10). `*-mutation-red-1/` are the same mutations on the pre-review input. Specs: `ownership-mutation.json`, `rollback-mutation.json`.
- `ownership-review-{job,result}.json` — read-only static delta review (advisory), base copies in `base-source/` verified against the pre-task snapshot; `ownership-source-manifest.json` binds the delta to the final input.

## Limitations

- Concurrent-edit proofs use in-process fault seams; no second real process races the app, though the check-and-swap is the same syscall path either way.
- `renamex_np` semantics are those of APFS/HFS+ on macOS; other filesystems are not exercised.
- The CLI stack still uses the `disk_steward` server name while the app adapters use `disk-steward`; the two never manage each other's entries (unchanged, documented).
- Real installed clients are not touched; native lifecycle remains opt-in (`DISK_STEWARD_NATIVE_CLIENT_TESTS`).
