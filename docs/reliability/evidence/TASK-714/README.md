# TASK-714: MCP 2026-07-28 alongside earlier versions

The helper now serves the stateless MCP `2026-07-28` revision on the same
stdio connection as the `initialize` era (`2025-11-25` and earlier). The
wire details are in
[`docs/research/mcp-2026-07-28-wire-notes.md`](../../../research/mcp-2026-07-28-wire-notes.md).

## Change (`Sources/DiskStewardMCP/MCPServer.swift`)

- **Era per request.** A request whose `params._meta` carries
  `io.modelcontextprotocol/protocolVersion` is a 2026-07-28 request. It is
  served without `initialize`. Any other request belongs to the
  `initialize`-based session, which works as before; both eras can be used
  at the same time.
- **2026-07-28 methods:**
  - `server/discover` answers `supportedVersions: ["2026-07-28"]`, the
    capabilities, the instructions, and the server's identity in
    `_meta["io.modelcontextprotocol/serverInfo"]`.
  - `tools/list`, `resources/list`, `resources/read` and `tools/call` answer
    with `resultType: "complete"` and the same `_meta` identity.
  - List results and discovery carry `ttlMs` and `cacheScope`. The tool and
    resource lists are fixed for a helper binary: one hour, `public`. The
    live status resource is `0` ms and `private`, and the interpretation
    guide is one hour and `public`.
- **Envelope checks:**
  - A version other than `2026-07-28` gets `-32022` with
    `data: {supported, requested}`.
  - A missing `io.modelcontextprotocol/clientCapabilities` gets `-32602`.
  - `initialize`, `ping` and `logging/setLevel` sent with the 2026 `_meta`
    get `-32601`, because they do not exist in that era.
- **Unchanged:** admission (at most four tool calls or reads in flight),
  cancellation, the response bound and every answer.
- **The official schemas.** The upstream `schema.json` files for 2026-07-28
  and 2025-11-25 are vendored, unmodified, in `Fixtures/MCP/upstream/`. That
  folder's README records their source and hashes. The download was approved
  by the maintainer on 2026-10-05.
- **The test validator.** `Tests/DiskStewardMCPTests/UpstreamSchemaValidator.swift`
  checks responses against those files. It supports `$ref`, `allOf`,
  `anyOf`, `oneOf` and schema-valued `additionalProperties`.

## Evidence

| Evidence | Result |
| --- | --- |
| Focused isolated run on input `9d45f706` ([`../TASK-711/green/`](../TASK-711/green/)) | `testA20260728ClientIsServedStatelesslyAndMatchesTheUpstreamSchema` validates every response with the upstream schema: discovery, tools/list, resources/list, resources/read, tools/call (success and an invalid-arguments error). `testThe20260728EnvelopeIsCheckedAndRemovedMethodsAreNotFound` covers the version, envelope and removed-method errors, with the initialize session working alongside |
| [`reds/`](reds/), specs in [`mutations/`](mutations/) | Below |

### Reds

Each mutation runs on a snapshot of input `9d45f706`:
- `no-discover`, `no-result-type` and `no-cache-hints` each fail `testA20260728ClientIsServedStatelesslyAndMatchesTheUpstreamSchema`, which validates every response against the upstream schema.
- `any-version-accepted` fails `testThe20260728EnvelopeIsCheckedAndRemovedMethodsAreNotFound`.
- `modern-needs-initialize` fails both.

## Limitations

- **Stateless only.** The helper does not implement the 2026 extensions
  (tasks, multi-round-trip requests) or progress notifications; it asks the
  client for nothing.
- **Clients.** Codex uses 2026-07-28 only behind a feature flag. Claude
  Code's stdio probing with `server/discover` is rolling out. Both clients
  fall back to `initialize`, which the helper answers as before.
- **Version list.** `supportedVersions` lists only `2026-07-28`; earlier
  versions are reached through `initialize`, as in the reference SDK.
