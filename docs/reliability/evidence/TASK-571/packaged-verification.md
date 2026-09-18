# TASK-571 — exact-candidate source and unsigned package verification

17 September 2026. Worker evidence, not a Pyramid audit pass or release approval.
The scope is the CI/verifier deliverable. Product-scale and downgrade-rollback
acceptance remain TASK-572/GATE-579 requirements and are not redefined here.

## Final executable evidence

`reviewed-run/candidate.json` is the authoritative report for this checkpoint.
Its source-input SHA-256 is
`b01e878f171012164bc8dc36647e02608964d227550633a12b07759a6e80ed97`.
HEAD is `cf313e4527a3bd30dae217d2c1ff68d7a7a87b60`, with a dirty worktree. HEAD alone
does not identify this candidate. Input manifests bind source/test/configuration
bytes and modes before and after the run, including both original and separately
generated package project inputs.

- Runner session 79859 exited 0. All 15 recorded stages passed.
- Harness: 20 tests, zero failures.
- Swift: 434 tests, 4 opt-in skips, zero failures; 30.423 seconds of test execution.
- Exact full-suite live-endpoint/sentinel test passed, not merely discovered.
- Four required historical migration cases passed: synthetic v5/v6 stores,
  513-row staged payloads, occurrence bounds, four interruption boundaries and
  no-headroom refusal. Fixture source hashes are recorded in the report.
- XcodeGen 2.46.0 and Xcode 26.3 / 17C529 built an unsigned `CI` app from a second
  disposable source copy. Canonical Xcode project and product sources were not
  regenerated or modified. Host architecture was arm64; Intel execution was not
  tested. macOS 13 is a declaration, not a runtime-compatibility test result.
- Whole app bundle SHA-256 (manifest of file paths, modes, sizes and hashes):
  `a7abba2d82e205c0e8dec264e7ea598b6d8889f6fe1a6894b068b9fbb86fd4f5`.
- Packaged accessory startup was isolated, paused, ephemeral, zero-root,
  notifications-disabled and Agent-Access-off. Its generated smoke directory was
  removed. The entire fixture tree, socket identity and lifetime lease remained
  unchanged; the listening sentinel socket received no connection.
- Bundled helper initialization, ten read-only tool definitions and ping passed
  the typed protocol checks. This is not an app-backed query or client-install test.
- All 15 archived log hashes match the report. Actionlint v1.7.12 returned exit 0
  for the current workflow; its optional shellcheck/pyflakes integrations were off.
  The hosted workflow was not dispatched, because no push/release was authorized.

## Failures retained and review reconciliation

`package-generator-failure.json` records XcodeGen's missing-USER failure. The runner
now derives USER from the OS account database instead of inheriting caller values.
`package-temporary-assumption-failure.json` records the incorrect assumption that
Foundation always honors TMPDIR. The verifier now obtains the account's OS temp
directory independently before launch and accepts only a removed UUID leaf under
that directory or its owned configured temp root. It never deletes a reported path.

`packaged-run/` and `packaged-source/` preserve the pre-review successful run.
`package-review-result.json` records three real verifier weaknesses found there:
an inexact test-name match, incomplete fixture inventory, and incomplete MCP shape
validation. All three were repaired with regressions, followed by the full final
run above. The old review is advisory/stale for the final source; it is not promoted
to a final validation result. The corrected five-file source snapshot is retained
in `reviewed-source/`, with combined hash
`95016b552a195bd52905315a7e0e32744caa38b810ab7b92421d7110b61e1026`.

The schema-valid `package-delta-result.json` independently confirms the three
repairs by static inspection. Coordinator reconciliation matched the corrected
snapshot, current G66 task guard, job identity, result budgets, empty changed-file
declarations and referenced files. It is accepted as a narrow current review, not
promoted to runtime-validation evidence; the actual final run above supplies that.

## Compatibility and rollback boundary

TASK-571 requires candidate identity, compatibility information and rollback
prerequisites. Those are explicit in the report. Passing synthetic forward-upgrade
and interruption tests does **not** verify downgrade rollback. The current migration
does not retain the old database after its successful atomic switch. A consistent
old-schema backup, exact compatible old executable, measured restore headroom and
interruption-safe restoration must be established before product rollback or
release acceptance. No old app, real evidence or real client configuration was opened.

The canonical rollback control and FIND-ROLLBACK remain unresolved. No scale,
overnight, native-client, signing, notarization, Homebrew or release claim is made.
No installed-app replacement, normal launch, commit or push occurred.

## Resource and Pyramid provenance

Final build remains at `/private/tmp/ds-ci-q6vafj8g`. The preceding reviewed build
is `/private/tmp/ds-ci-5ki2wtgp`. Neither runner is active. The log/tool-cache parent
is `/private/tmp/disk-steward-571-validation.pTkIn0`.

After lsof found no open files and all relevant runners were terminal, four exact
obsolete generated trees were removed: `ds-ci-2wu59ky_`, `ds-ci-gwynn_3s`,
`ds-ci-y6_suuk8`, `ds-ci-bjx1j12d` under `/private/tmp` (about 1.7 GiB).
Their logs/reports remain. These reproducible build copies were not moved to Trash;
no personal documents or app state were removed. Local build-cache retention is
manual, not an aggregate byte quota. CI uploads logs/reports, not a distributable app.

Pyramid baseline revision 3 adds Scripts/Testing to ASSET-BUILD. Its runtime apply
is G65; G66 maps the operational runbook to ASSET-ASSURANCE with a pre-audit
inspection. Earlier baseline assets, incidents and uncertainty remain preserved.
No history record or canonical graph file was hand-edited. These mappings do not
pass the pending product audits or resolve the paused storage proof.
