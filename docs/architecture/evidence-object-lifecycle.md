# Evidence identity and object lifecycle

Status: normative version 1 contract for `PLAN-DISK-STEWARD-002`.

## Questions every result answers

Every UI, export, or MCP result distinguishes:

1. what exists now;
2. what changed in the requested interval;
3. when it was observed and the occurrence interval actually justified;
4. which source and coverage support the result;
5. who or which session caused it, if supportable;
6. which precision retention removed; and
7. which roots or intervals were incomplete, unavailable, excluded, or unseen.

Absence from a scan is not automatically proof of deletion. Historical growth
is not proof that an object still exists.

## Core invariants

- `current` means present in the newest complete observation for the applicable
  root and scope version.
- `deleted` requires a previously present object plus a later complete
  same-scope observation proving absence, or a trusted direct delete event.
- Failed, partial, capped, permission-denied, excluded, or unavailable
  observations produce `unknown`, `stale`, or `out-of-scope`, never deletion.
- A path is a time-bounded binding, not permanent object identity. Path reuse
  with a different identity creates a new object.
- A first complete observation is a baseline, not proof of creation.
- Every change links its before and after observations or explicitly records a
  missing side.
- `detected_at` is not exact `occurred_at`. Periodic observations justify an
  `occurred_between` interval unless a direct source narrows it.
- Immutable history and the materialized `CurrentFileState` projection are
  separate. They commit atomically.
- Retention and replay cannot resurrect deleted objects or remove present
  current state.
- Cleanup candidates originate only from present, recently revalidated current
  objects. Historical events are never candidates by themselves.
- Query filtering and ordering happen before limits and privacy shaping.
- Provenance is a separate claim; a registered agent session is context, not
  proof of a write.
- Partial coverage, event loss, offline time, compaction, and forced eviction
  create durable `CoverageGap` records.
- No MCP method mutates files, evidence, policy, settings, sessions, or exports.

## Persistent object lifecycle matrix

| Object | Required identity and lifecycle | Retention |
| --- | --- | --- |
| `ScopeVersion` | Stable ID, effective interval, roots, exclusions, investigations, scan limits and filesystem policy. `prepared → active → superseded`. | Retain while referenced by current or retained history. |
| `ObservationRun` | Stable ID, scope, trigger, start/end, source cursor, per-root completion, limits and errors. `started → complete / partial / failed`. | Raw-detail window, then summarized coverage. |
| `FileObject` | Stable object ID, volume and filesystem identity plus identity method and first/last observed times. `discovered → present → changed / moved / deleted / unknown / out-of-scope`. | Present state remains current; historical tombstones follow history retention. |
| `PathBinding` | Object, normalized path, valid-from/to, opening/closing reason and confidence. Rename changes bindings, not object identity. | While current or referenced by retained history. |
| `FileStateObservation` | Immutable object/path state: logical bytes, allocated bytes, modification time, existence result, source references and confidence. | Raw-detail window, then eligible for rollup/expiry. |
| `CurrentFileState` | Atomic projection keyed by current object/path with state-as-of observation and coverage. | Retained while present/in-scope; bounded independently from chronological history. |
| `ChangeEvent` | Baseline, create, modify, truncate, rename, replace, delete, scope-enter or scope-exit; before/after links, signed deltas and occurrence interval. `observed → reconciled → attributed → detailed → rolled-up → expired`. | Raw-detail window; corrections supersede rather than invisibly rewrite. |
| `ProvenanceClaim` | Event, source method, actor if observed, session if supported, confidence, basis, limitations, contradictions and supersession. `unknown → inferred / tool-linked / exact`. | Raw-detail window; rollups retain confidence distributions without promotion. |
| `AgentSession` | Registration, provider, session, process identity, workspace roots and registered/expires/ended times. `active → ended / expired / interrupted`. | Sanitized metadata retained long enough for historical impact; no secrets. |
| `CoverageGap` | Source/root, interval, reason, affected precision, detected/resolved time. `open → resolved`. | Retained at least as long as any result whose interpretation it limits. |
| `RollupBucket` | Tier, interval, scope/category/object dimensions, operation counts, signed deltas, confidence distribution and coverage flags. `open → finalized → compacted → expired`. | Hourly then daily policy windows. |
| `RetentionRun` | Policy, trigger, interval, before/after bytes and rows, rolled-up/expired/forced rows, gaps and result. `started → completed / failed`. | Retained with lifecycle diagnostics. |
| `ExportRecord` | Export ID, manual/temporary type, requested/actual coverage, privacy shape, path if manual, bytes and manifest digest. | Manual `creating → available → missing`; temporary `creating → served → destroyed`. |
| `MCPAccessState` | Persistent preference, effective state, changed time and failure. `disabled ↔ starting ↔ enabled`, or `degraded`. | Latest state plus bounded diagnostic history. |

