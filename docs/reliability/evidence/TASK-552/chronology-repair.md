# TASK-552 — chronology repair checkpoint

17 September 2026. Partial implementation evidence, not TASK-552 completion, an audit, or release approval.

## Reproduced failures

`chronology-red/` contains four failing tests (26 failed assertions, no unexpected failures), input `b1c25b7ac9ea620acc4bf12a4a7e4eb64468b134e74e9088f3adc135022109fb`. Constructors reordered contradictory endpoints; the engine could still name a writer/task with invalid chronology; invalid claims could be persisted; a session active only at discovery could be selected despite not covering the possible occurrence interval. Each persisted fixture claim has its own ID, so duplicate-ID rejection cannot masquerade as chronology rejection.

The second red run, `chronology-boundary-red/`, used input `97592b21f1d6d17e8bccee29c9911401c0a116517aee25bce4a820c49a14f448`. Five tests passed and the added observer-boundary test failed four assertions: the matching tolerance admitted notifications before/after the supplied occurrence bounds. A competing partial-overlap session test passed.

## Repair and verification

The model now preserves supplied endpoint order. A shared finite/ordered chronology check requires occurrence start <= occurrence end <= detection, and observation <= detection. Invalid input produces an explicitly unknown claim without actor/session; persistence rejects it rather than changing the dates. Workspace correlation considers every overlapping session and requires the sole match to cover the entire supplied interval. Direct process/session matching uses the notification time, and the notification must lie inside the occurrence bounds; tolerance does not override those bounds.

Accepted chronology candidate input: `8e28d59130313947242d4a5a51d070b0a35af520f17f24d97458a7513dc18100`. `chronology-source/` contains the four changed source/test files; `chronology-base-source/` records the first red-run versions. The store delta in this checkpoint is limited to its chronology guard; the file also contains earlier repairs which remain preserved.

The credential-free verifier ran against disposable source `/private/tmp/ds-ci-i4mxhdrm/project`:

```sh
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 Scripts/Testing/verify_candidate.py --output /private/tmp/ds552-chronology-20260917
```

All six stages passed: 20 Python harness tests; 458 Swift tests, 4 opt-in skips, zero failures, 31.457 seconds. `chronology-green/` retains the full input manifest, commands, artifact hashes and six logs. Copied log checksums were verified. The isolated live-endpoint sentinel and four historical forward-migration checks passed; these do not establish new-schema compatibility or old-binary rollback. No packaged build was run for this checkpoint.

The narrow helper review is recorded in `chronology-review-job.json` and `chronology-review-result.json`. It found no further actionable defect within the partial patch. Coordinator reconciliation checked the envelope, task guard, candidate identity and evidence budgets; this remains static advisory review, not independently executed validation. Its noted limit is retained: non-finite chronology is exercised through the engine, while non-finite persistence rejection is supported by the shared guard's source, not a dedicated store test. The review cannot approve the whole task or replace runtime validation.

## Required continuation — not fixed by this checkpoint

1. `ProvenanceInput` and `ProvenanceClaim` still have nonnullable `occurredStart` and substitute `event.observedAt` when omitted. The next coordinated contract must preserve unknown lower bounds through input, claim, presentation, persistence, MCP and export. Do not claim that the new whole-interval check solves unknown-start attribution.
2. `EvidenceStoreEvent` still does not carry `change_events.occurred_start`, operation-specific `occurred_end`, or `detected_at`. Both inline commit results and bounded event readers need an authoritative timing path. Rename and growth may have different upper bounds; first sighting/scope entry must not become creation timestamps.
3. A source search found `ProvenanceEngine` and `persistProvenanceClaim` definitions but no calls in `Sources` or `Extensions`. Existing provenance pipeline tests synthesize the engine/persistence calls. Establish the actual production store-to-agent path, not merely another helper-only test. Avoid inventing writer/session attribution for metadata-only monitoring.
4. Stored provenance schema currently requires a nonnull lower bound. Overlap predicates in the store/exporter use `occurred_start <= through`; NULL requires an explicit possible-overlap rule, bounded row/byte admission, and honest uncertainty. Choose versioned public payloads and deliberate legacy decoding/migration together. Preserve original historical evidence and never reinterpret prior fabricated timing as measured evidence. Preview-v9 stores remain disposable; released v5/v6 are the established historical inputs.
5. Complete AC-TASK-552-01: pre-materialization budgets, compact store-backed public summaries (not decoding full scan frontiers before omitting them), effective root/exclusion policy, private query/revision-bound cursors, typed errors and freshness. Existing backend fixes are partial and need end-to-end proof.
6. Exercise all ten tools and both resources through isolated real IPC, plus decoded exports, for both acceptance criteria. Then update and audit through Pyramid. Current tests prove only this bounded chronology repair.

No installed application, real evidence database, watched files, client configuration, signing identity, commit, push or release was changed. TASK-552 and the full reliability intent remain unfinished.

After all runners were terminal, four obsolete disposable `.build` directories were checked as owned real directories with no open files, then removed permanently (not Trash): `ds552-check-__gyzl5c`, `ds552-check-rzrx5wh9`, `ds552-check-nzhmdq4x`, and `ds552-check-obw7mbmh`, each under `/private/tmp`, only the `project/.build` leaf. About 1.5 GiB of reproducible generated output was removed. Source snapshots, reports, and final `ds-ci-i4mxhdrm` build remain.
