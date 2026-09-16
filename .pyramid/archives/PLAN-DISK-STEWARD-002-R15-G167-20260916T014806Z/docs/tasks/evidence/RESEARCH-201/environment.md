# RESEARCH-201 environment evidence

Observed 2026-09-13:

- Xcode 26.3 (build 17C529), Swift 6.2.4, and `notarytool` 1.1.0 are installed.
- One Apple Distribution identity is installed for Marudan Kiji, Team
  `G3P6TU385Y`.
- No Developer ID Application identity was listed.
- The installed Apple Development identities identify Team `ZMSBHZKAY2`, not
  the paid distribution team; one listed certificate is reported revoked.
- Xcode’s account surface supplied by the user shows Marudan Kiji as an Admin
  team member.
- Three local provisioning-profile files exist, but their presence was not
  treated as proof of matching identifiers or capabilities.
- App ID, App Group, notarization authorization, and Endpoint Security approval
  remain unverified external state. Each has an exact owner action in
  `docs/release/signing-readiness.md`.

No private key, certificate fingerprint, account token, password, device ID, or
profile content is recorded in repository evidence.
