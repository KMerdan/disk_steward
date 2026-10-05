# MCP wire notes for a dual-era stdio server (checked 2026-10-05)

Research notes gathered for TASK-714 from the MCP specification, the upstream `schema.ts` files and client source. They are notes, not the specification; recheck primary sources before relying on a detail.

## MCP dual-era (2025-06-18, 2025-11-25, 2026-07-28) server notes for a read-only stdio server

**Sources.** I read the spec docs and `schema.ts` from `main` of github.com/modelcontextprotocol/modelcontextprotocol. I diffed them against the `2026-07-28` tag: only link and typo fixes differ, so the content is the released revision.
- Spec pages: https://modelcontextprotocol.io/specification/2026-07-28/ — `changelog`, `basic/index#meta`, `basic/versioning`, `basic/transports/stdio#backward-compatibility`, `server/discover`, `server/utilities/caching`, `server/tools`, `server/resources#error-handling`, `basic/patterns/cancellation`, `basic/patterns/progress`.
- Schemas: `schema/2026-07-28/schema.ts`, `schema/2025-11-25/schema.ts`, plus `schema/2026-07-28/examples/*.json`.

### 1. `server/discover`
- **Must implement:** servers MUST implement it.
- **Request:** `params` is required, with only `_meta` in it (`RequestParams`). There are no body params. It is valid as the very first message, with no handshake.
- **`DiscoverResult` fields:**
  - required: `resultType`, `supportedVersions: string[]`, `capabilities`, `ttlMs`, `cacheScope`
  - optional: `instructions`
  - identity: `_meta["io.modelcontextprotocol/serverInfo"]` (SHOULD)
  - There is **no** body-level `serverInfo`.
- **`ttlMs`/`cacheScope` are required here too.** `DiscoverResult extends CacheableResult`, and the caching page lists `server/discover`. The changelog's list of methods leaves it out.
- **Unsupported version in `_meta`:** the server answers **-32022**, not a `DiscoverResult`. The versioning page's MUST applies to every request, and the stdio probe page lists -32022 as a valid probe outcome.
- **Missing `_meta` or a missing required key:** -32602.

### 2. Per-request `_meta` (request params)

| Key | Type | Required |
|---|---|---|
| `io.modelcontextprotocol/protocolVersion` | string | **Yes** |
| `io.modelcontextprotocol/clientCapabilities` | ClientCapabilities (`{}` = none) | **Yes** |
| `io.modelcontextprotocol/clientInfo` | Implementation | No (SHOULD send; servers must not require it) |
| `io.modelcontextprotocol/logLevel` | LoggingLevel | No (deprecated; if absent, MUST NOT emit `notifications/message`) |
| `progressToken` | string \| number | No |

- **Missing required key:** spec text: "A request missing any required field is malformed; the server **MUST** reject it with JSON-RPC error code `-32602`".
- **Error codes:**
  - **-32022** UnsupportedProtocolVersion. `data` is `{ supported: string[], requested: string }`, both required.
  - **-32021** MissingRequiredClientCapability. `data.requiredCapabilities` is a ClientCapabilities object.
  - **-32020** HeaderMismatch (HTTP only).
  - `-32000..-32019` is legacy/implementation-defined. `-32020..-32099` is reserved for the spec.

