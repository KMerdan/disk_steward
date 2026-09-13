# GATE-390 independent increment audit

Date: 2026-09-13 (Asia/Tokyo)

## Result

Pass. The current build composes the persistent recorder, app-owned evidence service, authenticated task registration, read-only MCP connector, client packaging, and inherited human status/export journey.

## Independent scenario

`AgentQueryableEvidenceIncrementTests` creates a private app service and retained artifact event, registers a Codex-shaped session, then drives the built `disk-witness-mcp` executable with a JSON Lines transcript. The transcript demonstrates:

- MCP initialization and discovery of exactly seven tools, all annotated read-only and none destructive.
- `explain_growth` returning a bounded evidence explanation.
- `get_task_impact` linking the unique workspace and active lease as `inferred`, never `exact`.
- `export_evidence` returning the same summary and event detail as the app service's direct export path.
- `find_cleanup_candidates` labeling results `review-required-never-safe-to-delete-claim`.
- An attempted `delete_file` call rejected as an unknown tool.
- Exact forbidden output keys absent and the complete transcript below the 4 MiB response ceiling.
- After the service socket stops, `get_storage_summary` returns `app_unavailable` with an explicit recovery action and no fabricated data.

The same test refreshes the compact human model, exports its current snapshot, and repeats the left-click status board, right-click utility menu, and Export/Settings/About/Quit labels.

## Client and recovery evidence

`IntegrationInstallTests` runs entirely under temporary configuration roots. It covers Codex TOML/plugin discovery, Claude JSON discovery, repeat upgrades, dated backups, mutation-free dry runs, malformed-marker refusal, a real registration/end exchange, unavailable-app diagnostics, and uninstall with byte-identical evidence sentinels.

## Security inspection

The connector inventory has no deletion, process-control, settings-write, destination-path, or shell-command tool. A targeted source search for deletion/process-control terms found only explanatory text warning that candidates are not safe to delete. The stdio connector does not open SQLite; the Unix socket checks current-user ownership and private permissions.

## Verification

- `swift test --filter AgentQueryableEvidenceIncrement`: 1 test passed.
- `swift test`: 83 tests passed, 0 failures.
- `swift build`: passed.
- `git diff --check`: passed.
- Targeted destructive-surface search: only non-destructive warning text matched.

During construction, the first audit fixture used a future/same-tick synthetic timestamp and a substring check that confused `contains_file_contents: false` with leaked contents. The test was corrected to sequence the event after registration and inspect exact JSON keys. The focused and full suites then passed; product code was unchanged by that correction.
