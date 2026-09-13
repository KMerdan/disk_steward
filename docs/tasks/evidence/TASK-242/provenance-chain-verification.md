# TASK-242 provenance and session lifecycle verification

Verified candidate: the working tree for `PLAN-DISK-STEWARD-002`, revision 3.

## Durable chain

1. A committed observation run is the required parent for every persisted FSEvents hint. The hint retains its event identifier, raw flags, decoded rename/drop signals, rescan requirement, and limitations.
2. An Endpoint Security observation is stored as its own stronger evidence object. It may link to an observation and metadata event, but is never synthesized from an FSEvents hint or confidence label.
3. A provenance claim links one metadata event to its detection time, bounded occurrence interval, method, confidence, basis, optional observed process and ancestry, optional authenticated session, contradictions, and support references.
4. A later claim may supersede exactly one earlier claim for the same event. Both remain queryable; the earlier row records its successor and current-only queries return only the unsuperseded claim. Reused or conflicting identifiers fail closed.
5. Agent-session registrations persist immutable process/session/workspace/task identity plus start, heartbeat, expiry, end, lifecycle, and authentication summary. Heartbeats are monotonic and never shorten a lease. Ended and expired records cannot be rewritten.
6. Historical task-impact queries load retained sessions after app restart and use SQLite timestamps directly. This avoids presentation timestamp rounding at session boundaries. Workspace/time correlation is labeled `inferred`; an active or retained session alone is never reported as the writer.
7. Rename, delete, path replacement, overlapping workspaces, event-stream gaps, offline intervals, and absent privileged evidence resolve to an ordered chain with explicit limitations or `unknown` authorship rather than an invented actor.
8. Evidence exports include persisted actor, ancestry, session, method, confidence, contradictions, and support when a claim exists. Schema-required unknown fields remain explicit JSON `null` values.

## Verification

- `swift test` — passed: 123 tests, 0 failures.
- Restart/session-boundary stress run — passed: 12 consecutive executions of `AppEvidenceIPCIntegrationTests/testEndedSessionHeartbeatAndHistoricalImpactSurviveBackendRestart`.
- Schema contract — `ContractTests/testEverySchemaIsClosedAndVersioned` passed for the added FSEvents, session, and provenance schemas.
- Export contract — `EvidenceBundleExporterTests/testGoldenBundleIsDeterministicSchemaValidAndIntegrityVerifiable` and `DurableProvenanceLifecycleTests/testEvidenceBundleExportsPersistedActorSessionMethodAndSupportWithoutSynthesis` passed.
- Attribution honesty — provenance, task-impact correlation, gap, overlap, restart, expiry, path-reuse, and unknown-actor fixtures passed.

## Known boundary

The standard application does not require Endpoint Security. Without direct privileged process-to-file evidence, FSEvents and session overlap can justify only inference or unknown attribution. This is an intentional trust boundary, not missing evidence represented as certainty.
