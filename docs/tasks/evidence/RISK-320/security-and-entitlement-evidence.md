# RISK-320 security and entitlement evidence

## Negative policy matrix

`Tests/Distribution/release-policy-fixtures.json` contains one complete valid
observation and deterministic invalid variants for:

- wrong application bundle identifier;
- wrong nested-helper signing identifier;
- Apple Distribution instead of Developer ID Application;
- placeholder/wrong team;
- unsigned application;
- invalid nested-helper signature;
- missing hardened runtime;
- missing secure timestamp;
- extra/restricted standard-app entitlement;
- missing notarization staple;
- Gatekeeper rejection.

The policy test accepts only the complete Developer ID observation. It also
asserts that the production verifier contains the corresponding fail-closed
inspection commands and identity constants.

## Real verifier checks

Fresh temporary app bundles exercised three early production paths: missing
helper, wrong app identifier, and unsigned code. Each returned exit 67 with the
specific rejection, and the test removed every temporary fixture.

The production verifier evaluates the actual `.app` or the only app inside the
actual `.xcarchive`; it does not accept a compile result. Both the app and
nested helper pass strict/deep codesign validation before authority, team,
identifier, secure timestamp, and hardened runtime are accepted. The standard
app must contain exactly one entitlement key and one production app-group
value. Stapler validation and Gatekeeper assessment run last, so a successful
archive or shallow signature alone cannot pass.

## Entitlement diff

| Target | Keys |
| --- | --- |
| Standard app | `com.apple.security.application-groups` |
| Optional Endpoint Security component | `com.apple.security.application-groups`, `com.apple.developer.endpoint-security.client` |

The exact-set check rejects the optional restricted key—or any other extra
key—if it appears in the standard exported app.

## Credential scan

The automated scan covered text files below `Config`, `Scripts`, `Sources`, and
`docs/release`. It found no private-key PEM blocks, notarytool stored-credential
commands, or inline Apple/notarization password assignments. The repository
contains only public product/team identifiers and instructions; certificate
private keys and account credentials remain outside the repository.

## Executed results

- `swift test --filter DistributionReleaseIntegrityTests`: 5 passed, 0 failed.
- `Scripts/Distribution/verify --development`: passed and explicitly made no
  signing, system-extension activation, or notarization claim.
- `swift test`: 140 passed, 0 failed.
- `git diff --check`: passed.
