# Evidence, Privacy, and Export Contract

Status: version 1 contract, extended by `evidence-object-lifecycle.md` for
`PLAN-DISK-STEWARD-002`.

## Ownership boundaries

- `DiskStewardCore` owns normalized models, confidence semantics, policy evaluation, retention, redaction, explanation, and export generation.
- Collectors emit observations; they never label unsupported attribution as exact.
- The application process owns the evidence database and export transaction. UI and MCP clients consume sanitized service responses rather than opening the database directly.
- The future Endpoint Security extension is notification-only, filters events before IPC, never blocks filesystem operations, and reports gaps or overload explicitly.
- The MCP process is read-only. It cannot delete files, stop processes, alter monitoring policy, or access the SQLite file directly.

## Monitoring scope

Whole-volume capacity is sampled for accessible local volumes. Detailed evidence is limited to the union of configured watched roots, registered local agent process trees, and time-bounded investigation scopes. External, network, Time Machine, and cloud-placeholder volumes are excluded by default.

An unexplained delta is evidence, not an error: it must remain attributed as `unknown` or `inferred` with limitations until a stronger observation exists.

## Attribution confidence

- `exact`: a live observer directly connected the file operation to a process identity. The supporting event reference is retained.
- `tool-linked`: a registered tool/session and process ancestry establish the task link, but the filesystem actor was not independently observed at the strongest level.
- `inferred`: timestamps, FSEvents, snapshots, or nearby process activity support a hypothesis but do not prove a creator.
- `unknown`: the available evidence does not support an actor or session claim.

Every event carries both `confidence` and `method`, plus limitations and supporting evidence references. Historical timestamps alone never produce `exact` attribution.

## Size semantics

Logical and allocated byte values are separate. A missing observation is `null`; zero means an observed zero. Deltas are signed integers. Collectors may coalesce repeated writes into one `write-summary`, but must retain the observation window and supporting references in their internal record.

## Current state versus history

The authoritative answer to “what exists now?” comes from `CurrentFileState`,
not from summing historical event deltas. Immutable observation and change
history explains how state changed. Both are linked through file-object identity,
temporal path bindings, scope versions, and per-root coverage. The complete
state machine, atomic transaction, restart, replay, path-reuse, and A/B/C
deletion rules are normative in `evidence-object-lifecycle.md`.

## Privacy and redaction

Disk Steward records metadata, never file contents. Environment-variable capture is disabled. Command strings pass through argument redaction before persistence or export. Users can exclude paths and select full, basename-only, or hashed path detail for exports.

Unknown fields are rejected in version 1 evidence objects. This makes accidental additions such as `file_contents` fail closed instead of silently entering evidence.

## Retention and resource bounds

The policy schema imposes finite limits on raw events, observations, provenance,
anomalies, summaries, database bytes, and coalescing windows. Defaults are 7
days of raw detail, at most 30 days of anomaly detail, 30 days of hourly
summaries, 365 days of daily summaries, and a 512 MiB database ceiling.
Current present state is not chronological history and survives history
compaction. Reaching a limit triggers deterministic rollup or oldest-history
expiry plus a retention and coverage-loss record; it must not silently stop
collection or grow without bound.

## Export consistency and integrity

An export is created from one consistent database view. WAL-backed storage must use a transaction, checkpoint, or SQLite backup mechanism rather than copying only the main database file. The bundle manifest lists every payload path, semantic role, byte count, and lowercase SHA-256 digest. It also records limitations and privacy posture.

Required human and agent entry points are a concise `codex-brief.md` and structured JSON/NDJSON detail. The manifest is authoritative for bundle membership; unlisted payloads invalidate the export.

## Service and error states

- `active`: promised standard monitoring is operating.
- `degraded`: useful evidence continues, but a collector, privilege, event window, or storage limit has reduced fidelity.
- `paused`: the user intentionally suspended monitoring.
- `unavailable`: no trustworthy result can currently be served.

Errors are returned as structured status with component, reason, limitations, and recovery guidance at the service layer. A missing app, unavailable extension, permission denial, dropped event, corrupt database, unsupported schema, and oversized MCP response are distinct conditions. None permits fabricated data or a silent downgrade.

## Versioning

All persisted and exported top-level objects contain a stable schema discriminator. Version 1 readers reject unsupported versions. Additive fields require a schema revision because version 1 uses closed objects to preserve privacy review and deterministic exports.
