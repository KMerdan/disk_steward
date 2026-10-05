# TASK-711: fix the defects found in use

This task belongs to PLAN-DISK-STEWARD-007. It fixes three of the findings
accepted at the close of PLAN-006 (FIND-R4-PATH-REDACTION-FALSE-POSITIVE,
FIND-R4-JOURNAL-LIMIT and FIND-R4-OBJECT-CONVERGENCE-FLAKE), plus one defect
found while fixing the first.

## Changes

- **One redaction filter, with a name boundary.**
  - `EvidencePathRedaction` (`Sources/DiskStewardCore/Export/EvidencePathRedaction.swift`)
    now serves both the MCP answers (`AppEvidenceQueryBackend.shape`) and the
    evidence bundle (`EvidenceBundleExporter`). It replaces two copies of the
    same pattern.
  - `sk-`, `gh*_` and `AKIA` tokens now redact only where a token can start,
    so `.disk-steward-gate-659` survives. A token after `/`, `=`, `-` or at
    the start of a name is still redacted.
- **The exporter missed some secrets (found while fixing the redaction).**
  The bundle exporter's copy of the pattern read `[^/\\s]` inside a raw
  string. That excluded the letter `s` rather than whitespace, so
  `password=s3cret` was never redacted in exported bundles. The shared filter
  uses `[^/\s]`.
- **explain_growth honours `limit`.** `changed_directories` now returns at
  most the request's `limit` (1–500, 200 when absent) and still says when it
  truncated. `export_evidence` keeps 200.
- **The convergence flake, root-caused and fixed.**
  - **The mechanism.** When a legacy object is replaced at the same path,
    publication stamps the replacement with the staged sample time.
    `stagedReplacementDate` read that time from SQLite's seconds-since-1970
    REAL column, and that conversion does not round-trip a `Date`. About one
    instant in four comes back one ulp (about 119 ns) later, which makes it
    later than the publication instant it was sampled at.
  - **The effect.** The store's invariant ("change evidence is later than
    observation publication") then refused the whole slice. It was never
    load-dependent.
  - **The fix.** The time is read from the staged payload, exactly as
    `decodeStagedFile` already does. The REAL column only orders rows. The
    invariant at `EvidenceStore.swift:3266` is unchanged.
  - **Scope.** The write scope was amended for this change
    (`docs/reliability/planning/amend-711-store-time.json`).

## Evidence

| Evidence | Result |
| --- | --- |
| [`green/`](green/) | Focused isolated run on input `9d45f706`: 58 tests, 0 failures. Covers `EvidencePathRedactionTests`, `ExplainGrowthJournalTests`, `ObjectConvergenceTests` and the MCP and review suites |
| [`flake/repro-*`](flake/) | `testAReplacedLegacyRowPublishesWhenItsSampleInstantRoundsUp` picks an instant that rounds up and fails on the unfixed store with "change evidence is later than observation publication", every time by construction |
| [`flake/fix-*`](flake/) | With the fix, all 42 tests in `ObjectConvergenceTests`, `ScanConvergenceStopTests`, `MonitoringReceiptTests` and `MonitoringLifecycleTests` pass. So do 84 store reconciliation tests and `DirectoryMetadataScannerConvergentScanGenerationTests` |
| [`reds/`](reds/), specs in [`mutations/`](mutations/) | `redaction-no-boundary` fails `testOrdinaryNamesSurvive`. `value-stops-at-letter-s` fails `testAssignedSecretsAreRedactedWhateverTheyStartWith`. `journal-limit-ignored` fails `testTheRequestLimitBoundsChangedDirectories`. `replacement-time-from-column` fails `testAReplacedLegacyRowPublishesWhenItsSampleInstantRoundsUp` |

The full candidate verification runs once on the final 1.5.1 input, at
GATE-719.

## Limitations

- The retired scanner path that hit the flake is no longer used by the app,
  only by its tests. The fix is still in product code, because the store's
  reconciler is shared.
- The `-` boundary means `my-sk-abcdefgh…` is still redacted. That is
  deliberate: a hyphen-separated `sk-` token is a likely key.
