# Privacy and retention controls

Disk Steward observes metadata, never file contents or environment variables. Users can exclude subtrees and choose full, basename-only, or one-way hashed paths. Configured sensitive values are replaced in paths, commands, and executable locations before persistence or presentation.

Raw event, state, and provenance detail is retained for 7 days by default.
Anomaly detail has a 30-day maximum, hourly summaries extend through day 30,
and daily summaries through day 365. Repeated capacity snapshots are
downsampled deterministically. The evidence database has a 512 MiB default hard
ceiling.

Current in-scope state is stored separately from chronological history and
remains while an object is present. Deleted and out-of-scope tombstones expire
with history; expiry cannot add an object back to current state. Retention runs
at startup, at least every six hours while active, and promptly near the byte
ceiling. It first rolls up eligible detail, then expires globally oldest
history. Forced loss creates a durable coverage gap before removal.

Manual exports are user-owned and never automatically deleted. Disk Steward
records their bounded app-folder inventory and observes when the user moves or
deletes one. MCP temporary exports are destroyed immediately after serving.
Export history is capped at 512 records. When a new export begins, the oldest
completed record is retired first; an in-progress record is never pruned, and a
new request is rejected if 512 exports are simultaneously in progress. A
creating or served export left unfinished for more than six hours is recovered
as failed at the next store open. Retention-run history is capped at 1,500
records (roughly one year at the six-hour schedule). Open coverage gaps remain
until their affected loss is quantified; completed gap records expire with the
daily-history horizon.
Endpoint event queues are bounded by count and estimated bytes; overflow is
recorded as evidence loss and disables exact attribution across the gap.

The declared default operating budgets are: under 1% idle CPU, under 15% CPU while processing load, under 150 MiB resident memory, no more than 4,096 pending privileged events, no more than 1% event loss under declared load, and no more than 512 MiB for the evidence database. Measurements above a limit are visible and require backpressure or degraded operation.
