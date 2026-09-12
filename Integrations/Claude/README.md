# Claude Code integration

Disk Steward exposes the same local, read-only stdio MCP connector to Claude Code. The supported installer merges the `disk_steward` entry into an explicit configuration root and preserves other MCP servers:

```sh
Scripts/Integration/install \
  --client claude \
  --config-root "$HOME/.claude" \
  --connector "/Applications/Disk Steward.app/Contents/MacOS/disk-witness-mcp"
```

For a repository-shared configuration, pass the repository directory as `--config-root`; the installer writes its `.mcp.json`. Review project-scoped MCP servers before approving them in Claude Code.

Register a running task only while it is active:

```sh
Scripts/Integration/session register --client claude --session-id "$CLAUDE_SESSION_ID" --workspace "$PWD"
```

Save the returned `registration_id`, then end it with `Scripts/Integration/session end --registration-id ID`. Registration links a process tree and workspace to a task; it does not prove individual file writes.
