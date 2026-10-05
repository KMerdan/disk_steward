# MCP polish after HOTFIX-1.5.1

The fixes below come from the MCP and agent-skill research of 2026-10-05
([`docs/research/mcp-and-skills-2026-10.md`](../../../research/mcp-and-skills-2026-10.md)),
checked against the installed 1.5.0 (12) helper. The helper still speaks MCP
`2025-06-18`. These changes make it answer newer clients' probes cleanly and
describe itself better. No contract that a test pins was changed, apart from
adding fields.

Candidate input: `e328a392e82cef47de72a7822957be64ccca968425ca4d92261d350a4cdc3945`
(on `main` after `c22f173`). It is committed locally only: there is no
version bump, and nothing is installed or published.

## Changes

- **An unknown method is "not found" before initialization too.**
  - In MCP 2026-07-28 a client may probe with `server/discover` before
    `initialize`.
  - 1.5.0 answered -32002 ("Server is not initialized"). It now answers
    -32601, the unambiguous "older server" signal, and the client falls back
    to `initialize`.
  - Known methods before initialization still answer -32002.
- **Tool titles.**
  - Every tool carries a `title` (MCP 2025-06-18), and the same title in
    `annotations.title` for 2025-03-26 clients.
  - Examples: "List review items" and "Measure a folder".
  - The contract schema requires a title, and the inventory fixture carries
    them.
- **`serverInfo` names the app build.**
  - `title` is "Disk Steward".
  - `version` is the app's `CFBundleShortVersionString` when the helper runs
    from `Disk Steward.app/Contents/Helpers`, and `development` otherwise.
  - It was a fixed `1.0.0`, so a client could not tell a stale helper from a
    current one. A Claude session started before an upgrade kept using
    the old helper without saying so.
- **Instructions name the review flow** (336 characters, within Codex's 512):
  "For what can be cleaned, call list_review_items with the scope named as
  get_health shows it (or caches), then get_review_item_evidence for one
  item."
- **The integration templates name the real helper path.**
  - The Claude template and README, the Codex config fragment, and both
    client fixtures said `Contents/MacOS/disk-witness-mcp`.
  - The bundle puts the helper in `Contents/Helpers/`
    (`Config/Packaging/project.yml`), so a copied template started nothing.

## Evidence

**Green** ([`green/`](green/)). A focused isolated run of
`DiskStewardMCPTests`, `MCPContractTests`, `MCPAdmissionTests`,
`ReviewToolsTests` and the agent-integration tests passed 48 tests with 0
failures.

**New tests** in `DiskStewardMCPTests`:
- `testAnUnknownMethodIsNotFoundBeforeAndAfterInitialization`: a
  `server/discover` probe is answered first. A 2025-11-25 `initialize` with
  URL-mode elicitation capabilities then negotiates 2025-06-18.
- `testToolsCarryTitlesAndTheServerItsVersion`.
- `testIntegrationTemplatesNameThePackagedHelper`: every copy names
  `Contents/Helpers`, and the bundle layout says so. The inventory carries
  the live titles and instructions.

**Reds** ([`reds/`](reds/), specs in [`mutations/`](mutations/)):

Each mutation runs on a snapshot of input `e328a392` and fails only its
target test:

| Mutation | Fails |
| --- | --- |
| `discover-not-initialized`: an unknown method before initialize answers -32002, as 1.5.0 did | `testAnUnknownMethodIsNotFoundBeforeAndAfterInitialization` |
| `tools-untitled`: no top-level `title` | `testToolsCarryTitlesAndTheServerItsVersion` |
| `version-fixed`: `serverInfo.version` is the fixed `1.0.0` | `testToolsCarryTitlesAndTheServerItsVersion` |
| `template-path-old`: the Claude template names `Contents/MacOS` | `testIntegrationTemplatesNameThePackagedHelper` |

**Full verification** ([`full/`](full/)). `verify_candidate.py --xcodegen`
on input `e328a392`:
- 733 tests, 11 opt-in skips, 0 failures.
- The packaged CI build exited 0. Its stage is marked
  `launcher-exited-with-descendants` with cleanup verified: the accepted
  FIND-R4-XCODE-WORKER.
- The packaged helper from that build was then probed directly
  ([`full/packaged-helper-probe.json`](full/packaged-helper-probe.json)):
  - `server/discover` answers -32601;
  - a 2025-11-25 `initialize` negotiates 2025-06-18;
  - `serverInfo` is `{"name": "disk-witness-mcp", "title": "Disk Steward", "version": "1.5.0"}`,
    read from the bundle;
  - every tool has its title.

This also covers HOTFIX-1.5.1's input, which is an ancestor: the packaged
build that its two full runs never reached now passes with both changes.

## Not changed (options in the research note)

- Invalid arguments stay protocol errors (-32602); SEP-1303 recommends
  `isError` results. The contract fixture `protocol-error-malformed-input.json`
  and `testMalformedInputAndUnknownToolsAreProtocolErrors` pin the current
  behaviour, so this is a contract change and needs its own decision.
- No `outputSchema`, no tasks, no progress notifications, and no
  2026-07-28 support.
- No Claude Code skill.