## Reconciliation state machine

| Before | New observation | Coverage | Result |
| --- | --- | --- | --- |
| unseen | present | complete | baseline at startup/scope entry; create only when the interval proves creation |
| present | same object/path, unchanged | complete | retain present; no change event |
| present | same object/path, size changed | complete | modify or truncate with signed deltas |
| present | same object, different path | complete/direct hint | rename; close/open path bindings for one object |
| present | different object, same path | complete | replace; delete old lifecycle and create/baseline new object |
| present | absent | complete, same scope | delete and close binding |
| present | absent | partial/failed/capped | unknown/stale plus gap; never delete |
| present | excluded/root removed | new scope | out-of-scope; never delete |
| deleted | same path, new object | complete | new lifecycle; never resurrect the old object |
| unknown | present later | complete | recover current state; changes during the gap remain interval-bounded |
| unknown | absent later | complete | delete only across the wider last-known-present to complete-absence interval |

## Atomicity and recovery

One SQLite transaction commits an observation run, root coverage, state
observations, reconciled changes, path-binding changes, current projection, and
coverage gaps. The observation ID is an idempotency key. A duplicate delivery
does not duplicate events. A failed transaction exposes none of its derived
state and leaves the previous current projection intact.

On restart, open observation runs become failed and unclosed agent sessions
become interrupted. The next scan reconciles from the last committed state and
records the offline interval. It never assigns all offline changes to startup.
Migration creates new tables and indexes before activating the new schema and
preserves legacy events as historical-only evidence with explicit weaker
identity and coverage.

Replay of retained raw observations must derive the same current projection.
After raw-detail compaction, a projection checkpoint plus retained changes and
coverage records must derive the same result. Any mismatch is corruption and
must fail closed.

## Bounded scan-generation lifecycle

An entry or time cap bounds one work slice, not the lifetime coverage of a root.
Each configured root has at most one active generation for a `ScopeVersion`.
The durable generation record contains its ID, scope version, normalized root,
deterministic traversal version, start time, last progress time, next frontier
or cursor, staged-object count, completed-slice count, limitations, and state:
`started`, `in-progress`, `complete`, or `abandoned`.

Every slice:

1. validates that the scope version, root identity, exclusions, traversal
   version, and cursor still match;
2. observes at most the configured entry and time budget into generation-local
   staging keyed by generation and object identity;
3. atomically stores staged rows, the next frontier, counts, and limitations;
4. leaves authoritative `CurrentFileState`, absence, and deletion unchanged
   while more frontier remains; and
5. closes the entry-cap gap only when the generation has enumerated every
   eligible entry without an unresolved permission, depth, or source error.

Completion atomically promotes the staged full-root set into one
`ObservationRun`, reconciles it against the last complete same-scope generation,
updates path bindings and current state, emits changes, closes resolved gaps,
and retires the staging rows. A first complete generation is a baseline. A later
complete generation can prove A/B/C deletion. Partial slices never do.

After restart, a valid persisted frontier resumes the same generation without
duplicating staged objects. An invalid frontier or changed scope, root,
exclusion, or traversal version abandons the old generation with a durable gap
and starts a new generation. Abandonment never promotes its staged rows or
fabricates deletion. Stale abandoned staging is removed under bounded retention
only after its coverage record is durable.

Status, export, and MCP diagnostics expose configured roots, exclusions, active
generation progress, completed and estimated work when knowable, last complete
generation time, current-state age, and `complete`, `partial`, `stale`, or
`unavailable` coverage. They do not represent a repeatedly capped first slice as
ongoing whole-root monitoring.

## Normative A/B/C scenarios

Complete case:

1. Complete baseline `O1` observes objects A, B, and C. Current state is A, B,
   C; no creator is claimed.
2. B is removed.
3. Complete same-scope observation `O2` sees A and C.
4. Reconciliation emits `delete(B)` linked from O1 to O2, closes B's binding,
   records negative before-size deltas, sets `detected_at` to O2, and uses
   `[O1, O2]` as the occurrence interval unless direct evidence narrows it.
5. The same transaction replaces current state with A and C. B remains only as
   a historical tombstone while retained.

Partial case:

If O2 is partial, capped, denied, or unavailable, B remains non-actionable
`unknown/stale`; a gap is recorded and no delete is emitted. A later complete
observation may prove deletion only across the wider justified interval.

## Honest filesystem limits

Stable identity uses volume plus file identifier and generation when available.
Path-temporal fallback cannot prove rename or replacement. APFS clones,
compression, purgeable space, snapshots, hard links, and shared extents mean a
path's allocated bytes may not equal reclaimable whole-volume bytes. A file
created and deleted entirely between observations is unknowable unless a direct
event source observed it.
