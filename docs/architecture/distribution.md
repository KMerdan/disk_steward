# Disk Steward product and distribution contract

Status: normative for `PLAN-DISK-STEWARD-002`.

## Product identity

| Item | Canonical value |
| --- | --- |
| Product | Disk Steward |
| Apple Developer Team | `G3P6TU385Y` |
| Application bundle ID | `com.marudankiji.disksteward` |
| Bundled MCP helper ID | `com.marudankiji.disksteward.mcp` |
| Optional Endpoint Security extension ID | `com.marudankiji.disksteward.endpoint` |
| App Group | `group.com.marudankiji.disksteward` |
| Minimum macOS | macOS 13 |

These values replace every `dev.disksteward`, `group.dev.disksteward.shared`,
`group.com.disksteward.shared`, and placeholder-team value. Identifier
availability is verified separately before portal registration; this contract
does not authorize creating or deleting Apple resources.

## Product boundaries

The standard product is an `LSUIElement` menu-bar application containing a
read-only executable named `disk-witness-mcp` in `Contents/Helpers`. Monitoring,
local evidence, manual export, and the helper must work without Endpoint
Security approval. The helper communicates only through the app-owned Unix
socket and never opens a TCP listener.

The Endpoint Security system extension is optional. It may improve writer and
event-time confidence after Apple grants the restricted entitlement, but its
absence must not prevent the standard application from building, launching, or
correctly reconciling current file state. Its restricted entitlement must never
be copied into the standard app target.

## Signing modes

- Development uses Xcode automatic signing and an Apple Development identity
  for Team `G3P6TU385Y`. An explicit unsigned CI configuration remains valid.
- Direct distribution uses Developer ID Application signing, hardened runtime,
  a secure timestamp, Apple notarization, stapling, and Gatekeeper verification.
- An Apple Distribution identity is not accepted as proof of a valid direct
  distribution artifact.
- The repository stores identifiers and build settings, never private keys,
  passwords, App Store Connect secrets, or notarization keychain profiles.
- The account owner selects signing in Xcode and performs the final Organizer
  archive/export/notarization interaction. Scripts may inspect the result but
  must fail closed when required credentials or Apple evidence are absent.

## Agent Access boundary

Agent Access defaults off on a fresh installation. When disabled, the app
closes active IPC sessions, stops listening, and removes the owner-only Unix
socket. The helper returns a clear disabled-by-user response. Monitoring,
retention, notifications, the human status board, and manual export continue.
The switch never edits Codex or Claude configuration and never exposes a write
or cleanup tool.

## Evidence ownership and retention

Current in-scope file state is independent of historical retention. Default
history is 7 days of raw state/event/provenance detail, at most 30 days of
anomaly detail, 30 days of hourly summaries, and 365 days of daily summaries,
under a 512 MiB database ceiling. Compaction and forced loss are visible.
Manual exports are user-owned and never automatically deleted. MCP temporary
exports are destroyed after delivery.

## Release acceptance

The exact exported application—not merely the source build—must pass nested
code-signature, entitlement, hardened-runtime, timestamp, notarization,
stapling, Gatekeeper, launch, monitoring, Agent Access, evidence-chain, export,
and regression checks. Missing account-backed evidence produces a blocked
release with an exact remediation step, never a success claim.
