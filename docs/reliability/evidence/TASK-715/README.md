# TASK-715: one registration and the skill for both clients

## What was wrong

- **Two installers, two names.**
  - The app's **Settings › Agent Integrations** (what Homebrew users have)
    registers the server as `disk-steward` through each client's CLI.
  - `Scripts/Integration/install` registered `disk_steward`.
  - Using both gave Codex two servers. On the maintainer's Mac in this
    session, running the script after the app replaced the app's entry.
- **The Codex skill never reached Codex.** The script copied the plugin, with
  its skill, into `~/.codex/plugins/disk-steward`. Codex loads plugins only
  from its marketplace cache, so `codex mcp list` and the skill list never
  saw it.
- **No skill for Claude Code.** Only the Codex plugin carried a skill.
- **The Claude path the README gave was unread.** `--config-root ~/.claude`
  wrote `~/.claude/.mcp.json`, which Claude Code does not read (user-scope
  servers live in `~/.claude.json`).
- **A stale tool list.** The script pinned `enabled_tools`, which went stale
  when the catalogue changed in 1.5.0.

## Changes

- **The app installs the skill**
  (`Sources/DiskStewardApp/AgentIntegrations`).
  - Setting up Codex or Claude Code also writes the evidence skill:
    - Codex: `$CODEX_HOME/skills` or `~/.codex/skills`;
    - Claude Code: `~/.claude/skills`.
  - The receipt records the skill's path and hash. Removal deletes the skill
    only while it is unchanged.
  - A skill the user wrote or edited is never overwritten or removed.
  - The text is embedded as `AgentEvidenceSkill.text`, and a test pins it
    byte-identical to
    `Integrations/Codex/disk-steward/skills/disk-steward-evidence/SKILL.md`,
    the single source.
- **The skill itself.**
  - It follows the Agent Skills specification: `name` matches its folder,
    the `description` leads with trigger words, and it adds `license` and
    `compatibility`.
  - It names the `disk-steward` server, the scope names `get_health` shows,
    the error-result format and a safe cleanup workflow (reversible moves,
    re-checking with `get_review_item_evidence`).
- **The script agrees with the app** (`Scripts/Integration/install`,
  `uninstall`, `rollback`, `doctor`, `json-config.swift`):
  - **One name.** It writes `[mcp_servers.disk-steward]` with only
    `command`, as `codex mcp add` does, and refuses when an unmanaged
    `disk-steward` table already exists, from the app.
  - **The skill is the recoverable artifact for both clients**, with the
    existing backup, undo and rollback machinery: Codex
    `<config-root>/skills`, a Claude project `<config-root>/.claude/skills`.
  - **Migration.** A legacy `disk_steward` TOML block is replaced. A legacy
    JSON entry moves to `disk-steward` with the user's own settings. The
    unused `plugins/disk-steward` copy is moved into the backup.
  - **Claude scope.** For Claude the script is project-scope only.
    `--config-root ~/.claude` is refused with the app or
    `claude mcp add --scope user` as the alternative.
  - **No `enabled_tools`.** No published configuration pins a tool list any
    more.
  - **A reinstall no longer adds a blank line** to `config.toml` each time.
- **The Codex plugin package**, kept for marketplace distribution, is no
  longer copied anywhere:
  - its server is `disk-steward` with the absolute helper path;
  - it gains the portable Agent Plugins 1.0.0 layout: a root `plugin.json`
    with OpenAI settings under `extensions.com.openai`, and a root
    `mcp.json` with a `type: stdio` server;
  - `.codex-plugin/plugin.json` stays as the fallback.
- **Docs and fixtures:** the fragment, the client fixtures,
  `Integrations/Claude/README.md` and `docs/integrations/README.md`.

## Evidence

| Evidence | Result |
| --- | --- |
| [`green/`](green/) | Focused isolated run on input `b11ba4ff`: 116 tests, 0 failures. New tests: `testSetupInstallsTheEvidenceSkillAndRemovalTakesOnlyAnUnchangedOne` (both clients), `testTheEmbeddedSkillIsTheIntegrationsSkillByteForByte`, `testCodexInstallRefusesADuplicateAndMigratesTheLegacyInstall`, the rewritten `testClaudeUpgradePreservesUserAdditionsAndUninstallRefusesToDeleteThem` (legacy entry moves with its settings) and `testEveryPublishedToolListIsTheCatalogue` (no pinned list; every copy names `disk-steward`). The rollback suite now restores the skill for both clients |
| [`reds/`](reds/), specs in [`mutations/`](mutations/) | Below |
| GATE-719 | Both installers run on the maintainer's Mac against the installed 1.5.1 |

### Reds

Each mutation runs on a snapshot of input `b11ba4ff`, and the repository is never modified:
- **App adapter:**
  - `skill-not-installed`, `users-skill-overwritten` and `edited-skill-removed` each fail `testSetupInstallsTheEvidenceSkillAndRemovalTakesOnlyAnUnchangedOne`.
  - `embedded-skill-drifts`, which edits the SKILL.md source alone, fails `testTheEmbeddedSkillIsTheIntegrationsSkillByteForByte`.
- **Install script:**
  - `duplicate-registration-allowed`, `legacy-plugin-left` and `claude-user-scope-written` each fail `testCodexInstallRefusesADuplicateAndMigratesTheLegacyInstall`.
  - `tool-list-pinned` fails it, `testCodexInstallUpgradeAndUninstallPreserveUnrelatedConfigurationAndEvidence` and `testEveryPublishedToolListIsTheCatalogue`.
- **JSON merger:** `legacy-entry-kept` fails `testClaudeUpgradePreservesUserAdditionsAndUninstallRefusesToDeleteThem`.

## Limitations

- **Entries the script wrote are not adopted by the app.** The app owns
  only what its receipts record. A `disk-steward` entry written by the
  script shows as external in the app; use one installer.
- **The old plugin copy.** The legacy `plugins/disk-steward` copy moved into
  a backup is not put back by `rollback`. It was never loaded by Codex.
