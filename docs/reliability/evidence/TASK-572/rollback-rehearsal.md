# TASK-572 — Migration and compatible-binary rollback rehearsal (FIND-ROLLBACK)

Actor: `claude`, TASK-572 taken at G104 after replan R12 (guard `GUARD-TASK-F7F3FBBDFE60B08C7C2ACBB65AA20E0D`).
Tool: `Scripts/Testing/rehearse_migration_rollback.py` (new, TASK-572 write scope). Nothing was committed, installed, signed or released; no production store or app launch was involved. Everything ran inside one fresh `/private/tmp/ds572-rollback-*` directory.

## What the rehearsal does

1. Exports the compatible baseline source at git `HEAD` (`cf313e4527a3bd30dae217d2c1ff68d7a7a87b60`, schema 6, the last committed product) and copies the candidate inputs (the same manifest the verifier hashes). One small `store-probe` executable (`rollback-rehearsal/store-probe-main.swift`) is built against each `DiskStewardCore`; it uses only public API both share: open with a migration checkpoint hook, insert, SQLite-API backup, diagnostics, current files, close.
2. The **baseline** probe creates a synthetic old-schema store and seeds 300 events (schema 6).
3. The baseline probe takes a **SQLite-consistent backup** (backup API, committed WAL included) into a separate directory. The sqlite3 CLI independently confirms `integrity_check = ok`, `user_version = 6`, 300 events. The backup's hash is recorded and re-checked at the end; the backup is never opened in place again.
4. For each migration checkpoint (`after-consistent-copy`, `after-shadow-validation`, `before-atomic-switch`, `after-atomic-switch`) the **candidate** probe migrates a fresh copy of the backup, is interrupted exactly there (exit 4), and the next open recovers and completes: schema 14, `quick_check = ok`, 300 events. An uninterrupted migration is recorded too.
5. The baseline probe opens a scratch copy of the migrated store and **refuses it explicitly** ("Database schema is newer than this application", exit 3); the copy's main file hash is unchanged afterwards. A newer schema is never opened with the older binary in place.
6. **Rollback**: the backup is restored into a separate directory; the baseline probe opens it (schema 6, 300 events); the candidate probe then migrates that restored copy forward again (schema 14). The original backup's hash is unchanged.

## Results

| run | candidate input | result |
|---|---|---|
| `rollback-rehearsal/report.json` (positive) | `068d9107bf5e57714ae8d63e71ede25af268e770e995a330e5cca2a13135b78f` | passed: 19 steps, 0 problems; old schema 6 → new schema 14; every interruption recovered; refusal explicit and non-destructive; backup unmodified |
| `rollback-rehearsal/negative-oracle/report.json` | same inputs, baseline probe standing in for the candidate | must report failure (schema not advanced, no refusal): see the oracle report |

`rehearsal.log` holds every command, exit code and JSON line. `store-probe-main.swift` is the exact probe source.

## Limitations

- The "compatible binary" is the last committed product library built from `HEAD`, exercised through a probe executable, not the packaged `Disk Steward.app`: the app refuses any support-directory override outside `--ui-smoke` by design (CONTRACT-510 isolation), so no app process can be pointed at a fixture store.
- Interruptions are injected at the four checkpoints the migration exposes; power loss between those points is not simulated.
- The synthetic old store carries events only; scan generations, current file state and exports of an older schema are covered by `HistoricalMigrationTests` in the full candidate, not by this rehearsal.
- Production rollback readiness is not claimed; the control stays "development rollback within disposable snapshots" until a release candidate is rehearsed by `Scripts/Distribution/rehearse-handoff`.
