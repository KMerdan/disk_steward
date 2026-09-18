# TASK-571 — post-implementation inspection of the isolated CI and candidate workflow (2026-09-18)

Actor: `claude`. Performed after every later task in the plan recorded its implementation, on the final candidate input `5ecd49a31717…` (TASK-562's `candidate-2/`). Nothing was committed, pushed or run on GitHub-hosted runners; the workflow is inspected and linted locally, the runner is exercised locally in isolation.

## INSPECT-TASK-571-1 — BUILD / DISTRIBUTION / BOOT

| claim | check | result |
|---|---|---|
| CI configuration validates | pinned `actionlint@v1.7.12 -shellcheck= -pyflakes=` on a copy of `.github/workflows/ci.yml` (`actionlint.out`) | exit 0, no findings |
| fork/PR tests need no signing secrets | `ci.yml`: `on: pull_request / push main / workflow_dispatch`, `permissions: contents: read`, both checkouts `persist-credentials: false`, no `secrets.*` reference, no `pull_request_target`, hosted `ubuntu-latest` / `macos-15` runners, pinned action SHAs (checkout 11bd7190… v4.2.2, upload-artifact ea165f8d… v4.6.2) matching the runbook's upstream links | as documented |
| isolated harness preserves sentinel production state | the runner's own unit tests (`harness-tests.log`: `test_verify_candidate`, `test_verify_packaged_candidate`, 20 tests, OK) and the final candidate run `docs/reliability/evidence/TASK-562/candidate-2/candidate.json` (`sentinelPreserved: true`, packaged smoke with typed isolation fields, fresh UUID smoke directory removed, fixture socket untouched) | passed |
| candidate verification records the exact candidate | `candidate-2/candidate.json`: `inputSHA256`, per-file input manifest with modes, Git revision and `dirtyWorktree: true` (uncommitted candidate), stage log hashes, debug app/helper binary hashes, generator binary hash and Xcode version, bundle file hashes and both architectures, four named migration cases required as passed | recorded |
| packaged-app / upgrade verification cannot modify production data | packaged stages run only the freshly built unsigned `CI` bundle from a disposable copy with ephemeral settings, notifications off and Agent Access off; the helper stage speaks to a nonexistent private socket (`package-helper.log`); no installation, signing, Homebrew or push step exists in `ci.yml` | as documented |

Inputs hashed in `inputs.sha256`.

## INSPECT-TASK-571-RUNBOOK — ASSURANCE

`docs/reliability/CI-AND-CANDIDATES.md` compared with `ci.yml` and `Scripts/Testing/verify_candidate.py`:

- Triggers, permissions, credential persistence, runner images, actionlint pin, XcodeGen via Homebrew on the hosted runner, `--xcodegen "$(command -v xcodegen)" --output "$RUNNER_TEMP/…"`, 14-day artifact retention of logs and `candidate.json` only: the runbook matches the workflow line for line.
- Runner flags and behaviour (input hashing with modes, disposable copy, environment allowlist, deadlines and 8 MiB per-stage retention, required passed sentinel smoke, generated-project delta limited to project and Info.plist, bundle hashing, `--ui-smoke` isolation fields, helper protocol transcript without `--self-check`, four named migration cases): each item resolves to a stage or check visible in `candidate-2/candidate.json` and the stage logs.
- Item 8 already states that `--self-check` is deliberately not used in CI because it makes an app-backed query, which is exactly TASK-562's contract; the packaged helper stage remains protocol proof only.
- Boundaries: the runbook's "deliberately not claimed" list (no signing, no installation, opt-in skips are not scale coverage, downgrade rollback not verified by the workflow, scale/overnight/native clients/EndpointSecurity/final gates separate) is still accurate for the workflow. Since it was written, the migration rollback was rehearsed outside CI (`docs/reliability/evidence/TASK-572/rollback-rehearsal.md`, FIND-ROLLBACK resolved) and the real-time soak and scale matrix are recorded under TASK-572/GATE-539; those remain gate evidence, not workflow claims, so the runbook text is left unchanged.

## Limitations

- The workflow was not executed on GitHub-hosted runners in this inspection; hosted execution, runner-image drift and artifact upload are verified only by static comparison and the local isolated run.
- actionlint ran locally via `go run` with the pinned version; shellcheck/pyflakes integrations are disabled as in CI.
