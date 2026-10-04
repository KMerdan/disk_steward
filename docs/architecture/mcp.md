# Local Agent and MCP Contract

Status: version 1 contract for local Codex and Claude integration, with the tool catalogue rebuilt on the review report (TASK-671, rung 4).

## Boundary

`disk-witness-mcp` is a bundled local stdio server. It never listens on TCP or HTTP, opens a database, records file contents, captures environment variables, or accepts credentials. It talks to the running Disk Steward app over an authenticated Unix-domain socket owned by the current user and mode `0600`. The app remains the sole owner of the capacity ring, the steward store (change journal, object index, reviews, sessions), sanitization and export consistency.

The connector exposes only queries. It cannot delete, move, or modify files; stop processes; pause monitoring; change settings; install components; or alter evidence. Review items are evidence for a person to review and never declare a path safe to delete. `measure_path` is the only tool that reads the file system, and only within its budget. `export_evidence` returns an inline, bounded representation and accepts no filesystem destination.

## MCP compatibility

The server negotiates MCP protocol `2025-06-18`, with compatibility for `2025-03-26` and `2024-11-05`. Initialization advertises stable tools and resources, no prompts, sampling, logging, subscriptions, or task-augmented execution. Tools use closed JSON Schema inputs, bounded item counts and byte budgets, and the standard annotations `readOnlyHint: true`, `destructiveHint: false`, `idempotentHint: true`, and `openWorldHint: false`.

MCP lifecycle order is `initialize`, server response, `notifications/initialized`, then list/read/call operations. Unknown methods, unknown tools, and malformed requests are JSON-RPC protocol errors. Runtime failures such as an unavailable app, denied permission, stale registration, corrupt store, or exceeded response limit are tool results with `isError: true`, a stable code, limitations, retryability, and recovery guidance. The server never substitutes fabricated or stale-looking success data.

## Authoritative read-only inventory

Every answer comes from the capacity ring, the change journal and the steward
store's review report and object index, all with hard caps (CONTRACT-602). No
tool reads the retired per-file store.

- `get_storage_summary` reports live whole-volume capacity, the comfort reserve
  and the capacity history; it never depends on file detail.
- `get_health` reports the stores' sizes against their caps, each table's rows
  and caps, the latest review of each scope, a running review, the change
  journal's coverage and gaps, growth attribution, kept sessions and any legacy
  evidence.
- `explain_growth` returns the capacity change for a window, the volume delta
  attributed to re-measured objects with the unexplained remainder (System
  Data, purgeable space, snapshots, out of scope; never a cause), changed
  folders and journal gaps.
- `list_review_items` returns the latest review's ranked items for a scope
  (a configured folder, or `caches`) with the same sizes, evidence states
  (Verified now, Stale, Partial, Unknown), totals and report state as the
  review window. `get_review_item_evidence` adds one item's reasons to keep it,
  why it may be disposable, its recreate and cleanup commands (text, never
  run) and a live check.
- `list_largest_objects` returns the object index largest first, optionally
  under one scope, with each object's last measurement.
- `measure_path` measures one folder inside the configured scopes or opted-in
  caches within 15 s and 500,000 entries. It is the one walk in flight: a
  running review is joined (waited for within the budget), never run beside.
  It stores nothing and writes no cooldown; a stopped measurement is a lower
  bound.
- `list_active_agent_sessions` returns active authenticated contexts with the
  folders their workspaces saw change, and never calls them writers.
- `get_task_impact` returns the folders that changed at, inside or above a
  registered session's workspace during its window, with the objects there,
  rows collapsed to a watched root reported apart, and gaps. Sessions are kept
  in the steward store and survive a relaunch.
- `export_evidence` returns the steward evidence for a window (capacity,
  changed folders, reviews, growth attributions, sessions) and the legacy
  evidence read-only from a clone when it fits; otherwise it says how to
  export the legacy evidence to a file.

`get_provenance` is listed only while an Endpoint Security bridge is active;
the app runs none today, so it is not listed. `find_cleanup_candidates`,
`list_current_consumers` and `get_evidence_lifecycle` were replaced by the
review tools and `get_health`; the `list_active_writers` alias was dropped.

Static resources expose the health answer and the evidence interpretation guide. There are no mutation tools.

## Session registration and process correlation

A local adapter registers a client kind, opaque session ID, workspace roots, PID, process start time, and a bounded parent chain. PID alone is never identity because macOS may reuse it. A correlation is valid only while the registration is active, unexpired, authenticated, and the observed PID/start-time ancestry matches. Ended or stale registrations cannot acquire new evidence.

Peer credentials must match the current user. Registration uses a per-launch challenge whose digest may be logged for correlation but whose secret is never persisted. The socket directory and socket are private to the user. Failed peer verification, challenge mismatch, replay, oversized input, or an implausible lifecycle transition fails closed.

Registration can establish at most `tool-linked` confidence. It does not prove that a particular process wrote a file. Direct provenance may later raise an event to `exact`; otherwise the engine reports `inferred` or `unknown` and keeps its limitations. Remote tasks and transcript contents are out of scope.

## Sanitization and bounds

All responses flow through the same privacy policy as file export: metadata only, no file contents, no environment capture, token-like arguments redacted, configured exclusions enforced, and path detail set to full, basename, or hash. Results include a schema discriminator, observation time or range, freshness, truncation, limitations, and confidence where attribution is present. Structured output is also serialized into a text content block for client compatibility.

Every answer is at most 1 MiB, with every table at its cap; the connector's transport ceiling is 4 MiB. Requests time out after 10 s, except `measure_path`, whose 15 s budget runs under a 25 s deadline. A client must narrow its query after `response_too_large`. Cancellation stops query work, including a measurement, and mutates nothing.

Every query filters and orders in SQLite, within each table's cap, before limiting or paginating. Canonical
path/object matching occurs before privacy shaping. Bounded responses report
`matched_count`, `returned_count`, `truncated`, and `next_cursor`; interval
responses report requested versus actually retained time and coverage gaps.
Interactive history defaults newest-first unless the request specifies order.

## Client installation boundary

Codex local clients support stdio MCP servers through `~/.codex/config.toml`, project-scoped `.codex/config.toml`, the desktop settings UI, or `codex mcp add`; the ChatGPT desktop app, Codex CLI, and IDE extension on the same host share that configuration. Disk Steward supplies a config fragment and helper but does not edit live user configuration without an explicit install action.

Claude Code supports local stdio servers with `claude mcp add`, `claude mcp add-json`, user scope, or a project `.mcp.json`. Project configuration requires the client's trust/approval flow. Disk Steward supplies an isolated configuration fragment and commands but does not import credentials or silently approve a project server.

Both clients launch the same bundled executable and receive the same tool inventory and schemas. If Disk Steward is not running, the connector initializes so it can return actionable `app_unavailable` tool errors and diagnostics.

## Sources checked

- OpenAI, “Model Context Protocol,” checked 2026-09-13: local stdio support, shared Codex-host configuration, `config.toml`, CLI setup, tool allowlists, timeouts, and approval modes.
- Anthropic, “Connect Claude Code to tools via MCP,” checked 2026-09-13: local stdio setup, `claude mcp add`, JSON configuration, user/project scopes, and project approval.
- Model Context Protocol specification, lifecycle, tools, and schema references checked 2026-09-13: initialization order, capability negotiation, tool schemas and annotations, structured-content compatibility, and protocol versus execution errors.
