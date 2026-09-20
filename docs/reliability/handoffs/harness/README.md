# Isolated test harness used by PLAN-DISK-STEWARD-006

Current safety boundary: read [SUPERVISION.md](../../../../Scripts/Testing/SUPERVISION.md)
and pass its bounded bootstrap first. TASK-616 replaces group-only cleanup.
`object-scale.py` is currently refused before fixture creation; the historical
description below is not authorization to bypass that guard.

These scripts ran every focused suite and every mutation red in this plan. They
lived in a session scratchpad under `/private/tmp` and were lost once to a
cleanup, so they are kept here with the evidence they produced.

- `run-focused.py '<filter regex>' [timeout]` — copies the candidate inputs to a
  fresh snapshot outside the repository and runs a filtered suite there. The
  worktree is never built in or written to.
- `run-mutation.py <spec.json> '<filter regex>'` — the same, with the spec's
  replacements applied to the copy only. Each result records
  `repositoryUnchanged`, which must be `true`.
- `object-scale.py <objects> <files-per-object>` — builds a fixture whose files
  sit behind classified objects and runs the opt-in `ObjectScanScaleTests`
  against it.
- `mut-*.json` — the mutation specs, one per claimed non-vacuity red.

Never run `swift test` in the worktree: it would build against the developer's
checkout and can touch live state. Every run goes through a snapshot.
