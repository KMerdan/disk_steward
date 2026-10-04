# Bounded store contract (CONTRACT-602)

Every table in the redesigned stores
(`docs/product/redesign-bounded-review.md`) follows these rules. They
replace the failure modes of the per-file evidence store: unbounded tables, a
summary that refused once a table grew, and retention that erased history to
make room. The code is `Sources/DiskStewardCore/EvidenceStore/BoundedStore.swift`
(`BoundedTable`, `BoundedStoreContract`, and `SQLiteConnection.insertBounded`
/ `readBoundedWindow`). The tests are in `BoundedStoreContractTests`.

## Rules

1. **Two caps per table.** Each table has a row cap and a payload byte cap.
   Payload bytes are the UTF-8 length of text columns plus 8 per numeric
   column. A write batch commits in one transaction, then one enforcement pass
   deletes rows by the table's eviction rule until both caps hold.
2. **Column limits are enforced at write.** Every text column has a byte
   limit; paths are limited to 1,024 bytes. A row that exceeds a limit is
   refused, and the writer receives the reason in `BoundedWriteReport.refused`.
   Readers therefore never meet an oversized row and never refuse a result.
3. **Only short keys are indexed.** Indexed columns are at most 64 bytes:
   ids, timestamps, and 32-byte `path_key` hashes when a lookup by path is
   needed. A path column is never indexed. Every eviction-order column is
   indexed.
4. **Eviction is defined per table:**
   - capacity samples: the oldest sample first;
   - journal: the oldest interval first, after the writer has already
     collapsed each interval to 2,000 directories, overflowing into parent
     directories;
   - objects: the oldest measurement first;
   - projects: the oldest source activity first;
   - reviews: the whole oldest report together with its items;
   - sessions: the whole oldest session together with its impacts.

   A group batch (one report or one session) must fit the caps on its own;
   otherwise the batch is refused whole (`batchExceedsCaps`). The report
   writer therefore truncates by rank to the byte budget, and records
   `total_items` and `truncated` on the report header. A binding cap
   produces a shorter report, never a refused one.
5. **Readers are windowed.** `readBoundedWindow` orders by an indexed column
   and returns `items`, `total` and `truncated`. It clamps the row limit so
   that a window of maximum-size rows stays under the 1 MiB response
   ceiling. A full table is listed in part; it is never refused.
6. **Files.** The capacity ring has its own file and its own connection,
   with a rollback journal and no `-wal` or `-shm` files. It is written once
   per sample interval, and capacity reads never open the steward file. The
   steward file uses a write-ahead log, limited by
   `journal_size_limit = 4 MiB`.

## Ceiling

The static check, `BoundedStoreContract.validateBudget()`, proves:

> sum over all tables of (byteCap + rowCap × indexed bytes per row) ≤ 32 MiB

"Indexed bytes per row" means each indexed column's limit plus 8 bytes for
the rowid. The check also rejects:

- an indexed column wider than 64 bytes;
- an eviction column that is not indexed;
- a table whose single maximum-size row exceeds its byte cap.

The ceiling bounds **live pages**. SQLite keeps freed pages on its freelist,
so after eviction a file stays at its steady-state maximum rather than
shrinking. The steward file's write-ahead log is bounded separately, at
4 MiB, and comes on top of the ceiling.

AC-CONTRACT-602-01 states the ceiling as "sum(cap × maximum row bytes)". This
contract meets it in byte-cap form. Row caps multiplied by worst-case paths
(1,024 bytes) would either force caps below what the maintainer's
`localGit` needs (3,700 objects), or count only typical rows. Each table's
payload is therefore capped directly in bytes, and the index term is counted
at worst case.

| File | Table | Row cap | Payload cap (MiB) | Index worst case (MiB) | Worst case (MiB) | Eviction |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| capacity ring | `capacity_volumes` | 16 | 0.03 | 0.00 | 0.03 | oldest first_seen_at |
| capacity ring | `capacity_fine` | 8,064 | 0.38 | 0.25 | 0.62 | oldest observed_at |
| capacity ring | `capacity_hourly` | 35,040 | 1.50 | 1.07 | 2.57 | oldest observed_at |
| steward | `journal_cursors` | 16 | 0.02 | 0.00 | 0.02 | oldest updated_at |
| steward | `journal_dirty` | 14,000 | 3.00 | 0.75 | 3.75 | oldest interval_start |
| steward | `projects` | 2,000 | 1.00 | 0.11 | 1.11 | oldest last_source_activity |
| steward | `object_index` | 20,000 | 6.00 | 2.59 | 8.59 | oldest measured_at |
| steward | `review_reports` | 20 | 0.12 | 0.00 | 0.13 | oldest started_at |
| steward | `review_items` | 40,000 | 6.00 | 2.75 | 8.75 | whole oldest report |
| steward | `sessions` | 500 | 0.50 | 0.04 | 0.54 | oldest started_at |
| steward | `session_impacts` | 10,000 | 1.50 | 0.84 | 2.34 | whole oldest session |
| **total** | | | | | **28.44** | |

## Changes from the design document

The data-model table in `redesign-bounded-review.md` used row caps only, and
its size estimates came out short:

- The capacity ring is about 3.2 MiB worst case, not under 1 MiB.
- Report items are capped at 40,000 rows and 6 MiB of payload; at worst-case
  path sizes, fewer than 40,000 fit in that budget.
- Session impacts are 10,000 rows, not 500 × 200.

This contract supersedes that table. The design document is corrected
separately.
