# TASK-521: interval and newest-alias evidence

Final core candidate acceptance and review-driven corrections are recorded in implementation-result.md; the 9688186 run below remains historical intermediate evidence.

17 September 2026. Continues legacy-progress.md. This report records implementation evidence; it is not a Pyramid audit or release approval.

## Exact candidate

- Canonical actor/claim: codex, PLAN-DISK-STEWARD-005 R5 G38, GUARD-TASK-DF3C078CCDB9D39E4D2718BCC19B95FB.
- Frozen copy: /private/tmp/disk-steward-521-interval-candidate.D7ovMy.
- Product/test source hash: 9688186dc6c2de154c66ec60982db1372551e2f26fdcf5b60f09bec4e285b238.
- Recomputed canonical and frozen-copy hashes agree. No source edits followed the full-suite run.
- Hash command: rg --files --no-ignore -0 Package.swift Sources Tests Config Scripts DiskSteward.xcodeproj Integrations Schemas Fixtures Resources Extensions | sort -z | xargs -0 shasum -a 256 | shasum -a 256.

## Reproduced and corrected

The old preferred-path ordering could select an earlier hard-link sample even after another alias proved newer metadata. Canonical selection now orders by actual sample time first, retaining the winning sample's path, size and timestamp together. The old preferred path is only a deterministic tie-breaker. Real hard links, between-slice growth and reopen are tested. This changes representative-path selection, not physical-object accounting; multi-link objects remain non-actionable.

Core change-event lower bounds are now nullable. A first observation proves presence by its sample time, not creation at exactly that instant. Rename and growth retain their distinct absence and positive-sample upper bounds. Replacing a noncanonical alias uses evidence for that path binding, not a later sample of another alias. Contradictory sample chronology is rejected transactionally rather than silently swapping endpoints or replacing newer truth.

The unreleased schema-9 migration now rebuilds change_events with an optional lower bound and ordered-bound constraint. It preserves IDs, deltas, upper/detection values, outbound foreign keys, cascade behavior and the object-time index. Historical first sightings and inverted ranges lose their unsupported lower bounds. Historical noninverted prior-derived intervals remain legacy estimates, not reconstructed actual samples. Genuine v5/v6 fixtures cover reopen, index/FK/cascade integrity, and the existing atomic migration interruption/headroom matrix. Intermediate development schema-9 shapes were never installed/adopted; supporting such a preview store would require a separate version/shape migration.

## Checks and results

All test commands ran in disposable copies, with these opt-ins unset: DISK_STEWARD_NATIVE_CLIENT_TESTS, DISK_STEWARD_PACKAGED_HELPER, DISK_STEWARD_GATE_EVIDENCE and DISK_STEWARD_CAPTURE_DIR. No installed application, real watched files, evidence database or client configuration was used.

| Evidence file | Result |
| --- | --- |
| alias-red.log | Three new methods executed; newest-alias cases failed before the fix; distinct rename/growth endpoints already passed. |
| alias-tests.log | New regressions passed; six old assertions in three failed-root variants exposed their older canonical-path oracle. |
| alias-corrected-tests.log | 66 tests passed after updating those oracles to latest sampled metadata; both canonical-root cases remain covered. |
| bounds-red.log | Four new methods failed before nullable bounds, chronology rejection, alias-binding lower bounds and migration correction. |
| bounds-tests.log | 85 convergence, lifecycle, store and historical-migration tests passed in 4.249 seconds. |
| interval-full-tests.log | Exact frozen source: 366 tests, 365 passed, one native opt-in skip, zero failures, 29.358 seconds; ended 05:34:02 UTC; process 48832 exited 0. |

Final full-suite command: env -u DISK_STEWARD_NATIVE_CLIENT_TESTS -u DISK_STEWARD_PACKAGED_HELPER -u DISK_STEWARD_GATE_EVIDENCE -u DISK_STEWARD_CAPTURE_DIR swift test --disable-sandbox. The targeted command adds --filter 'DirectoryMetadataScannerConvergentScanGenerationTests|EvidenceObjectLifecycleTests|EvidenceStoreTests|HistoricalMigrationTests'. Canonical git diff --check passes. Test logs alone do not prove scale, overnight safety or public API correctness.

## Scoped acceptance map: AC-TASK-521-01 / EVREQ-TASK-521-01

Test abbreviations below refer to actual methods in ConvergentScanGenerationTests.swift (C), EvidenceObjectLifecycleTests.swift (L), HistoricalMigrationTests.swift (H), and EvidenceStoreTests.swift (S). All named cases are included in the exact candidate's passing run.

