# TASK-713: typed and correctable tool answers (MCP 2025-11-25)

This task brings the helper to MCP `2025-11-25`. It also resolves
FIND-R4-PAGE-SCHEMA-STALE, which was accepted at the close of PLAN-006. The
research behind it is in
[`docs/research/mcp-and-skills-2026-10.md`](../../../research/mcp-and-skills-2026-10.md)
and [`docs/research/mcp-2026-07-28-wire-notes.md`](../../../research/mcp-2026-07-28-wire-notes.md).

## Changes

- **Every tool has an `outputSchema`** (`Sources/DiskStewardMCP/MCPOutputSchemas.swift`).
  - The fields every answer carries are required: `schema`, `limitations`
    and, per tool, fields such as `report`/`items` or `capacity_change`.
  - Fields that depend on the evidence available are described but optional,
    with nullable types, so a degraded answer still conforms.
  - The schemas use the default JSON Schema dialect and name no `$schema`,
    because Claude Code rejects tools whose outputSchema declares draft-07.
  - They are published as `Schemas/MCP/tool-output-schemas-v1.json`, and a
    test keeps that file identical to the catalogue.
  - The stale `Schemas/MCP/evidence-query-page-v1.schema.json` is removed.
- **Every answer is checked against its schema.** The caps test drives the
  real helper with every table full and the detail store corrupt, and
  validates every tool's answer against the outputSchema that `tools/list`
  advertises.
- **Invalid arguments are tool errors** (SEP-1303).
  - Arguments that fail a tool's input rules return `isError: true` with
    code `invalid_arguments`, so a model can correct them.
  - Unknown tools and non-object `arguments` stay `-32602` protocol errors.
- **Error results carry their details as JSON text.**
  - The mcp-error-v1 object (`code`, `message`, `retryable`, `recovery`,
    `limitations`) is the result's text, with no `structuredContent`.
  - Why: Codex shows the model only structured content when it is present,
    Claude Code shows only the text on errors, and some SDK versions check
    any structured content against the outputSchema, errors included.
  - `message` is new; it was only in the text before.
- **`initialize` offers `2025-11-25`.** A client asking for `2025-06-18`,
  `2025-03-26` or `2024-11-05` still gets that version echoed back.
- **Contract files updated:**
  - `Fixtures/MCP/tool-call-app-unavailable.json` (text-only error) and the
    new `tool-call-invalid-arguments.json`;
  - `protocol-error-unknown-tool.json`, which replaces the malformed-input
    fixture;
  - the inventory's protocol versions;
  - the contract schema, which now allows `outputSchema`;
  - `docs/architecture/mcp.md`.

The tool `title`s, the `-32601` probe answer and the helper's app version
came earlier, in `f670058`, and are kept.

## Evidence

| Evidence | Result |
| --- | --- |
| Focused isolated run on input `9d45f706` ([`../TASK-711/green/`](../TASK-711/green/)) | 58 tests, 0 failures, including `testEveryToolDeclaresAnOutputSchemaAndThePublishedCopyMatches`, `testInvalidArgumentsAreToolErrorsAndUnknownToolsProtocolErrors`, `testInitializeEchoesASupportedVersionAndOtherwiseOffers20251125`, `testA20251125SessionMatchesTheUpstreamSchema` (results validated against the vendored upstream 2025-11-25 schema) and the caps test with outputSchema validation |
| [`reds/`](reds/), specs in [`mutations/`](mutations/) | Below |

### Reds

Each mutation runs on a snapshot of input `9d45f706` and fails only the tests named here:
- `invalid-arguments-protocol-error` fails `testInvalidArgumentsAreToolErrorsAndUnknownToolsProtocolErrors` and both upstream-schema session tests.
- `error-structured-content` fails `testUnavailableAppAndInsecureSocketReturnActionableErrors` and the 2026-07-28 schema test.
- `output-schema-dropped` fails `testEveryToolDeclaresAnOutputSchemaAndThePublishedCopyMatches`.
- `schema-requires-absent-field` fails the caps test, which shows that the outputSchema check catches a non-conforming answer.
- `no-2025-11-25` fails the version-negotiation tests.

## Limitations

- The outputSchemas are deliberately loose: they type what is present and
  require only what every answer carries. They are a contract for clients,
  not a full description of every nested field.
- Progress notifications for `measure_path` are not sent. They are optional,
  and the 15 s budget sits inside both clients' timeouts.
