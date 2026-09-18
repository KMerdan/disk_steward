# TASK-521 integration handoff

Source examined: 9688186dc6c2de154c66ec60982db1372551e2f26fdcf5b60f09bec4e285b238, 17 September 2026. These are required follow-through items within the existing reliability intent, not claims that the core patch completed the app/API integration.

## TASK-522: ordinary dirty signals and lifecycle

MonitoringLifecycleController's FSEvents callback currently invokes probe.noteEventGap only for batch.eventGap. Ordinary events schedule sampling but do not fence already-staged membership. Route ordinary coalesced root/path hints through the durable store invalidation boundary before committing later work; preserve root isolation, same-time signal identity, pending coverage and gap replay semantics from TASK-521. A dirty hint is not exact writer attribution. Use isolated controller/probe/store tests with a paused in-flight slice: mutate after producing/validating a pass, deliver the ordinary signal, then release the stale result and prove it cannot publish as current. Include pause/sleep/quit, next-run recovery and failed-root coverage. Core store tests alone are not this proof.

## TASK-552: public timestamp truth

EvidenceStore.insertChangeEvent now records nullable occurred_start, actual sample/absence occurred_end and separate detected_at. But EvidenceStoreEvent has no interval; ProvenanceInput and ProvenanceClaim still substitute event.observedAt for omitted bounds and use min/max to silently reorder them. ProvenanceClaimPayload and provenance-claim-v2.schema.json require both dates. Export and session/window overlap use provenance_claims rather than the corrected change_events interval. Inspect callers before selecting the coordinated public contract; do not simply make a schema field nullable and leave inference/overlap unchanged.

Required proof: carry known/unknown lower bounds and operation-specific upper bounds through actual store-to-provenance-to-MCP/export paths; first sightings are not exact creation times; rename plus growth retains separate intervals; delayed publication remains distinguishable; uncertain intervals cannot create false session/writer attribution. Reject or explicitly qualify contradictory chronology rather than swapping endpoints. Establish deliberate old-payload/schema compatibility and migration, bounded overlap query behavior and redaction. Preserve all ten tool names/two resources where possible; version changed result contracts deliberately. GATE-559 must exercise these cases through isolated real IPC and decoded evidence exports.

The schema-9 stores produced during this development cycle are disposable preview fixtures only. Released v5/v6 are the proven historical migration inputs. Do not adopt a prior preview-v9 database without a new migration decision. Actual sampling time remains unknown for historical rows that never retained it.