| Required behavior | Direct executable evidence |
| --- | --- |
| Staged A deleted while B/C remain must not be freshly republished | C.testRestartedDirectoryDoesNotPublishDeletedStagedFile; C.testFinalDirectoryBatchIsRevalidatedBeforePublishingStagedMembership |
| Mutation in an already completed nested pass invalidates its membership | C.testCompletedNestedDirectoryIsRevalidatedWhileAnotherDirectoryIsStillScanning; C.testFreshOverlappingPassCannotInheritSupersededMembership |
| Reopen/interrupted publication cannot reuse unvalidated membership | C.testInterruptedPublicationDoesNotReplayCompletedStagingWithoutRevalidation; C.testPassValidationRestartsFromTheBeginningAfterDatabaseReopen |
| Dirty signal fences an in-flight result, including equal timestamps | C.testDirtySignalDuringValidationFencesInflightSliceAndSurvivesRestart; C.testRootSpecificDirtySignalPreservesIndependentStagingAndFencesEqualTimestampSlice |
| No claim of an atomic filesystem snapshot | C.testUnsignalledMutationAfterValidationRetainsOriginalSampleTimeAndNextScanCorrectsIt; actual sample dates remain old and the next scan corrects presence |
| Failed roots do not discard healthy progress or prove missing files deleted | C.testUnavailableRootDoesNotBlockHealthyRootOrProveDeletion; C.testFailedAncestorDoesNotEraseSuccessfulDescendantContribution; three failed-root hard-link cases |
| Root overlap and global/ancestor dirty coverage remain conservative | C.testOverlappingRootsSharePhysicalDirectoryProofWithoutLosingCoverage; C.testPartialGenerationDoesNotResolveGlobalDirtyCoverage; C.testAncestorDirtySignalResolvesOnlyWhenAllIntersectingRootsComplete |
| Gap receipt replay is idempotent, not a progress-reset loop | C.testReplayedFSEventGapDoesNotResetProgressOrReopenResolvedGap; C.testEventGapPersistsAcrossRestartUntilCompleteReconciliation |
| Rename/growth/replacement/swap preserve object identity and byte accounting | C.testSwappedObjectPathsPublishAtomicallyWithoutUniquePathCollision; C.testOneOldHardLinkedObjectReplacedByTwoObjectsIsDebitedOnlyOnce; C.testTwoOldObjectsReplacedByOneHardLinkedObjectAreBothDebited; C.testRenameOverExistingObjectAccountsForDisplacedBytes; C.testMoveAndGrowthRetainBothIdentityAndByteChange |
| Freshest alias wins without inventing a rename | C.testNewestHardLinkSampleWinsOverPreferredPathAcrossSlicesAndRestart; L.testLegacyNewestAliasSampleWinsWithoutInventingRename |
| Actual sample/absence dates differ from publication; unsupported lower bounds stay unknown | C.testSampleTimesSurviveDelayedPublicationAcrossEvidenceTables; C.testAbsenceTimeComesFromCoveringPassNotLaterPublication; C.testRenameAndGrowthRetainDistinctPositiveAndAbsenceBounds; L.testFirstObservationHasUnknownOccurrenceStartAndMeasuredUpperBound |
| Contradictory times cannot overwrite current truth | L.testContradictorySampleChronologyCannotOverwriteCurrentTruth; L.testReplacementOfAliasUsesItsBindingEvidenceNotAnotherAliasSampleTime |
| Scope changes are not deletion or rename evidence | C.testDeletedQueuedDirectoryIsRescannedAndScopeChangeAbandonsOnlyUnpublishedWork; L.testScopeChangeEmitsEnterAndExitWithoutClaimingDeletion; L.testLegacyScopeMoveDoesNotInferRenameAndScopeExitDoesNotRepeat |
| Publication is transactional, retry/replay-safe, and transient proofs are cleaned | C.testReconciliationIsAtomicAcrossEveryInjectedInterruptionBoundary; C.testCompletedGenerationsDoNotRetainTransientDirectoryProofs; L.testLegacyRollbackAtEveryBoundaryPreservesPriorStateAndActiveGeneration; L.testCompleteABCObservationRecordsDeletionAndReplayIsIdempotent |
| Legacy input obeys the same identity/uncertainty contract and does not resolve durable dirty evidence | L.testLegacyMixedRootsPublishesHealthyChangesAndRetainsFailedRootUncertainty; L.testLegacyPartialReplacementKeepsUnobservedAliasUnknown; L.testLegacyCompleteSnapshotCannotResolveDurableDirtyEvidence; L.testLegacyPartialCoverageCannotCloseAnExistingEventGap |
| Historical records migrate without inventing sample proof or losing committed truth | All four H methods exercise genuine v5/v6 DDL, 513-row backfill, NULL/inverted bounds, four shadow-migration failure points, insufficient headroom, reopen and safe abandonment of unproven staging; S migration tests remain green |

## Integration obligations (not satisfied by this core patch)

See integration-handoff.md. Ordinary app FSEvents currently schedule work without routing all dirty hints through the durable invalidation boundary. TASK-522 must connect and test that path. Public ProvenanceInput/Claim, provenance_claims and exports independently default missing intervals to points and normalize inversions. TASK-552 needs coordinated model/query/schema/consumer changes and versioned compatibility tests; the core change_events correction does not fix those public claims.

Resource redesign, 100k/1M measurement, rollback controls, real-client checks and overnight evidence remain separate plan obligations. Legacy snapshot ingestion still returns full arrays by its existing contract; generation publication still uses a bounded inline result. No limits were raised, no user files were deleted, and no install/signing/commit/push/release was performed.
