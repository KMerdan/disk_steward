# TASK-613 — The object row, and collapsing per-file rows into it

Actor: `claude`, 2026-09-20. Focused runs on input `ff1fb5e6d8ed…`; the full verifier run and the rollback rehearsal are recorded below. No live evidence database was opened: every run uses a store created inside an isolated snapshot under `/private/tmp`.

## What was added

**Schema 15** (`EvidenceStore.swift`): `current_objects`, one row per classified object, keyed by path. It carries the detection evidence the contract requires (kind, rule, confidence, the sentence shown to a person, owning project and marker), the aggregates (`logical_bytes`, `file_count`, `measured_at`, `dirty`), `project_last_activity`, `rebuild_command`, and `review_required`.

Two constraints put contract rules in the schema rather than in a convention:

- `CHECK(review_required = 1)` — a stored object always requires review.
- `CHECK((logical_bytes = 0 AND file_count = 0) OR measured_at IS NOT NULL)` — a size without the time it was measured cannot be written at all.

**`EvidenceStore+Objects.swift`**: `StoredObject`, `recordObjects`, `currentObjects`, `cleanupCandidateObjects` (which never returns a repository), `currentFileStateDirectories` (the directories a migration asks the classifier about, rather than asking about every file), and `collapsePerFileRows(into:checkpoint:)`.

The collapse is per object and transactional. For each object it writes the object row, closes the open path bindings beneath it, and deletes the `current_file_state` rows beneath it, all in one transaction. The `checkpoint` closure runs *before* each object's transaction and may throw `CollapseInterruption` to stop: everything already committed stands, nothing is half-written, and running the collapse again continues from where it stopped.

Deleting is bounded by an explicit upper key (`path >= prefix AND path < prefix + U+10FFFF`), so a collapse can only ever touch rows inside its own object.

Bindings are **closed, not deleted**: the history of what was there stays readable, which is what keeps a collapse from destroying evidence.

## Proofs (AC-TASK-613-01)

| case | test |
|---|---|
| schema upgrade exposes object rows and keeps existing evidence | `testSchemaUpgradeAddsObjectRowsAndKeepsExistingEvidence` |
| a row keeps its detection evidence and reads back whole | `testAnObjectRowKeepsItsDetectionEvidenceAndIsReadBackWhole` |
| a repository is stored but never a candidate | `testARepositoryIsStoredButNeverACleanupCandidate` |
| a size without its measurement time is refused | `testAnAggregateWithoutTheTimeItWasMeasuredIsRefused` |
| collapse removes only rows inside the object; other evidence is identical | `testCollapseRemovesOnlyRowsInsideObjectsAndLeavesOtherEvidenceIdentical` |
| an interrupted collapse commits what it finished and resumes | `testAnInterruptedCollapseCommitsWhatItFinishedAndResumes` |
| collapsing twice changes nothing the second time | `testCollapseIsIdempotent` |
| the directories to classify are reported, not every file | `testDirectoriesOfCurrentRowsAreReportedForClassification` |

Eight tests, zero failures (`focused-green/`).

## Non-vacuity

| mutation | result |
|---|---|
| the delete loses its upper bound, so it can reach past the object | three collapse tests fail (`collapse-scope-mutation-red/`) |
| the measurement-time constraint is removed | `testAnAggregateWithoutTheTimeItWasMeasuredIsRefused` fails (`measured-mutation-red/`) |
| `isCleanupCandidate` returns true for everything | the repository cases in both suites fail (`repository-offered-mutation-red/`) |

A fourth mutation was tried and discarded: moving the checkpoint inside the transaction. It changed nothing observable, because a throw inside the transaction rolls back the same work the outer form never started. It is recorded here rather than dressed up as a passing red.

## Migration and rollback

`rollback-rehearsal/` holds the run of `Scripts/Testing/rehearse_migration_rollback.py`: a store written by the baseline library at the previous schema, migrated by this candidate, interrupted at each exposed checkpoint and recovered, with the baseline binary refusing the newer schema on a scratch copy and the restored backup opening again with the baseline. The report names the exact baseline commit and candidate input.

## Limitations

- The collapse takes the objects it is given. Choosing them by classifying a real store's directories is wired up in `TASK-612`, which also proves that a scan publishes them.
- Aggregates are whatever the caller supplies; nothing measures a subtree yet. That is `TASK-621`, and until then most rows carry zero bytes with no `measured_at`, which the schema permits and a reader must respect.
- The tests seed current state through the public observation API, so they exercise the same publication path the app uses, but at a few rows rather than at the scale of a real store.
