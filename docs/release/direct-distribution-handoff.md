# Disk Steward direct-distribution handoff

This workflow intentionally stores no Apple password, private key, App Store
Connect API key, notarytool keychain profile, or certificate material in the
repository. The final account-backed action belongs to the developer in Xcode.

## 1. Obtain the correct certificate class

Disk Steward must use **Developer ID Application** for Team `G3P6TU385Y`.
`Apple Distribution` and `Apple Development` are not valid substitutes for a
public macOS release outside the Mac App Store.

If preflight reports the certificate is missing, ask the Apple Developer
Account Holder to create or authorize a Developer ID Application certificate.
Then install it, including its private key, in the login keychain using:

1. Xcode → Settings → Accounts.
2. Select the Apple ID and the `Marudan Kiji` team.
3. Choose Manage Certificates.
4. Add or download `Developer ID Application`.

The application remains buildable with unsigned Debug and rehearsal workflows
while this release-only credential is unavailable.

## 2. Rehearse without credentials

```sh
Scripts/Distribution/rehearse-handoff
```

This creates an isolated unsigned Release archive, checks bundle construction
and the embedded MCP helper, proves the release verifier rejects the archive,
and removes the temporary rehearsal. It never claims a distributable release.

## 3. Create the signed archive

Choose the shared `DiskSteward-Release` scheme and `My Mac`, then Product →
Archive. Alternatively, use a new absolute archive path:

```sh
Scripts/Distribution/archive-release --release /absolute/path/DiskSteward.xcarchive
```

The script refuses existing paths and stops before invoking Xcode if the exact
Developer ID identity is unavailable.

## 4. Notarize in Organizer

1. Open Window → Organizer → Archives and select the Disk Steward archive.
2. Choose Distribute App.
3. Choose **Developer ID**, then **Upload**.
4. Confirm the signing certificate is Developer ID Application for Team
   `G3P6TU385Y`, review entitlements, and upload.
5. Wait for status **Ready to distribute**. If rejected, inspect Show Status Log
   and fix the named issue; do not bypass the gate.
6. Choose **Export Notarized App**. Xcode exports an app with the notarization
   ticket attached.

If upload authorization is denied, the Account Holder must grant the Apple ID
or App Store Connect API key access. Do not add the credential to this repo.

## 5. Verify the exported app

```sh
Scripts/Distribution/verify-release '/absolute/path/Disk Steward.app'
```

The verifier fails closed unless the app and nested MCP helper have the correct
Developer ID authority and Team ID, hardened runtime, secure timestamps,
expected application-group entitlement, no restricted Endpoint Security
entitlement on the standard app, a valid stapled notarization ticket, and
Gatekeeper acceptance.

Only an artifact that passes this command is ready for direct distribution.

Apple references:

- https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html
- https://help.apple.com/xcode/mac/current/en.lproj/dev88332a81e.html
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
