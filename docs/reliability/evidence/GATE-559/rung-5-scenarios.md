# GATE-559 — Useful and private evidence API (rung 5)

Actor: `claude`. Independent exercise of the integrated candidate for OUTCOME-550 on top of every earlier verified rung. Nothing was committed, installed, signed or released; every run is an isolated snapshot under `/private/tmp`.

## Exact candidate

`docs/reliability/evidence/TASK-562/candidate-2/candidate.json`: source input `5ecd49a317171e493451894bcc082cd8d4516d2922c29564107baace9d21dd68` (the final candidate; TASK-562's second full run). Stages: harness ok, toolchain ok, manifest ok, entitlements ok, build ok, tests ok, package-generator ok, package-toolchain ok, package-system-temporary ok, package-project ok, package-build ok, package-architecture-app ok, package-architecture-helper ok, package-smoke ok, package-helper ok. 547 tests, 5 opt-in skips, 0 failures; `sentinelPreserved: True`; packaged unsigned app, architecture, smoke and bundled-helper stages passed.

`docs/reliability/evidence/audits/scoped-all-rungs-final-green/tests.log`: every earlier rung's scoped suites rerun in one isolated snapshot on the same input `5ecd49a31717…`: 423 tests across 60 suites, 0 failures, 1 opt-in skip (NativeClientLifecycleTests). Suite counts in `suite-counts.json`.

## Scenarios for this rung, independently rerun

- **Bounded exports and decoder/date consistency (TASK-551)**: `docs/reliability/evidence/audits/scoped-all-rungs-final-green/` — EvidenceBundleExporterTests 10, ExportSafetyRegressionTests 13, InlineExportSafetyTests 5, EvidenceEventTimingTests 2, EventTimingIPCIntegrationTests 2, ProvenanceChronologyTests 6; 0 failures. Audit EVENT-20260918T052753225845Z-7F80D1B3.
- **Compact privacy-correct evidence DTOs (TASK-552)**: EvidenceQueryPrivacyIPCIntegrationTests 4, EvidenceQueryScopeIPCIntegrationTests 6, EvidenceCardinalityIPCIntegrationTests 1, EvidenceQueryReadModelTests 3, AuthoritativeMCPReadModelTests 4, AgentQueryableEvidenceIncrementTests 1, LifecycleProjectionIPCIntegrationTests 4, UnknownOccurrenceTests 6; 0 failures. Audit EVENT-20260918T052753558429Z-62669150. `persisted_state_as_of` on the real backend is pinned by EvidenceQueryScopeIPCIntegrationTests and consumed by the helper self-check through `StorageSummaryContract` (TASK-562).
- **Occurrence semantics (INSPECT-GATE-559-OCCURRENCE)**: FIND-OCCURRENCE resolved; the occurrence-integration plan artefacts under `docs/reliability/evidence/occurrence-integration-*.json` and UnknownOccurrenceTests/ProvenanceEngineTests rerun on this candidate.
- **Inherited rungs 1–4** rerun on this candidate as listed in the earlier rung notes.

## Findings affecting this rung

FIND-QUERY, FIND-EXPORT, FIND-OCCURRENCE resolved; FIND-ATTRIBUTION (medium) open on ASSET-ATTRIBUTION with its disposition in the TASK-523/561 audit records; FIND-OVERNIGHT resolved under the R13 criterion.

## Safety and recovery (inherited)

- Migration/rollback rehearsal against the compatible baseline binary (`docs/reliability/evidence/TASK-572/rollback-rehearsal.md`, FIND-ROLLBACK resolved) and the four named historical migration cases required as passed by the verifier.
- Real-time supervised soaks (`docs/reliability/evidence/TASK-572/soak-runs/soak-3h/summary.json`, 112 min; `soak-final-candidate/summary.json`, 43 min on the exact final candidate) and the 100k wide full workload on the final candidate (`docs/reliability/evidence/GATE-539/scale-runs/wide-100k/`).

## Limitations

- Fixture endpoint adapter only; no native EndpointSecurity activation or entitlement.
- Fake-clock lifecycle proofs; real sleep/wake and native notification submission are not exercised; native client profiles stay opt-in.
- Unsigned disposable-copy packaging; host macOS 15.6.1 arm64.
- No overnight soak by the owner's R13 direction (open-source release; long-run behaviour comes from user feedback): real-time soaks of 112 min and 43 min (exact final candidate) plus the scale matrix are the resource evidence.
