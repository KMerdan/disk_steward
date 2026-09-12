# Privacy and retention controls

Disk Steward observes metadata, never file contents or environment variables. Users can exclude subtrees and choose full, basename-only, or one-way hashed paths. Configured sensitive values are replaced in paths, commands, and executable locations before persistence or presentation.

Raw evidence is bounded by the existing retention policy: 7 days by default and a 512 MiB database ceiling, with hourly and daily rollups retained longer. Unreviewed anomalies may be preserved inside that cap. Endpoint event queues are bounded by count and estimated bytes; overflow is recorded as evidence loss and disables exact attribution across the gap.

The declared default operating budgets are: under 1% idle CPU, under 15% CPU while processing load, under 150 MiB resident memory, no more than 4,096 pending privileged events, no more than 1% event loss under declared load, and no more than 512 MiB for the evidence database. Measurements above a limit are visible and require backpressure or degraded operation.
