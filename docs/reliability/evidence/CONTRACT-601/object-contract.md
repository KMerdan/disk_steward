# CONTRACT-601 — Object evidence and safety contract

Actor: `claude`, 2026-09-20. This contract governs every node of
`PLAN-DISK-STEWARD-006`. Each rule below names the task that must prove it and
the check that will hold it. Nothing here is proven by this note itself: it is
the contract the later tasks are audited against.

## 1. What an object is

An object is a directory that Disk Steward records as **one** piece of evidence
and never enumerates inside. Three kinds:

| kind | example | cleanup stance |
|---|---|---|
| `artifact` | `node_modules`, `target`, a virtual environment | reclaimable, review required |
| `cache` | a shared tool cache outside any project | reclaimable, review required |
| `repository` | a `.git` directory | measured, **never offered** |

Only the outermost qualifying directory becomes an object. Nothing inside an
object is a candidate, an object, or a per-file row.

## 2. Row shape

An object row carries exactly these fields. A reader that cannot fill one
records it absent rather than inferring it.

| field | meaning |
|---|---|
| `path` | absolute path of the object |
| `kind` | `artifact`, `cache` or `repository` |
| `detection_rule` | the rule that decided it (section 3) |
| `confidence` | `high` or `medium` (section 4) |
| `reason` | one sentence naming the evidence, shown to the user verbatim |
| `owning_project` | project root and the marker that identified it, or absent |
| `bytes`, `file_count` | aggregate size and count, logical bytes |
| `measured_at` | when those aggregates were last computed |
| `dirty` | whether a change was observed since `measured_at` |
| `project_last_activity` | newest activity of the owning project, or absent |
| `rebuild` | the command that regenerates it, or an explicit unknown |
| `review_required` | always true for a candidate; a repository is never a candidate |

Per-file rows for paths inside an object must not exist. **Proved by TASK-612
and TASK-613**; a store holding any such row after migration fails
`AC-TASK-613-01`.

## 3. Detection rules

The rules and their order are fixed by `RESEARCH-601`
(`docs/reliability/evidence/RESEARCH-601/detection-rules.md`):

1. `tracked` — the owning repository tracks files inside it. **Never an object.**
2. `self-marker` — a marker inside it identifies it (`pyvenv.cfg`, `CACHEDIR.TAG`).
3. `content` — its contents identify it (only compiled bytecode; installed
   packages carrying their own manifests).
4. `ignored` — the owning repository ignores it.
5. `manifest` — a project manifest beside it expects that output location.
6. `unresolved` — a known output name with no project evidence. **Not classified.**

A directory name alone never classifies. Detection must not execute project
tooling, must not write to the measured tree, and must treat an unreadable
repository as deciding nothing. **Proved by TASK-611**, whose fixtures include
the tracked lookalikes the corpus produced.

## 4. Confidence vocabulary

- `high` — decided by `tracked`, `self-marker`, `content`, `ignored` or `repository`.
- `medium` — decided by `manifest`.
- No object is recorded below `medium`. An `unresolved` candidate is not an
  object and is reported, if at all, as an explicit unknown the user may
  override. Confidence is never invented to fill a field. **Held by
  INSPECT rules at each gate.**

## 5. Never-classify and never-offer

- A directory tracked by its repository is never an object.
- A repository is measured and **never** offered as a cleanup candidate, even
  when everything in it is pushed.
- An object is never deleted, moved or modified by Disk Steward. Cleanup stays
  a reviewed, user-initiated action outside this intent.
- `review_required` is always true on a candidate; no surface may present an
  object as safe to delete without review. **Proved by TASK-622 and TASK-623.**

## 6. Sizing and staleness

- Aggregates are logical `lstat` bytes and a file count, not allocated blocks.
  The difference is stated wherever a size is shown.
- `measured_at` is the time the aggregate was computed. A size without it is
  not publishable.
- A change observed beneath an object sets `dirty`; the aggregate is
  recomputed on a bounded schedule, not on every scan. A `dirty` object shows
  its last measurement with its staleness, never a guess.
- Sizing must stay inside the existing resource budgets on the largest object
  in the corpus. **Proved by TASK-621** (assumption `ASM-602`).

## 7. Migration and rollback

- Migrating an installed store collapses per-file rows inside objects into
  their object row, preserves unrelated evidence, history and exports
  byte-for-byte, and is interruptible at every checkpoint.
- A rehearsed rollback restores the previous schema with the compatible
  previous binary, using `Scripts/Testing/rehearse_migration_rollback.py` as
  the closed plan established.
- Migration is exercised against a **captured copy** of a real store. The
  user's live evidence database is never opened by tests or measurements.
  **Proved by TASK-613** (assumption `ASM-603`).

## 8. Capacity honesty

When the configured scope cannot fit the configured limit, the app states the
shortfall and the available remedies once, and stops re-staging. An endless
active generation that reports healthy is a defect, not a degraded mode.
**Proved by TASK-614**, whose fixture reproduces the loop observed on the
installed 1.2.1 app (`EV-604-STUCK-SCAN`).

## 9. Inherited constraints

The closed reliability plan's guarantees continue to hold and are not re-proven
here: bounded resources under the circuit breaker, test isolation from the
installed app and its data, conflict-safe client configuration, and recoverable
migration. Any node of this plan that weakens one of them fails its gate.
