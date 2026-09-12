# GATE-290 persistent recorder audit observations

Observed 2026-09-13 (Asia/Tokyo) on the local arm64 macOS Swift 6 development host.

## Independent end-to-end scenario

`PersistentRecorderIncrementTests.testMonitoredGrowthPersistsNotifiesExportsAndRecoversAfterRestart` passed against a unique temporary root and database. It:

1. established a whole-volume and watched-root baseline;
2. wrote a 2 MiB watched-root file and a separate outside-root file;
3. confirmed only the watched file received detailed, inferred attribution while the outside allocation remained unknown-confidence unexplained growth;
4. crossed the configured growth threshold exactly once;
5. persisted snapshots and event metadata to the bounded WAL database;
6. exported a basename-shaped complete evidence bundle and independently verified every SHA-256 hash;
7. inspected the brief for the changed path, attribution method, and privacy statement; and
8. constructed a new probe against the same database, sampled successfully, and observed `quick_check=ok`, at least three snapshots, retained event detail, and storage below the 10 MiB fixture ceiling.

## Inherited behavior

- `swift test`: 54 tests passed with zero failures, including the original snapshot/export increment, schema contracts, live volume snapshot, native FSEvents smoke, evidence-store recovery, monitoring UI/lifecycle, and complete bundle tests.
- `swift build`: passed.
- `.build/debug/DiskStewardApp --ui-smoke`: launched as an accessory app, returned the expected left/right click routes and Export/Settings/About/Quit menu labels, and produced a live snapshot.
- `git diff --check`: passed.

## Human UI observation

The fixed render at `/Users/merdankiji/Documents/Codex/2026-09-12/as-x20/work/pyramid-disk-steward/TASK-212-ui-smoke/rendered-status-board.png` was visually inspected. At 330 × 270 points it showed, without clipping: the Disk Steward identity and refresh action; Monitoring Starting state and explanatory detail; growth-baseline status; live volume path/capacity/progress; Pause; and Export Evidence. State text has a combined accessibility summary, and deterministic tests separately cover Degraded and Recovered wording.

## Resource sample

`/usr/bin/time -l .build/debug/DiskStewardApp --ui-smoke` reported:

- elapsed: 0.37 seconds;
- user/system CPU: 0.03/0.02 seconds;
- maximum resident set size: 29,392,896 bytes (about 28.0 MiB);
- peak memory footprint: 10,404,560 bytes (about 9.9 MiB);
- swaps: 0;
- block input/output operations: 0/0.

This is a bounded launch-path sample, not a steady-state idle-duration claim. Long-duration idle budgets and component failure controls remain assigned to the later final risk-control gate.

## Privacy and limitations

- No test or export reads file contents or captures environment variables.
- FSEvents remains a notification hint and never supplies creator-process identity.
- Unknown/outside-root growth remains explicit rather than guessed.
- Threshold notifications fire only on crossings, not unchanged samples.
- Launch-at-login registration on a signed app bundle remains a packaging-time observation; the `SMAppService` adapter's success/failure semantics are unit-tested now.
