# GATE-569 — Safe reversible agent onboarding (rung 6)

Actor: `claude`. Independent exercise of the integrated candidate for OUTCOME-560 on top of every earlier verified rung. Nothing was committed, installed, signed or released; every run is an isolated snapshot under `/private/tmp`.

## Exact candidate

`docs/reliability/evidence/TASK-562/candidate-2/candidate.json`: source input `5ecd49a317171e493451894bcc082cd8d4516d2922c29564107baace9d21dd68` (the final candidate; TASK-562's second full run). Stages: harness ok, toolchain ok, manifest ok, entitlements ok, build ok, tests ok, package-generator ok, package-toolchain ok, package-system-temporary ok, package-project ok, package-build ok, package-architecture-app ok, package-architecture-helper ok, package-smoke ok, package-helper ok. 547 tests, 5 opt-in skips, 0 failures; `sentinelPreserved: True`; packaged unsigned app, architecture, smoke and bundled-helper stages passed.

`docs/reliability/evidence/audits/scoped-all-rungs-final-green/tests.log`: every earlier rung's scoped suites rerun in one isolated snapshot on the same input `5ecd49a31717…`: 423 tests across 60 suites, 0 failures, 1 opt-in skip (NativeClientLifecycleTests). Suite counts in `suite-counts.json`.

## Scenarios for this rung, independently rerun

- **Conflict-safe configuration ownership and CLI rollback (TASK-561)**: `docs/reliability/evidence/TASK-562/suites-green-2/` on the final input — ConfigurationOwnershipTests 10, ConfigurationRollbackTests 10, IntegrationInstallTests 8, AgentIntegrationHardeningTests 6, RemainingClientsAdapterTests 10, CodexAndClaudeCodeAdapterTests 12, AgentIntegrationContractTests 6, AgentIntegrationsPresentationTests 4; 0 failures. Audit EVENT-20260918T061005173881Z-F93AF5BB.
- **Verified means the configured helper answered (TASK-562)**: same run — HelperVerificationTests 6, SessionContractTests 3 (real connector against a recording socket server with the exact storage-summary shape), MCPAccessTests 7; four mutation reds on the final candidate (`identity-`, `cleanenv-`, `sessionpid-mutation-red-2/`, `freshness-mutation-red/`). Audit EVENT-20260918T064055670332Z-A07B933B.
- **Reversibility**: install → rollback → uninstall → rollback rehearsed by ConfigurationRollbackTests on temporary roots; no real client configuration was opened; native lifecycle stays opt-in (1 skip).
- **Inherited rungs 1–5**: `docs/reliability/evidence/audits/scoped-all-rungs-final-green/` rerun on this candidate (423 tests, 0 failures).

## Findings affecting this rung

FIND-ISOLATION, FIND-SERVICE, FIND-QUERY, FIND-OCCURRENCE resolved; FIND-ATTRIBUTION (medium) and FIND-DISTRIBUTION-DOC (medium) open with dispositions recorded in the task audits; FIND-OVERNIGHT resolved under the R13 criterion.

## Safety and recovery (inherited)

- Migration/rollback rehearsal against the compatible baseline binary (`docs/reliability/evidence/TASK-572/rollback-rehearsal.md`, FIND-ROLLBACK resolved) and the four named historical migration cases required as passed by the verifier.
- Real-time supervised soaks (`docs/reliability/evidence/TASK-572/soak-runs/soak-3h/summary.json`, 112 min; `soak-final-candidate/summary.json`, 43 min on the exact final candidate) and the 100k wide full workload on the final candidate (`docs/reliability/evidence/GATE-539/scale-runs/wide-100k/`).

## Limitations

- Fixture endpoint adapter only; no native EndpointSecurity activation or entitlement.
- Fake-clock lifecycle proofs; real sleep/wake and native notification submission are not exercised; native client profiles stay opt-in.
- Unsigned disposable-copy packaging; host macOS 15.6.1 arm64.
- No overnight soak by the owner's R13 direction (open-source release; long-run behaviour comes from user feedback): real-time soaks of 112 min and 43 min (exact final candidate) plus the scale matrix are the resource evidence.
