# Direct-distribution signing readiness

Observed: 2026-09-13 (Asia/Tokyo). This record is sanitized and contains no
certificate fingerprints, private keys, passwords, profile contents, or account
tokens.

## Local environment

| Requirement | Status | Evidence | Exact next action when unavailable |
| --- | --- | --- | --- |
| Xcode toolchain | Ready | Xcode 26.3 (17C529), Swift 6.2.4 | None |
| Notarization client | Ready as a tool | `notarytool` 1.1.0 is installed | None; account authorization is separate |
| Team `G3P6TU385Y` connected in Xcode | Observed | Xcode Accounts screenshot supplied by the user shows Marudan Kiji, Admin | If Xcode later reports the team unavailable, open Xcode Settings → Accounts, select the Apple ID, and refresh the team |
| Apple Development identity for Team `G3P6TU385Y` | Not observed | Installed Apple Development identities belong to Team `ZMSBHZKAY2`; one is reported revoked | In Xcode Settings → Accounts → Marudan Kiji → Manage Certificates, create an Apple Development certificate for the paid team or let automatic signing request it |
| Apple Distribution identity for Team `G3P6TU385Y` | Observed, not sufficient for direct distribution | One installed Apple Distribution identity names Marudan Kiji and Team `G3P6TU385Y` | Do not use it as the final Developer ID identity |
| Developer ID Application identity for Team `G3P6TU385Y` | Not observed | No installed codesigning identity has the Developer ID Application class | In Xcode Settings → Accounts → Marudan Kiji → Manage Certificates, create “Developer ID Application”; the Account Holder may need to authorize creation |
| App ID `com.marudankiji.disksteward` | Unverified | No portal mutation or availability lookup was performed | In Xcode Signing & Capabilities select Team `G3P6TU385Y` with automatic signing, or create the explicit App ID in Certificates, Identifiers & Profiles if Xcode requests it |
| App Group `group.com.marudankiji.disksteward` | Unverified | No portal mutation or availability lookup was performed | Register the App Group in Certificates, Identifiers & Profiles, then attach it to the app and optional extension identifiers |
| MCP helper identity | Locally specified | Contract uses `com.marudankiji.disksteward.mcp`; helper will be nested code in the app | Xcode need not register a separate portal App ID unless the final target/capabilities require one; verify its nested signature in the archive |
| Notarization account authorization | Unverified | Tool availability does not prove App Store Connect authorization | Use Xcode Organizer’s Developer ID distribution workflow; if it fails, the Account Holder must grant the Apple ID/API key notarization access |
| Endpoint Security entitlement | Unverified and optional | Repository models the entitlement only on the separate endpoint target | Request Apple’s Endpoint Security entitlement for the extension identifier; do not block the standard app while it is unavailable |

Three provisioning-profile files are installed locally, but file presence does
not prove they match the new identifiers or required capabilities. Xcode must
resolve or regenerate development profiles after the canonical targets exist.

## Release truth rules

- A successful build or archive is not a direct-distribution release.
- Apple Distribution is not Developer ID Application.
- The final artifact passes only after every executable is Developer ID-signed
  with hardened runtime and a secure timestamp, the submission is notarized,
  the ticket is stapled, and Gatekeeper accepts the exported app.
- If the Developer ID or notarization account step is unavailable, development
  continues with an unsigned CI build or paid-team development build. The
  release gate remains visibly blocked.
- No certificate, profile, App ID, App Group, entitlement request, keychain
  profile, or Apple credential is created or stored automatically by Disk
  Steward’s repository scripts.
