# TASK-253 public repository audit

Date: 2026-09-13

## Local candidate

- `README.md` uses the product's real 704 × 910 light and dark status-board captures copied to `docs/images/`.
- Every local README link and image target resolves.
- `LICENSE` contains the standard MIT text and a 2026 Marudan Kiji copyright notice.
- `.gitignore` excludes Swift/Xcode build products, release archives, certificates, private keys, provisioning profiles, environment files, runtime SQLite databases, and manual evidence-export directories.
- Candidate files contain no certificate, provisioning-profile, environment, runtime-database, or private-key artifact.
- A bounded high-risk credential-pattern scan found no GitHub, AWS, Slack, OpenAI, or PEM private-key value. Product-name and secret-redaction fixtures were reviewed as non-credential matches.
- The complete Swift suite passed: 158 tests, 0 failures.
- `git diff --check` and the staged public-tree inspection are required again immediately before push.

## Publication evidence

- Repository: `https://github.com/KMerdan/disk_steward`
- Visibility: `PUBLIC`
- Default branch: `main`
- First published candidate: `b94bf56532009b362ad6d07774524e5257329b7c`
- GitHub license detection: `MIT License` (`mit`)
- Description: `Native macOS menu-bar disk evidence monitor with bounded local history and read-only MCP for Codex and Claude.`
- Topics: `developer-tools`, `disk-usage`, `macos`, `mcp`, `menu-bar`, `privacy`, `swift`
- Remote content checks found `README.md` and both screenshot assets at their README paths; their GitHub object sizes match the local 8,182-byte README, 105,251-byte light capture, and 104,021-byte dark capture.

The evidence commit that adds these post-publication checks is pushed separately, so the first candidate hash above remains an immutable reference to the source and public project surface that were inspected.
