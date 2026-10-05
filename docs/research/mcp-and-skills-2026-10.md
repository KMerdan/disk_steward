# MCP and agent-skill changes since 2025-06-18 (checked 2026-10-05)

The question: does Disk Steward's read-only stdio MCP helper and its agent
skill need to change for the MCP revisions published after the version it
speaks (`2025-06-18`)?

Sources are primary (the specification, client docs and source) unless
marked otherwise. Client behaviour changes quickly, so recheck before relying
on a detail.

## Specification revisions

**2025-11-25** ([changelog](https://modelcontextprotocol.io/specification/2025-11-25/changelog)):
- Optional `icons` on tools, resources and prompts, and `Implementation.description`.
- Tool-name guidance: 1–128 characters from `[A-Za-z0-9_.-]`. All of ours
  comply.
- JSON Schema 2020-12 is the default dialect. Our input schemas are plain
  and compatible.
- Input-validation failures SHOULD be tool results with `isError: true`, not
  protocol errors (SEP-1303).
- Experimental tasks (`execution.taskSupport`, default `forbidden`). A server
  that does not declare them is unaffected.
- `structuredContent` stays an object, and the serialised JSON SHOULD also be
  sent as text.

**2026-07-28** ([changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
[announcement](https://blog.modelcontextprotocol.io/posts/2026-07-28/)) is a
breaking, stateless revision:
- **No `initialize` or sessions.** The version, client info and capabilities
  travel in each request's `_meta`, and servers MUST implement
  `server/discover`.
- **Results.** Every result carries `resultType`. List and read results
  carry `ttlMs` and `cacheScope`.
- **Moved out of the core.** Tasks become an extension. Multi Round-Trip
  Requests replace server-initiated elicitation, sampling and roots.
  Logging, roots and sampling are deprecated, and `ping` is removed.
- **Annotations are unchanged:** `title` plus the four hints.
- **Fallback on stdio**
  ([transport](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)).
  A dual-era client sends `server/discover` first. Any error other than a
  recognised modern one (-32020 to -32022), or a timeout, marks the server as
  older, and the client falls back to `initialize`. A client that speaks only
  2026-07-28 cannot use a `2025-06-18` server.

No newer revision has been published. The
[roadmap](https://blog.modelcontextprotocol.io/posts/mcp-roadmap/) of
2026-08-22 gives no date.

## Client support

| | Claude Code ([docs](https://code.claude.com/docs/en/mcp)) | Codex ([docs](https://learn.chatgpt.com/docs/extend/mcp)) |
|---|---|---|
| Protocol | **v1:** requests 2025-11-25 and accepts 2025-06-18. **v2:** adds 2026-07-28 and probes stdio with `server/discover` (rolling out behind a flag) | `initialize` with 2025-06-18 by default. 2026-07-28 needs a feature flag and an environment variable |
| `structuredContent` | Supported | The model sees only `structuredContent` ([issue 10334](https://github.com/openai/codex/issues/10334)) |
| Annotations | `readOnlyHint` lets read-only tools run in parallel | In the default `auto` mode, `readOnlyHint` means no approval prompt |
| Tasks | Not supported. Calls over 2 minutes move to the background | Not supported |
| Instructions | Truncated at 2,048 characters | Keep the first 512 characters self-contained |
| Limits | Warns at 10k tokens; above 25k tokens the result is saved to a file | `tool_timeout_sec` is 60 s by default |

## Skills and plugins

- **[Agent Skills specification](https://agentskills.io/specification).**
  - `name` is 1–64 characters of `a-z0-9-` and must match the folder.
  - `description` is 1–1,024 characters, saying what the skill does and when
    to use it.
  - Optional fields: `license`, `compatibility`, `metadata` and
    `allowed-tools`.
  - Keep the body under 500 lines.
  - Our skill complies.
- **[Codex skills](https://learn.chatgpt.com/docs/build-skills)** shorten
  descriptions first when the skill list is over budget, so trigger words
  belong at the start. Ours already starts with them. An optional
  `agents/openai.yaml` can declare the MCP dependency.
- **[Codex plugins](https://developers.openai.com/plugins/build/plugins).**
  - The portable Agent Plugins 1.0.0 layout is preferred: a root
    `plugin.json` and a root `mcp.json` whose servers carry
    `"type": "stdio"`.
  - Our `.codex-plugin/plugin.json` + `.mcp.json` layout is still
    supported.
  - A public directory listing requires a remote HTTPS server.
- **Claude Code** reads skills from `~/.claude/skills` or plugins
  ([docs](https://code.claude.com/docs/en/skills)). Disk Steward ships no
  skill for it; only Codex gets `SKILL.md`.

## What the helper did, checked against 1.5.0 (12)

- **The `server/discover` probe** was answered with -32002 ("not
  initialized"). That should still trigger the fallback, but -32601 is the
  unambiguous "older server" signal.
- **Version negotiation is correct.** A request for 2025-11-25 is answered
  with 2025-06-18.
- **Invalid arguments** are a protocol error (-32602). The contract fixture
  `protocol-error-malformed-input.json` and the `DiskStewardMCPTests` tests
  pin this.
- **Missing fields.** Tools had no `title`. `serverInfo.version` was a fixed
  `1.0.0`, so a client could not tell a stale helper from a current one.
- **Wrong helper path.** The Claude and Codex templates named
  `Contents/MacOS/disk-witness-mcp`, but the app bundle puts the helper in
  `Contents/Helpers/`.

## Done, and left as options

**Done in the MCP polish commit after HOTFIX-1.5.1:**
- `-32601` for unknown methods before initialization.
- Tool and annotation `title`s.
- `serverInfo.title` and the app version.
- Instructions that name the review flow, within 512 characters.
- The templates' helper path.

**Options, not done:**
1. **`outputSchema` per tool.** Codex code mode renders it as types. Every
   success shape would have to conform; it ties to
   FIND-R4-PAGE-SCHEMA-STALE.
2. **A Claude Code skill**, installed by `Scripts/Integration/install
   --client claude` or shipped as a Claude Code plugin.
3. **Invalid arguments as `isError` results (SEP-1303)**, then advertising
   `2025-11-25`. This is a deliberate contract change: the fixture and two
   tests pin the protocol error.
4. **Agent Plugins 1.0.0 layout** for the Codex plugin. It is optional, and
   the current layout works.
5. **`_meta["anthropic/maxResultSizeChars"]`** for `export_evidence`, whose
   answer can exceed Claude Code's 25k-token inline limit.
6. **Deferred:** tasks (no client supports them), progress notifications
   (optional for a 15 s tool), and dual-era 2026-07-28 support (wait until
   Codex enables it by default).
