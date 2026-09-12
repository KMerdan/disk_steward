# Agent integrations

Disk Steward ships one local read-only MCP connector for Codex and Claude Code. The connector uses stdio on the agent side and a private current-user Unix socket on the app side. It never opens the evidence database and exposes no cleanup or filesystem mutation tool.

## Install into an explicit configuration root

Build the connector, then opt in one client at a time:

```sh
swift build --product disk-witness-mcp
Scripts/Integration/install --client codex --config-root "$HOME/.codex" --connector "$PWD/.build/debug/disk-witness-mcp"
Scripts/Integration/install --client claude --config-root "$HOME/.claude" --connector "$PWD/.build/debug/disk-witness-mcp"
```

The Codex installation adds a delimited block to `config.toml` and installs the `disk-steward` plugin package. Claude installation merges only `mcpServers.disk_steward` into `.mcp.json`. Upgrades first save dated copies under `.disk-steward-backups`; unrelated settings remain in place.

Codex desktop, the Codex CLI, and the IDE extension use the same host configuration. Start a new Codex task after installing or upgrading so the plugin and MCP server are discovered. Claude Code project-scoped servers may require approval before first use.

## Register task context

Registration is optional and temporary. It improves task-impact correlation but cannot prove individual file operations:

```sh
Scripts/Integration/session register --client codex --session-id TASK_ID --workspace "$PWD"
Scripts/Integration/session end --registration-id REGISTRATION_UUID
```

The adapter authenticates through the socket's kernel peer credentials. It persists no token or credential. A registration expires after two hours by default and is capped at 24 hours.

## Diagnose and remove

Preview diagnostics without reading client configuration:

```sh
Scripts/Integration/doctor --dry-run
```

Run a concrete check by providing the same client, root, and connector plus an optional `--socket` override. An unavailable app produces recovery guidance and no fabricated evidence.

Uninstall is reversible and does not delete evidence:

```sh
Scripts/Integration/uninstall --client codex --config-root "$HOME/.codex"
Scripts/Integration/uninstall --client claude --config-root "$HOME/.claude"
```

The uninstaller removes only the managed MCP entry and moves the Codex plugin into a dated backup. Disk Steward's database, exports, and unrelated agent configuration are outside its target set.
