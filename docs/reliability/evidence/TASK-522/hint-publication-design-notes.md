# TASK-522 — next receipt/publication design boundary

17 September 2026; read-only follow-through during notification verification. Observed code is source hash `5da2e407b89521627ba4c31cb7a742eab423cef60155b49c97d9a8b541bdb140`. These notes identify what must be proved next; they do not select a finished design or weaken AC02.

## Observed facts

1. `MonitoringLifecycleController.restartChangeCollector` starts one unstructured MainActor task per delivered batch. It tests current `canSample`, not the stream identity captured at registration. A delayed old callback could pass that check after resume/restart. Ordinary hints only schedule a debounced sample; only `batch.eventGap` calls `noteEventGap`.
2. `PersistentMonitoringProbe.sample` scans synchronously inside its actor, then awaits `store.recordScanSlice`. Its actor can accept `noteEventGap` while suspended, but there is no explicit receipt/publication ordering mechanism. `noteEventGap` sets a Boolean and swallows store invalidation failure with `try?`; successful observation bookkeeping later clears that Boolean without identifying which receipt it acknowledged.
3. `EvidenceStore.recordReconciliationInvalidation` durably upserts an open invalidation and changes the active generation token, resetting only intersecting roots. This is the usable core primitive. `recordScanSlice` rejects a token mismatch at entry. Those tests do not prove that a callback received during an already-running synchronous store publication is handled before its commit.
4. `recordScanSlice` commits staging, performs pass validation, and finally calls `reconcileCompletedScanGeneration`, whose transaction publishes current state and resolves invalidations. `SQLiteConnection.transaction` executes the body, then `COMMIT`. Cancellation is checked around SQLite operations and inside progress/busy handlers, but cancellation alone is not an explicit serialized receipt-versus-commit boundary. The exact interleaving still needs a deterministic reproduction.
5. `recordFSEvents` is not a ready substitute: it requires an existing observation ID and only invalidates for new gap evidence. Do not fabricate an observation merely to attach an ordinary receipt.
6. `TargetedFSEventsCollector` starts with `kFSEventStreamEventIdSinceNow`, copies each native batch's flags/IDs, and interprets every path. The app currently retains each batch in a new task. A bounded downstream queue alone cannot justify a claim that the native-to-app path has bounded retained memory. Startup/resume needs an explicit coverage-gap/reconciliation policy if missed history is not replayed.

## Candidate to evaluate, not yet approved

Use a bounded coalescing receipt mailbox at the callback boundary, one owned drain, stream-generation identity, per-root durable invalidation and receipt-specific acknowledgement. Fail closed on persistence failure: retain dirty state, report degraded freshness, and retry under a bound rather than silently resume publication. Accepted work must remain owned through pause/sleep/quit; stale callbacks can be ignored only when missed coverage is explicitly accounted for. Ordinary changes should preserve unaffected roots.

For in-flight publication, evaluate a shared generation/receipt permit whose final check and database commit are serialized against receipt acceptance. Do not hold a callback lock over filesystem traversal or the full reconciliation transaction. If the remaining commit critical section can block, measure/limit that cost and prove burst handling; a lock is not automatically a resource-safe solution. Account for crash between volatile receipt acceptance and durable invalidation, and re-establish dirty coverage before resuming an interrupted/unknown stream.

The current contract does not authorize Core or collector edits. First confirm the smallest necessary API/file set, then preview/apply an explicit Pyramid scope/impact revision. Do not hide Core changes inside Lifecycle or claim actor ordering without an explicit proof.

## Required next proof

- Pause an actual controller/probe/store slice after metadata/pass validation but before publication; mutate a fixture and deliver an ordinary hint. Release the stale work and prove no stale current-state publication or false deletion.
- Inject the hint both before store admission and during transaction preparation, and cover equal timestamps with distinct receipts. Define the receipt/commit linearization point and test both orderings.
- Keep an independent root's progress, cover pending/new receipt acknowledgement races, stop/restart and old callback identities, and fail durable persistence deliberately.
- Bound a burst before creating tasks/retaining all input; prove overflow produces explicit reconciliation uncertainty rather than silent loss or unbounded work.
- Reopen the temporary store after interruption with staged work. Prove missed or unacknowledged changes cannot be mistaken for a validated current generation.

This is the remaining TASK-522 work. Other INTENT-005 obligations, including scale and overnight acceptance, are not replaced by this design note.

## R8 follow-through

R8 explicitly extends the Core/store/collector write scope and impact mapping. `receipt-core-progress.md` records the selected process-local final-COMMIT fence and bounded native ingress, their reproductions and exact-hash checks. The historical R7 scope warning above no longer applies. The bounded app mailbox, durable receipt routing, stream identity and end-to-end lifecycle/restart proof remain unfinished; neither note claims AC02 acceptance.

The later `implementation-handoff.md` maps this design boundary to the integrated candidate and twelve receipt regressions. Consult it and current Pyramid state for implementation status; this document preserves the original decision context, not a second live task list.
