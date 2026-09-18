# GATE-519 — Safe testing alongside a running application (rung 1)

Actor: `claude` (gate taken at G110, guard `GUARD-TASK-085671AF6608153BBEC7510DAD0DE040`). Independent exercise of the integrated candidate for OUTCOME-510; task self-reports were not used as proof. Nothing was committed, installed, signed or released.

## Exact candidate

`candidate/candidate.json`: source input `7f3ff4fa33b2ace1811192c4f4229a33870a07b9f51b3f1e30babf26e9de27fa` (product sources identical to the TASK-532 candidate `02fe77cd…`; the input additionally carries the TASK-572 rehearsal script). Fifteen stages passed:

| stage | result |
|---|---|
| harness, toolchain, manifest, entitlements, build | passed (build 15.4 s) |
| tests | 522 tests, 4 opt-in skips, 0 failures (80.7 s); `sentinelPreserved: true` — the exact live-endpoint/sentinel scenario ran and passed, not merely discovered |
| syntheticUpgrade | four historical migration cases recorded with fixture source hashes |
| package-generator, package-toolchain, package-system-temporary, package-project | XcodeGen 2.46.0, disposable second source copy, canonical project untouched |
| package-build (30.6 s), package-architecture-app/helper | unsigned CI app `com.marudankiji.disksteward` 1.1.1 (3), arm64; bundle manifest with per-file hashes |
| package-smoke | accessory `--ui-smoke` launch: isolated, detail sampling paused, zero watched roots, agent access off, IPC off, ephemeral settings, notifications disabled; generated smoke directory removed; sentinel socket received no connection |
| package-helper | bundled `disk-witness-mcp` initialization, ten read-only tool definitions and ping through the typed protocol |

Debug artifacts: `DiskStewardApp` `ac47ce57131b…`, `disk-witness-mcp` `1560827ab3fd…` (not distribution-ready by construction).

## Scenarios for this rung, independently rerun

- **Isolation (TASK-511)**: `docs/reliability/evidence/audits/scoped-511-521-522-green/` — VerificationIsolationTests, BackendIsolationTests, InlineExportSafetyTests, ExportSafetyRegressionTests, MonitoringSettingsTests: 29 tests, 0 failures. Audit `docs/reliability/evidence/audits/TASK-511/audit-result.json` passed (EVENT-20260918T051855151418Z-E03FCA0D).
- **Ownership (TASK-512)**: `docs/reliability/evidence/audits/TASK-512/scoped-green/` — SocketOwnershipRegressionTests, VerificationIsolationTests, MCPTransportLifecycleTests: 25 tests, 0 failures. Audit passed (EVENT-20260918T051110595530Z-69D66B6E).
- **Running application + another launch**: the packaged smoke above and the full-suite sentinel scenario: a live endpoint and sentinel state survive a second isolated launch and the whole test run.
- **Safety and recovery for this rung**: `docs/reliability/evidence/TASK-572/rollback-rehearsal.md` — synthetic schema-6 store, SQLite-API backup, interrupted migration at every checkpoint recovered, old binary refuses the newer schema and leaves it untouched, restored backup opens with the old binary and migrates forward; negative oracle fails as required.

## Findings affecting this rung

FIND-ISOLATION, FIND-SCALE, FIND-SERVICE, FIND-ROLLBACK, FIND-QUERY, FIND-OCCURRENCE: resolved with canonical inspections. FIND-DISTRIBUTION-DOC: open, non-material (documentation, TASK-571). FIND-OVERNIGHT: open, on ASSET-RESOURCE/ASSET-BUILD; it does not touch this rung's assets and is owned by TASK-572 (soak supervisor `Scripts/Testing/supervise_soak.py` written, run pending).

## Limitations

- The packaged app is unsigned and built from a disposable copy; notarization and installed-app behavior are not exercised (release is a separate authorization).
- Host macOS 15.6.1 arm64 only; macOS 13 remains a declaration.
- The auditor also implemented later tasks on the shared candidate; independence rests on reruns, hashes and archived logs rather than a separate person.
