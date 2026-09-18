# TASK-552 task-impact timing checkpoint

Checkpoint: 18 September 2026 JST. Source candidate `74bd38987ebb54a77a7dd87a683d6339523607a0386f6cf4038c3216f1d00d92`, plan R10/G81 before impact reconciliation. This is partial implementation evidence, not task acceptance or release approval.

## Behavior repaired

Task impact uses possible occurrence overlap instead of discovery time. A current claim is selected before range filtering, so an older claim cannot be resurrected when its correction falls outside the window. Revalidation retains the selected claim's explicit bounds, including unknown lower bounds; it neither upgrades retained unknown/operator evidence to inferred ownership nor transfers an old inference to a different registration. Competing sessions are considered, and observation gaps apply only to matching roots/paths. Genuine retained direct process/task proof remains available. Returned byte totals cover whole matched events, not a time-prorated amount, and the response labels that limitation.

Candidate loading rejects row/byte overflow without partial aggregates. Aggregate arithmetic is checked. Unix timestamp scalar equality preserves SQLite/Codable roundtrips without widening intervals. The preview-v10 migration regression fixture now actually recreates the pre-v12 provenance table rather than accidentally keeping newer columns.

## Verification and history

`task-impact-source-manifest.json` lists the exact 11 product/test deltas from the preceding nullable checkpoint; `task-impact-source/` preserves them. `task-impact-final-green/candidate.json` and its six stage logs are the authoritative isolated verification record: 486 Swift tests, 4 explicitly skipped opt-in cases, zero failures; 20 Python harness tests passed. Source inputs and all 11 archived deltas were rehashed against this checkpoint before further work.

Earlier runs remain evidence of discovery, not acceptance of the final source:

- `task-impact-red`: incorrect raw/baseline attribution and discovery-window selection.
- `task-impact-precision-red`: fractional timestamp regression, with separately identified instrumented diagnostic source/log.
- `task-impact-initial-green`: superseded by retained-claim regressions.
- `task-impact-retained-red` and `task-impact-retained-green`: unknown/operator/reassignment and unrelated-root gap cases; later superseded by bounds review.
- `task-impact-bounds-red`: three tests/seven failing assertions reproduce loss of selected claim bounds.
- `task-impact-build-error`: failed compilation before replacing inaccessible timing construction with a local tuple; no tests claimed.
- `task-impact-final-green`: corrected complete isolated run.

R10 adds only the exact inherited MCP increment test to allowed scope. Its old raw-observation attribution expectation contradicted the accepted timing contract; all unrelated journey assertions remain. Topology and acceptance criteria were not weakened.

## Helper reconciliation

`HELPER-TASK-552-IMPACT-01` reviewed an older `0724...` snapshot. Its bounds finding was reproduced and repaired; it is advisory historical evidence only. `HELPER-TASK-552-IMPACT-02` reviewed the final `74bd...` delta. Its identity, schema, result budgets, immutable snapshot and task guard `GUARD-TASK-B7CFF057041F576DA4D767C93E4991C2` were reconciled while that guard remained current. The narrow static review found no additional concrete defect; it did not run tests or establish whole-task acceptance. Raw result envelopes remain pending/ineligible so they cannot be mistaken for independent runtime validation. Changing assurance or product source requires fresh reconciliation for later candidates.

## Still required

AC-TASK-552-01 remains incomplete: a real-IPC matrix for all ten tools/two resources, privacy including cursors, immediate effective scope/policy, missing/stale evidence, and pre-materialization row/byte budgets. AC-TASK-552-02 is only partly supported: query execution cost at representative cardinality and complete composed export/MCP checks remain. The source byte cap does not establish an end-to-end RSS bound or bounded SQL join/sort time. Session/gap materialization remains to inspect. No full-task/gate pass, live database change, installed-app replacement, client configuration edit, signing, commit, push or release occurred.
