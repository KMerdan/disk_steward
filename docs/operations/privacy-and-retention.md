# Privacy and retention controls

Disk Steward observes metadata, never file contents or environment variables. Users can exclude subtrees and choose full, basename-only, or one-way hashed paths. Configured sensitive values are replaced in paths, commands, and executable locations before persistence or presentation.

## What is kept (since 1.4)

Disk Steward no longer scans files while idle and keeps no row per file. It
keeps two small files under the 32 MiB ceiling of CONTRACT-602, each table with
a hard row and byte cap that evicts its oldest rows in the inserting
transaction, so there is no storage pressure and no pressure retention:

- **`capacity.sqlite`**: volume capacity samples, every few minutes for about a
  week and hourly for about a year.
- **`steward.sqlite`**: the directory-level change journal (7 days of changed
  folders, never files), the object index (the 20,000 largest measured build
  outputs, environments and caches, with no files inside them), review reports
  (20) and their ranked items, agent sessions (500) and their kept directory
  impact. The write-ahead log is limited to 4 MiB.

Beside them, `review-state.json` holds each review scope's cooldown and
`growth-attributions.json` the last 8 growth attributions (at most 512 KiB).

## Legacy evidence

The per-file evidence store of earlier versions is renamed unchanged into
`legacy/` on first launch of 1.4 and never written again. It can be exported to
a file from Settings and, when it fits, inline through `export_evidence`; both
read a clone. It is deleted only after the user confirms.

## Exports

Manual exports are user-owned and never automatically deleted. MCP temporary
exports are destroyed immediately after serving.

## Operating budgets

Idle cost is event-driven only: the declared budget is under 0.5% of one core
on average over an hour. A review is limited to 120 s, 5 million entries and
256 MiB of memory; `measure_path` to 15 s and 500,000 entries. A stopped review
or measurement produces a partial report that states its covered scope.
Endpoint event queues are bounded by count and estimated bytes; overflow is
recorded as evidence loss.
