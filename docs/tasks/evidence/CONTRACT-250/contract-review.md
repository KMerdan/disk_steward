# CONTRACT-250 review

The evidence-usefulness contract is now explicit and executable.

- `docs/architecture/evidence-export.md` separates whole-volume capacity from
  configured file-detail roots, defines one-view export ownership, requires all
  evidence roles, orders the human brief around decisions, and makes empty or
  missing evidence honest.
- `docs/architecture/evidence-object-lifecycle.md` now defines durable capped
  scan generations. A slice can stage progress but cannot reconcile absence;
  only a complete full-root generation can update current state and changes.
- The actionable-export schema and fixtures distinguish scope, coverage,
  current-state age, active generation progress, open gaps, limitations, and
  privacy posture.
- The scan-generation schema and fixtures cover multi-slice completion, restart
  continuity, scope-version abandonment, and completion-only reconciliation.
- The export-manifest contract now requires the complete eleven-payload bundle
  shape through the actionable-export schema and semantic tests, while the
  shared manifest remains compatible with the separately named capacity
  diagnostic.
- Contract tests reject a capacity-only bundle, reject false complete/no-change
  claims while a gap is open, and reject reconciliation by partial or abandoned
  scan generations.

Validation: `swift test --filter ContractTests` executed 24 tests with zero
failures, including all six `EvidenceUsefulnessContractTests`.

Regression repair: a later full-suite run showed that placing the eleven-file
minimum on the shared manifest invalidated the retained capacity diagnostic.
That constraint was moved back to `actionable-export-v1`; both contract and
`SnapshotExporterTests` now pass.

No file contents, environment values, cleanup mutation, whole-disk file claim,
or implementation of the exporter or traversal engine was added by this node.
