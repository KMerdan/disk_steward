# GATE-390 final distribution audit

Disposition: **release blocked; product implementation and local journey pass**.

## Exact release artifact

No Developer ID Application identity for Team `G3P6TU385Y` is installed.
Xcode displays Apple Development and Apple Distribution certificate records,
but `security find-identity -v -p codesigning` currently reports **zero valid
code-signing identities**. Neither displayed certificate class is accepted for
direct public macOS distribution. Consequently there is no
exact Developer ID signed, Apple-notarized, stapled export to hash or inspect.

Xcode 26.3 was inspected under Apple Accounts → Marudan Kiji → Manage
Certificates. Apple Distribution is present, but the Create Certificate menu
shows Developer ID Application disabled for this signed-in Admin account. The
remaining action therefore belongs to the Apple Developer Account Holder.
An independent read-only visit to the Apple Developer certificates portal
reached the Apple Account sign-in boundary; no credentials were entered and no
certificate was created, downloaded, or modified.

This gate does not convert an unsigned archive, development build, successful
compile, or Apple Distribution signature into release evidence. Artifact hash,
Developer ID codesign output, production entitlements from the signed export,
Apple notarization/staple validation, and Gatekeeper acceptance remain
unavailable and AC-390-01 is not passed.

## Credential-free release evidence

- Release archive rehearsal constructs the app and executable nested MCP
  helper, then the production verifier rejects the unsigned archive.
- The production verifier requires canonical app and helper identifiers,
  Developer ID Application authority, Team ID, strict/deep signatures, secure
  timestamps, hardened runtime, exactly the standard app-group entitlement,
  a stapled notarization ticket, and Gatekeeper acceptance.
- Twelve policy fixtures cover one complete pass state and eleven failure
  modes. Real temporary bundles confirmed missing-helper, wrong-ID, and
  unsigned-code rejection.
- The release credential scan found no private-key block, stored notary
  credentials, or inline Apple/notary password assignment.

## Inherited product journey

A fresh unsigned Debug build succeeded and its actual main executable and
nested MCP helper were hashed in `product-journey.json`. Built-app smoke
confirmed accessory activation, the menu-bar status item and both click
surfaces, the required utility menu, a live snapshot, and fresh-install Agent
Access/IPC off.

The focused 18-test matrix passed deletion reconciliation, partial-scan
uncertainty, restart/scope/identity semantics, authoritative MCP cleanup
revalidation, MCP on/off service lifecycle, export, the complete product
journey, and the status-board state/accessibility matrix. The complete suite
passed 140 tests with zero failures.

These results support the local product behavior in AC-390-02 but cannot prove
that the not-yet-existing exported release launches. That final launch remains
part of the blocked release verification.

## Exact remediation

The Apple Developer Account Holder must create or authorize **Developer ID
Application** for Team `G3P6TU385Y`, then provide or install it in the login
keychain together with its private key. Xcode currently disables that creation
choice for the signed-in Admin account.

Then:

1. Archive the shared `DiskSteward-Release` scheme.
2. In Organizer choose Distribute App → Developer ID → Upload.
3. Wait for Ready to distribute, then Export Notarized App.
4. Run `Scripts/Distribution/verify-release` on that exact exported `.app`.
5. Launch that same app and rerun the product-journey audit before passing this
   gate.

Per AC-390-03, OUTCOME-220 and INTENT-002 must remain unverified until those
account-backed results exist.
