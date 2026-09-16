# TASK-230 Agent Access verification

Verified 2026-09-13 on macOS with Apple Swift 6.2.4 and Xcode 26.3.

## Lifecycle and privacy boundary

- The persisted `agent-access-state-v1` setting is absent on a fresh install, which means off.
- Enabling creates the app-owned server and an owner-only Unix-domain socket (`0600`); disabling stops the service and removes the socket.
- The helper distinguishes an intentional user disable (`agent_access_disabled`, non-retryable) from an unavailable app (`app_unavailable`). It never fabricates evidence for either state.
- The toggle changes only the Agent Access state file and IPC server lifecycle. Tests verify evidence, monitoring settings, and representative Codex and Claude configuration files remain byte-for-byte unchanged.
- MCP remains a local stdio helper connected to a Unix-domain socket. No TCP listener or write-capable evidence tool is introduced.
- Off, Starting, On, and Needs Attention each have explicit title, detail, and accessibility text independent of color.

## Checks

- `swift test --filter MCPAccessTests`: passed, 6 tests, 0 failures.
- `swift test`: passed, 116 tests, 0 failures.
- `./Scripts/Development/build_xcode_project`: passed; XcodeGen regenerated the canonical project and the signed Debug app build succeeded.
- `codesign --verify --deep --strict --verbose=2 <Debug app>`: passed, including bundled `disk-witness-mcp`.
- Signed app `--ui-smoke`: passed and reported `"agent_access":"off"`, `"ipc_service":"off"`, accessory activation, status board left click, and utility menu right click.

## Acceptance mapping

- AC-230-01: fresh-off, persistence, and relaunch-state behavior are covered by `MCPAccessTests`.
- AC-230-02: real socket start/query/mode/stop/removal and disabled client guidance are covered by `MCPAccessTests` and `DiskStewardMCPTests`.
- AC-230-03: non-mutation sentinels plus the existing read-only MCP catalog and private-socket contract pass in the full suite.
- AC-230-04: all four state models and accessibility summaries are covered, and the status board consumes the single controller state.
