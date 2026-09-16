# TASK-310 release workflow evidence

Recorded 2026-09-13 on the development Mac for Team `G3P6TU385Y`.

## Result

The repository now has one shared archive-only scheme, a Developer ID export
configuration, a credential preflight, an archive driver, a fail-closed
artifact verifier, and a self-cleaning unsigned rehearsal. No credential or
certificate fingerprint is stored in the repository or in this evidence.

The current Mac does not have a `Developer ID Application` identity for this
team. That is an expected external release prerequisite, not a development
failure. `release-preflight` exits 66 before invoking Xcode and supplies the
exact Account Holder and Xcode Manage Certificates action. Installed Apple
Development and Apple Distribution identities are explicitly rejected as
substitutes for direct distribution.

## Acceptance chain

1. `DiskSteward-Release.xcscheme` archives only the app under the Release
   configuration; the target dependency and post-build phase place the
   `disk-witness-mcp` executable in `Contents/Helpers`.
2. `Release.xcconfig` selects Developer ID Application, the production team,
   hardened runtime, production bundle identifiers, and the standard app-group
   entitlement. The standard app does not receive Endpoint Security rights.
3. `archive-release --release` runs credential preflight before Xcode and
   refuses relative, reused, or non-archive destinations.
4. `verify-release` resolves exactly one app from an archive or accepts the
   exported app directly. It checks both app and helper with strict/deep
   codesign verification, then checks application and nested-helper bundle
   identities, authority class, Team ID, secure timestamp, hardened runtime,
   entitlements, stapled notarization, and Gatekeeper acceptance.
5. The verifier rejects wrong product identifiers, Apple Distribution,
   missing/invalid/ad-hoc signatures, missing nested code, missing
   timestamp/runtime/app group, restricted Endpoint Security entitlement,
   absent staple, and Gatekeeper rejection.
6. Organizer remains the credential boundary. The handoff documents Developer
   ID Upload, waiting for Ready to distribute, Export Notarized App, and final
   verification of that exact exported app.

## Executed checks

- Shell syntax: four distribution scripts passed `zsh -n`.
- Configuration syntax: Developer ID export plist passed `plutil -lint`; the
  shared scheme passed `xmllint --noout`.
- Rehearsal archive: Xcode completed a Release archive for the generic macOS
  destination with signing disabled.
- Nested code: the rehearsal confirmed an executable
  `Disk Steward.app/Contents/Helpers/disk-witness-mcp`.
- Negative handoff: the unsigned archive was rejected by `verify-release` and
  could not be presented as distributable.
- Credential diagnostic: the missing Developer ID identity produced exit 66
  and the contracted Account Holder/Xcode next action.
- Regression: `swift test` passed 135 tests with zero failures.
- Hygiene: `git diff --check` passed.

The unsigned rehearsal is created below `/private/tmp`, removed on every exit,
and never retained as release evidence. A signed/notarized artifact inspection
is intentionally deferred until the external Developer ID certificate exists;
the final verification command cannot pass without that real Apple evidence.
