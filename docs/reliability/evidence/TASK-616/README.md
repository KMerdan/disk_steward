# TASK-616 — verified bounded supervision

Candidate input SHA256: `9fd30592af86d021a4b661cafad65f6564798c89e8b416ac2a0312a7c6fdf4da`.

The common supervisor replaces process-group-only cleanup with gated launch,
kernel birth/original-parent identity tracking, inherited-marker recovery,
aggregate physical-footprint budgets, bounded output, cancellation and verified
descendant exit. Read `Scripts/Testing/SUPERVISION.md` for the supported boundary.

- `bootstrap.json`: 13 small cases, independent watchdog, self-expiring fixtures,
  at most 64 MiB fixture allocation, unrelated sentinel preserved. The legacy
  oracle deliberately exposes an orphan under the old policy, then cleans only
  that exact recorded identity. This is not a rerun of the unbounded Swift hang.
- `harness.json` / `.log`: 31 Python regression tests; includes identity races,
  clock rollback, missing telemetry, finite admission and existing harness tests.
- `swift-smoke.json` / `.log`: eight real AboutVersion XCTest cases passed under
  the repaired supervisor in an isolated copy; no owned live descendants remain.
- `review.json`: independent candidate review reconciled with exact-source
  execution; three initial review findings were fixed before final acceptance.

Commands: `python3 Scripts/Testing/bootstrap_supervision.py`; snapshot harness
`python3 docs/reliability/handoffs/harness/run-focused.py AboutVersionTests 240`;
snapshot `python3 -m unittest discover -s Scripts/Testing -p 'test_*.py'` through
the shared `run_command` (30 seconds). No app installation, live-store access,
production notifications or broad process termination occurred.

Two earlier Swift admissions stopped conservatively on an unresolved process
classification error and verified cleanup. They are not passing tests. The
final classification excludes only proven unrelated birth chains; it does not
ignore unresolved telemetry. Initial fixture-evidence atomicity and selector
cancellation failures were also corrected before the retained passing run.

Limits remain explicit: reviewed cooperative process trees, sampled quotas,
non-atomic check-then-signal on macOS. Legacy soak/scale/corpus and rollback
entry points are disabled before side effects until their setup and storage
quotas are migrated. This task does not satisfy their future release gates.
