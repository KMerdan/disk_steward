# Measured event timing checkpoint

Candidate `93015d674fd03a81ff74d58df563922996ac3ec8057c0009e38c9245744058c5`, PLAN-DISK-STEWARD-005 R9 G76, TASK-552. This is a partial implementation checkpoint, not task acceptance or release approval.

The corrected candidate passes all six isolated verifier stages: 20 Python harness tests; 465 Swift tests, four opt-in skips and zero failures. See `timing-corrected-green/candidate.json` and its hash-bound logs. `timing-source-manifest.json` and `timing-source/` retain the 17 changed product inputs relative to the prior chronology checkpoint.

The patch carries measured/unknown event timing through inline publication, reopened store readers, real IPC get_provenance and decoded export_evidence. Event and manifest payloads are deliberately versioned. Metadata-only observations do not synthesize writer claims.

Review HELPER-TASK-552-TIMING-01 found that the first new event after an upgrade could promote a historical current-state timestamp into a measured lower bound. The failure was reproduced for actual v5/v6 fixtures (`timing-legacy-red/`). Schema 11 adds verification flags to current state and path bindings, preserves flags on restoration, and withdraws preview-v10 timing assertions without erasing their original dates. Three new migration regressions cover first/new observations, legacy aliases, and preview-v10 correction.

Delta review HELPER-TASK-552-TIMING-02 matched guard GUARD-TASK-A8DE5156DDA36184F5DE026E73D6D2D5 and the corrected immutable candidate. It reported no concrete remaining defect within the narrow reviewed delta. This is static review, not independent runtime validation. The restore path was statically traced; no new direct restore regression was run. The coordinator accepts that bounded review for this checkpoint only. Earlier `timing-green/` evidence is superseded and must not be used as the accepted candidate.

Remaining TASK-552 work includes nullable occurrence bounds in provenance claims and overlap queries, old-payload compatibility, compact public projections, effective policy/scope, private cursors, pre-materialization budgets, typed errors and full ten-tool/two-resource IPC proof. Scale, overnight, rollback and packaged-release gates remain open. No real watched roots, installed app, user evidence or agent client configuration were changed.
