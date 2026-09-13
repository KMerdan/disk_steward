# Actionable evidence export contract

Status: normative version 1 contract for `PLAN-DISK-STEWARD-002`.

## Purpose

`Export Current Evidence` is an actor-visible product action, not a capacity
snapshot shortcut. It exports one consistent read view of the durable
`EvidenceStore` so a human or local read-only agent can select the next
investigation without opening SQLite or rescanning the disk.

The export is evidence for review. It never deletes files, recommends an
automatic cleanup, or claims that recorded allocated bytes equal reclaimable
whole-volume bytes.

## Scope vocabulary

Every brief, manifest, structured payload, UI status, and MCP response uses the
following terms consistently:

- **Volume capacity scope**: local volumes for which total, used, and available
  bytes were sampled. This can be whole-volume even when no file path on that
  volume was enumerated.
- **File-detail roots**: configured roots whose metadata is eligible for
  traversal. File-level claims never extend outside this list.
- **Exclusions**: paths, depth rules, cloud placeholders, volume classes, and
  privacy rules intentionally omitted from file-detail coverage.
- **Scan generation**: a scope-version-bound attempt to enumerate every eligible
  object under one file-detail root, possibly across many bounded slices.
- **Coverage state**: `complete`, `partial`, `stale`, or `unavailable` for file
  detail. Capacity scope is reported separately and cannot promote this state.
- **State as of**: the observation or completed generation supporting current
  state. An in-progress generation does not advance it.
- **Open gap**: a durable interval or root limitation that weakens a result.
  An open gap must appear in both structured coverage and human limitations.

The phrase “whole disk” is permitted only for volume-capacity sampling. It must
never describe file-detail, provenance, cleanup-candidate, or creator coverage.

## One-view export transaction

The application owns the export. It requests a consistent EvidenceStore view,
writes payloads into a new staging directory, validates membership and hashes,
atomically publishes the manual bundle, records its manual ownership, then
reveals it to the user. Failure leaves no available export record and reports a
recoverable UI error.

The menu and status-board action must call this path asynchronously. The legacy
three-file `SnapshotExporter` may remain a narrowly named capacity diagnostic,
but it is not the implementation of `Export Current Evidence`.

Manual exports are user-owned and are never removed by retention. Agent-serving
temporary exports follow the temporary lifecycle and are destroyed after use.

## Required bundle roles

`manifest.json` is authoritative for bundle membership. Every manual current
evidence bundle contains these semantic roles with lowercase SHA-256 digests and
byte counts:

| Role | Canonical payload | Decision supported |
| --- | --- | --- |
| `codex-brief` | `codex-brief.md` | Human and agent inspection order |
| `summary` | `summary.json` | Counts, time range, deltas, and top-level confidence |
| `summary` | `rollups.json` | Retained hourly and daily change evidence |
| `events` | `events.jsonl.zlib` | Bounded exact retained change records |
| `snapshot` | `snapshots.json` | Whole-volume capacity history |
| `current-state` | `current-state.json` | Present, stale, unknown, and out-of-scope objects |
| `provenance` | `provenance.json` | Confidence-labelled actor claims and contradictions |
| `agent-sessions` | `sessions.json` | Sanitized session context and lifecycle |
| `coverage` | `coverage.json` | Roots, exclusions, generations, gaps, and data age |
| `lifecycle` | `lifecycle.json` | Retained ranges, precision, storage pressure, exports |
| `integrity` | `integrity.json` | Hash and byte verification for every non-manifest payload |

An empty evidence class is represented by a valid payload with an empty record
array plus an explicit limitation. Omitting the payload is invalid. Unlisted
files, duplicate canonical paths, missing required roles, digest mismatches, or
an integrity file that does not cover every other payload invalidate the bundle.
The shared `export-manifest-v1` remains a generic closed integrity envelope so
the separately named capacity diagnostic stays readable; actionable role
completeness is enforced by `actionable-export-v1` and its semantic tests.

## Decision-focused brief

The brief is derived only from structured payloads in the same view. It leads
with, in order:

1. evidence time and age;
2. volume-capacity scope versus exact file-detail roots;
3. coverage confidence, last complete generation, in-progress generation, and
   open gaps;
4. largest current directory and file consumers inside covered roots;
5. recent growth, shrinkage, and the retained interval—or an explicit statement
   that no trustworthy change history is available;
6. cleanup-review leads restricted to present, recently revalidated objects;
7. provenance and agent-session confidence;
8. lifecycle and retained precision; and
9. limitations followed by an exact payload inspection order.

“No measured growth” is valid only when two comparable complete generations or
another trustworthy source cover the interval. Zero change events after only
partial generations is “growth unavailable”, not zero growth.

## Bounded exact detail

The export is bounded by the evidence database retention policy and an explicit
per-export record limit. Filtering and stable ordering occur before the limit.
Truncation records the filter, ordering, total matching count when available,
emitted count, continuation or retained-range guidance, and a limitation. The
brief may summarize records but never replaces the machine-readable current
state needed to inspect a named consumer.

## Privacy and redaction

Exports contain metadata, never file contents or environment values. Path detail
uses the requested full, basename, or hashed shape consistently across every
payload. Command arguments and path-like strings pass through the same secret
redaction rules. Missing provenance remains unknown; it is never synthesized
from filenames, modification times, or nearby sessions.

## Validation

`Schemas/Evidence/actionable-export-v1.schema.json` specifies the contract
fixture. Contract tests additionally enforce required role membership, unique
paths, open-gap limitation honesty, coverage terminology, and the difference
between trustworthy zero growth and unavailable growth.
