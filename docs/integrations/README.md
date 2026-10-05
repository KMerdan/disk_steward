# Agent integrations

Disk Steward ships one local read-only MCP connector for Codex and Claude Code. The connector uses stdio on the agent side and a private current-user Unix socket on the app side. It never opens the evidence database and exposes no cleanup or filesystem mutation tool.

## Install

**Disk Steward app (recommended).** Open **Settings › Agent Integrations**
and set up Codex or Claude Code. The app:
- registers the `disk-steward` server through the client's own CLI
  (`codex mcp add`, `claude mcp add --scope user`);
- installs the evidence skill into the client's user skills folder
  (`~/.codex/skills/disk-steward-evidence`, `~/.claude/skills/disk-steward-evidence`);
- records both in its receipts;
- on removal, removes the skill only while it is unchanged.

**From a source checkout.** Build the connector, then opt in one client at
a time:

```sh
swift build --product disk-witness-mcp
Scripts/Integration/install --client codex --config-root "$HOME/.codex" --connector "$PWD/.build/debug/disk-witness-mcp"
Scripts/Integration/install --client claude --config-root "$PWD" --connector "$PWD/.build/debug/disk-witness-mcp"
```

**What each mode writes:**
- **Codex** gets a delimited `[mcp_servers.disk-steward]` block in
  `config.toml` and the evidence skill in `<config-root>/skills`.
  - The script refuses to add a second `disk-steward` server when the app
    already registered one.
  - It migrates a `disk_steward` block written by 1.5.0 or earlier, and moves
    that release's unused `plugins/disk-steward` copy into the backup.
- **Claude Code** is configured for a project: `--config-root` is the
  project directory, which gets `mcpServers.disk-steward` in its `.mcp.json`
  and the skill in `.claude/skills`.
  - Settings you added to that entry (`env`, `cwd`, unknown keys, your own
    `args`) are kept on upgrade and are never deleted by uninstall. A legacy
    `disk_steward` entry moves to the new name with its settings.
  - For every project at once, use the app, or
    `claude mcp add --scope user disk-steward -- <helper>`. The script refuses
    `~/.claude`, because Claude Code does not read `~/.claude/.mcp.json`.
- **No tool list is pinned.** All ten read-only tools are offered, and a
  new release cannot leave a stale `enabled_tools` behind.

**Backups.** Every install and uninstall first writes a backup directory
with a manifest under `<config-root>/.disk-steward-backups/`. A failure
part-way restores exactly what that attempt changed, and says so. Only the
newest ten backups are kept.

Codex desktop, the Codex CLI and the IDE extension share one host
configuration. Start a new Codex task after installing or upgrading, so the
server and the skill are discovered. Claude Code may ask you to approve
project-scoped servers before first use.

## Roll back a configuration change

```sh
Scripts/Integration/rollback --client codex --config-root "$HOME/.codex" --list
Scripts/Integration/rollback --client codex --config-root "$HOME/.codex" --dry-run
Scripts/Integration/rollback --client codex --config-root "$HOME/.codex" --backup 20260918T054341Z-11183
```

Rollback restores a backup only while the current files are still what that install or uninstall wrote; a file you edited since is refused unless you pass `--force`. The state before the rollback is saved into a `rollback-*` backup first, so a rollback can itself be rolled back.

## Verify the configured helper

In the app, **Test Connection** runs the exact command the client's configuration names, with a clean environment, and trusts only the self-check report that command prints: the helper's own executable identity must match the entry Disk Steward installed. A different or moved helper cannot pass as verified. The result distinguishes:

- **Verified**: the configured helper reached the app and evidence is fresh (age is shown).
- **Stale evidence**: the helper connected, but the newest persisted observation (Monitoring's latest capacity sample, taken every 5 minutes by default) is older than an hour, or nothing has been persisted yet; check that Monitoring is running.
- **Disk Steward is not running**: no socket at the app's path (open the app).
- **Agent Access is off**: the socket path is absent and the access state says off (turn Agent Access on).

From a shell, `disk-witness-mcp --self-check` prints the same report as its last line (`"schema": "disk-steward-self-check-v1"`).

## Register task context

Registration is optional and temporary. It improves task-impact correlation but cannot prove individual file operations. A registration belongs to one long-lived agent process, never to the session command itself:

```sh
Scripts/Integration/session register --client codex --session-id TASK_ID --workspace "$PWD" --process-pid AGENT_PID
Scripts/Integration/session heartbeat --registration-id REGISTRATION_UUID --lease-seconds 900
Scripts/Integration/session end --registration-id REGISTRATION_UUID
```

`--process-pid` is required: pass the agent process's own PID (for a shell-driven agent, the agent's PID, not `$$` of a transient wrapper shell). The command checks that the process is alive and is one of its own ancestors, warns when it looks like a wrapper shell, and refuses its own interpreter; the app validates the same ancestry from the socket's kernel peer credentials. The adapter persists no token or credential. A registration expires after two hours by default (capped at 24 hours); heartbeats carry the lease explicitly. Nothing is registered automatically from MCP traffic: the helper's `initialize` and self-check never create a session.

## Diagnose and remove

Preview diagnostics without reading client configuration:

```sh
Scripts/Integration/doctor --dry-run
```

Run a concrete check by providing the same client, root, and connector plus an optional `--socket` override. The default socket is the app's own, `~/Library/Application Support/Disk Steward/disk-steward.sock`. An unavailable app produces recovery guidance and no fabricated evidence.

Uninstall is reversible and does not delete evidence:

```sh
Scripts/Integration/uninstall --client codex --config-root "$HOME/.codex"
Scripts/Integration/uninstall --client claude --config-root "$HOME/.claude"
```

The uninstaller removes only the managed MCP entry and moves the Codex plugin into a dated backup. Disk Steward's database, exports, and unrelated agent configuration are outside its target set.
