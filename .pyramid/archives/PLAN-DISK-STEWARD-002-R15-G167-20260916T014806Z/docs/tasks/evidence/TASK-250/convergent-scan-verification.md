# TASK-250 convergent scan verification

## Lifecycle

Disk Steward now stores a scan generation separately from authoritative file
state. A generation owns:

- its immutable scope version, configured roots, and exclusions;
- a per-root directory frontier with the last processed child name;
- processed-entry and staged-file counts;
- start, update, and completion times;
- root status and explicit limitations;
- metadata-only staged file records keyed by path.

Each monitoring sample advances at most the configured entry budget. Capacity
snapshots remain independently durable on every sample, while staged file
metadata does not alter `current_file_state`, events, or absence semantics.
When all included roots complete, the staged set becomes one idempotent
observation and the existing reconciler applies it. A crash after staging or at
the completion boundary is safe: the persisted frontier resumes, and the
generation observation identifier makes completion replay idempotent.

Completed and abandoned generations discard their staging rows. Generation
history is capped at 64 non-active records. Thus progress survives restart but
does not grow without bound.

## Failure behavior

- A changed scope version abandons the old generation, records an explicit
  limitation, deletes its staging rows, and starts a new generation.
- A missing root, inaccessible directory, metadata failure, or invalid saved
  directory cursor abandons the generation without reconciling absence.
- While a generation is active, lifecycle/query status reports partial detail
  coverage and emits `scan-generation-incomplete` gaps for unfinished roots.
- Only a fully completed generation may resolve old absence and emit delete,
  rename, replacement, modification, truncation, or creation evidence.

## A/B/C proof

`ConvergentScanGenerationTests` uses a two-entry slice budget against three
files. It verifies the first slice leaves authoritative state empty, closes and
reopens the database, resumes the same generation and exact progress, then
finishes with A/B/C exactly once. After B is removed, every incomplete slice
still exposes A/B/C and no delete event; only full second-generation completion
emits one deletion for B and leaves A/C.

The companion case persists a frontier into a directory, removes that
directory, and proves the cursor is abandoned without current-state mutation.
It then changes exclusions mid-generation and proves the old staging is
abandoned, the new scope is visible, and lifecycle/MCP coverage is partial.

## Verification

- Focused scanner, store, reconciler, and app lifecycle set: 30 tests passed,
  0 failures.
- Final adversarial/lifecycle set: 13 tests passed, 0 failures.
- Full Swift package suite: 155 tests passed, 0 failures.
- Scoped `git diff --check`: passed.