### 3. Result envelope
- **`resultType`:** required on **every** result, including `tools/call` and `EmptyResult`. Values are `"complete"` or `"input_required"` (the latter only for MRTR, which you don't need).
- **`ttlMs` and `cacheScope`:** required on `complete` results of `server/discover`, `tools/list`, `resources/list`, `resources/templates/list`, `resources/read` and `prompts/list`.
  - `ttlMs`: integer, `>= 0`.
  - `cacheScope`: `"public"` or `"private"`, the same on every page.
  - `tools/call` does **not** carry them.
- **`_meta["io.modelcontextprotocol/serverInfo"]`:** SHOULD be on every result.
- **Legacy eras:** the 2025-06-18 and 2025-11-25 `Result` types have `[key: string]: unknown`, so extra fields are tolerated there. Omitting them in legacy is cleaner.

### 4. Era detection and backward compatibility on stdio
- **Removed in modern:** `initialize` and `notifications/initialized` no longer exist in the modern era.
- **Versioning page, dual-era servers:** "A request carrying modern per-request `_meta` is served statelessly… An `initialize` request selects legacy semantics, scoped to the stdio process." A dual-era server "MAY serve both eras concurrently".
- **Routing rule:**
  - If `_meta["io.modelcontextprotocol/protocolVersion"]` is present → modern path.
    - Validate the full envelope (missing `clientCapabilities` → -32602).
    - A version not in your modern list → -32022.
    - The TS SDK's `serveStdio` also treats a legacy version such as `"2025-11-25"` sent this way as unsupported; legacy versions are only reachable through `initialize`.
  - If the key is absent → legacy path.
  - A request with no `_meta` version arriving before any `initialize` is ambiguous in the spec. Pick a behaviour: -32602 with a message naming the supported versions, or (as the TS SDK does) treat it as legacy. *Implementation choice.*
- **Client probe:** the stdio page says dual-era clients SHOULD probe with `server/discover` first. Any non-modern error or a timeout counts as legacy; the fallback "MUST NOT be keyed to one specific error code".
- **Probe on a throwaway process:** Claude Desktop/Cowork and the TS SDK may spawn your server **just to answer the probe**, then close stdin (issue anthropics/claude-code#92122; TS SDK `versionNegotiation.ts`). The probe timeout is the client's normal request timeout. So answer `server/discover` immediately with no `initialize`, and exit promptly on EOF (SHOULD).
- **`supportedVersions`:** list `["2026-07-28"]` only. The TS SDK reference server lists only modern versions in both `supportedVersions` and the -32022 `supported` list. The spec's -32022 example also includes `"2025-11-25"`, and both known clients filter out legacy entries. *Recommendation, not a mandate.*
- **No server requests in modern stdio:** the server MUST NOT write JSON-RPC requests to stdout.

### 5. Tools (2026-07-28)
- **Schemas and fields:**
  - `inputSchema` requires root `type:"object"`; any other 2020-12 keyword is allowed.
  - `outputSchema` can be any 2020-12 schema.
  - The default dialect is 2020-12 when `$schema` is absent.
  - Also: `title`, `icons`, `annotations` (`title`, `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`), and `_meta`.
  - There is no `execution` field: tasks moved to the extension `io.modelcontextprotocol/tasks`.
- **`tools/list`:** MUST NOT vary per-connection; SHOULD be in deterministic order.
- **Result:** `content` is required. `structuredContent` can be any JSON value. If `outputSchema` is declared, the server "MUST provide structured results that conform", and SHOULD also put the serialized JSON in a TextContent block.
- **`structuredContent` on `isError` results:** the spec is silent.
- **Errors:**
  - Unknown tool or a malformed `CallToolRequest` → -32602.
  - Input validation errors, such as a value out of range → `isError:true` result. The 2025-11-25 and 2026 tools pages say so, though the `InvalidParamsError` doc comment in schema.ts still says "invalid tool arguments".
- **Legacy-era constraint:** in 2025-06-18 and 2025-11-25, `outputSchema` must have root `type:"object"` and `structuredContent` must be an object. If you have non-object outputs, wrap them for legacy only; the TS SDK uses `{ "result": ... }`.

### 6. Removed methods, error-code changes, cancellation, progress
- **`ping`, `logging/setLevel`, or `initialize` arriving with modern `_meta`:** answer **-32601**. *Inferred:* the stdio page doesn't say this. It rests on `MethodNotFoundError` in schema.ts, the Streamable HTTP page ("404 + -32601"), and the official conformance suite. In the legacy era, `ping` must still be answered.
- **Resource not found:** now **-32602**, and implementations "MUST NOT emit" -32002. Keep -32002 in legacy eras. Never return an empty `contents` array.
- **Cancellation (stdio):** the client MUST send `notifications/cancelled {requestId, reason?}`. The server SHOULD stop and "**MUST NOT** send any further messages for it" — no response. Unknown or completed IDs are ignored.
- **Progress:** unchanged. `_meta.progressToken` triggers `notifications/progress {progressToken, progress, total?, message?}`, and `progress` must increase. Use it for the ~15 s tool; clients MAY reset timeouts on progress.

### 7. Pagination
Unchanged: `params.cursor` and `result.nextCursor`. An invalid cursor → -32602. Each page carries its own `ttlMs`.

### 8. 2025-11-25 vs 2025-06-18 (server side)
- **Version echo:** the server MUST answer with the version the client requested if it supports it.
  - Codex proposes `2025-06-18` by default (`protocol_mode.rs`), so answer `2025-06-18`, not your latest. Simply always reporting 2025-11-25 would break this.
  - For an unknown version, including `initialize` naming `2026-07-28`, answer your latest legacy version (`2025-11-25`).
- **JSON Schema:** 2020-12 is the default dialect, and schemas "MUST be valid according to their declared or default dialect". Avoid draft-04/07-only forms such as tuple `items: [...]` or boolean `exclusiveMinimum`.
- **Input validation errors:** return them as `isError` results (SEP-1303; clarification, no MUST).
- **Tasks:** only if declared. Without the `tasks` capability, the server "MUST process requests of that type normally, ignoring any task-augmentation metadata" (`params.task`).
- **New optional fields:** `icons` on Implementation, Tool, Resource and Prompt; `Implementation.description` and `websiteUrl`; tool-name guidance (SHOULD: 1–128 chars from `[A-Za-z0-9_.-]`).
- **Unchanged:** resource not found stays -32002; `ping` MUST still be answered.

With no tasks capability, valid 2020-12 schemas and correct version echo, nothing else in 2025-11-25 is a new MUST for this server.

### 9. Client behaviour (observed, not spec)
- **Claude Code** (bundled TS SDK v2 client; *inferred from matching error strings in issues*):
  - Validates `structuredContent` against `outputSchema` on success and throws `-32602 "Structured content does not match…"` (#76257).
  - **Skips that validation when `isError`** (TS SDK v2 `client.ts`).
  - Rejects every call to a tool whose `outputSchema` declares `$schema` draft-07: "unsupported dialect" (#90549, #86142, #92122). **Omit `$schema`.**
  - Silently drops tools whose `inputSchema` has a root `allOf`/`anyOf`/`oneOf`/`if` (#95504).
  - On success the model sees only `structuredContent` (#59480). On `isError`, `structuredContent` is dropped and only `content` text is shown (#86032, reproduced by a maintainer).
  - *Unverified:* whether the Claude Code CLI (as opposed to Desktop) probes with `server/discover`, and which version it proposes in `initialize`.
- **Codex** (rmcp 3.3.0):
  - **No** client-side validation against `outputSchema`.
  - Any non-null `structuredContent` **replaces** `content` for the model, **including on `isError`** (`codex-rs/protocol/src/models.rs`).
  - stdio uses legacy `initialize` by default. The modern era is used only when both of these hold: Codex runs in its 2026-07-28 protocol mode, and the server's `env` config sets `CODEX_MCP_PROTOCOL_VERSION=2026-07-28`.
- **Known SDK bug:** TS SDK **1.32.0** (the current 1.x) validates `structuredContent` even on `isError` results (a truthy check with no `isError` guard). An error payload with a different shape therefore becomes a -32602 thrown by the client. The Python SDK and TS SDK v2 skip validation on `isError`.
- **Recommendation:** on success, return schema-conforming `structuredContent` that is self-sufficient, plus a text mirror. On `isError`, put the full message in `content[0].text` and **omit `structuredContent`**.

### Examples (2026-07-28)
`server/discover` request:
```json
{"jsonrpc":"2.0","id":"d1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"ExampleClient","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}}}
```
`server/discover` response:
```json
{"jsonrpc":"2.0","id":"d1","result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"resources":{}},"instructions":"…","ttlMs":3600000,"cacheScope":"public","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"disk-steward","version":"1.5.1"}}}}
```
`tools/list` request:
```json
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
```
`tools/list` response:
```json
{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","tools":[{"name":"get_storage_summary","title":"Storage summary","description":"…","inputSchema":{"type":"object","properties":{"scope":{"type":"string"}},"additionalProperties":false},"outputSchema":{"type":"object","properties":{"totalBytes":{"type":"integer"}},"required":["totalBytes"]},"annotations":{"readOnlyHint":true,"openWorldHint":false}}],"ttlMs":300000,"cacheScope":"public","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"disk-steward","version":"1.5.1"}}}}
```
`tools/call` request (with progress):
```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"progressToken":"p3"},"name":"get_storage_summary","arguments":{}}}
```
`tools/call` response:
```json
{"jsonrpc":"2.0","id":3,"result":{"resultType":"complete","content":[{"type":"text","text":"{\"totalBytes\":123}"}],"structuredContent":{"totalBytes":123},"isError":false}}
```
Unsupported-version error (schema example verbatim):
```json
{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2026-07-28","2025-11-25"],"requested":"1900-01-01"}}}
```
`resources/read` response (`ttlMs`/`cacheScope` are required by the type, though one schema example omits them):
```json
{"jsonrpc":"2.0","id":4,"result":{"resultType":"complete","contents":[{"uri":"diskSteward://guide","mimeType":"text/markdown","text":"# …"}],"ttlMs":60000,"cacheScope":"private"}}
```

The full-depth sources are the four schema.ts files plus the TS SDK and Codex code cited above, read from local scratch clones.
