# Local Agent and MCP Contract

Status: version 1 contract for local Codex and Claude integration.

## Boundary

`disk-witness-mcp` is a bundled local stdio server. It never listens on TCP or HTTP, opens the evidence database, records file contents, captures environment variables, or accepts credentials. It talks to the running Disk Steward app over an authenticated Unix-domain socket owned by the current user and mode `0600`. The app remains the sole owner of SQLite access, retention, policy, sanitization, and export consistency.

The connector exposes only queries. It cannot delete, move, or modify files; stop processes; pause monitoring; change settings; install components; or alter evidence. `find_cleanup_candidates` returns review candidates and never declares a path safe to delete. `export_evidence` returns an inline, bounded representation equivalent to app-generated evidence and accepts no filesystem destination.

## MCP compatibility

The server negotiates MCP protocol `2025-06-18`, with compatibility for `2025-03-26` and `2024-11-05`. Initialization advertises stable tools and resources, no prompts, sampling, logging, subscriptions, or task-augmented execution. Tools use closed JSON Schema inputs, bounded item counts and byte budgets, and the standard annotations `readOnlyHint: true`, `destructiveHint: false`, `idempotentHint: true`, and `openWorldHint: false`.

MCP lifecycle order is `initialize`, server response, `notifications/initialized`, then list/read/call operations. Unknown methods, unknown tools, and malformed requests are JSON-RPC protocol errors. Runtime failures such as an unavailable app, denied permission, stale registration, corrupt store, or exceeded response limit are tool results with `isError: true`, a stable code, limitations, retryability, and recovery guidance. The server never substitutes fabricated or stale-looking success data.

## Read-only inventory

- `get_storage_summary` returns current volume and monitored-scope totals with freshness.
- `explain_growth` returns bounded explanations, confidence, method, and limitations.
- `get_provenance` returns sanitized observations for a path hash or basename query.
- `list_active_writers` returns recently observed writer identities without unsupported claims.
- `get_task_impact` summarizes evidence correlated to one registered local session.
- `find_cleanup_candidates` returns evidence-backed items for human review.
- `export_evidence` returns a bounded inline export using the same snapshot and redaction path as the app exporter.

Static resources expose service status and the evidence interpretation guide. There are no mutation tools.

## Session registration and process correlation

A local adapter registers a client kind, opaque session ID, workspace roots, PID, process start time, and a bounded parent chain. PID alone is never identity because macOS may reuse it. A correlation is valid only while the registration is active, unexpired, authenticated, and the observed PID/start-time ancestry matches. Ended or stale registrations cannot acquire new evidence.

Peer credentials must match the current user. Registration uses a per-launch challenge whose digest may be logged for correlation but whose secret is never persisted. The socket directory and socket are private to the user. Failed peer verification, challenge mismatch, replay, oversized input, or an implausible lifecycle transition fails closed.

Registration can establish at most `tool-linked` confidence. It does not prove that a particular process wrote a file. Direct provenance may later raise an event to `exact`; otherwise the engine reports `inferred` or `unknown` and keeps its limitations. Remote tasks and transcript contents are out of scope.

## Sanitization and bounds

All responses flow through the same privacy policy as file export: metadata only, no file contents, no environment capture, token-like arguments redacted, configured exclusions enforced, and path detail set to full, basename, or hash. Results include a schema discriminator, observation time or range, freshness, truncation, limitations, and confidence where attribution is present. Structured output is also serialized into a text content block for client compatibility.

Default connector ceilings are 10,000 items and 4 MiB per response; individual tools have stricter input limits. A client must narrow its query after `response_too_large`. Cancellation stops query work but does not mutate the evidence store.

## Client installation boundary

Codex local clients support stdio MCP servers through `~/.codex/config.toml`, project-scoped `.codex/config.toml`, the desktop settings UI, or `codex mcp add`; the ChatGPT desktop app, Codex CLI, and IDE extension on the same host share that configuration. Disk Steward supplies a config fragment and helper but does not edit live user configuration without an explicit install action.

Claude Code supports local stdio servers with `claude mcp add`, `claude mcp add-json`, user scope, or a project `.mcp.json`. Project configuration requires the client's trust/approval flow. Disk Steward supplies an isolated configuration fragment and commands but does not import credentials or silently approve a project server.

Both clients launch the same bundled executable and receive the same tool inventory and schemas. If Disk Steward is not running, the connector initializes so it can return actionable `app_unavailable` tool errors and diagnostics.

## Sources checked

- OpenAI, “Model Context Protocol,” checked 2026-09-13: local stdio support, shared Codex-host configuration, `config.toml`, CLI setup, tool allowlists, timeouts, and approval modes.
- Anthropic, “Connect Claude Code to tools via MCP,” checked 2026-09-13: local stdio setup, `claude mcp add`, JSON configuration, user/project scopes, and project approval.
- Model Context Protocol specification, lifecycle, tools, and schema references checked 2026-09-13: initialization order, capability negotiation, tool schemas and annotations, structured-content compatibility, and protocol versus execution errors.
