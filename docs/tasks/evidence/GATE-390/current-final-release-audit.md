# Current final release audit

Audit date: 2026-09-15. Candidate: Disk Steward 1.0.0.

## Exact distributable artifact

- GitHub release: `v1.0.0`, public, non-draft, non-prerelease.
- Asset: `Disk-Steward-1.0.0.zip`.
- SHA-256: `5cc6cafeecde5508c58a062726f5b9f9cec9f4d8a1fa722e4472413496684135`.
- The Homebrew download cache produced the same SHA-256.
- The archive contains `Disk Steward.app`, the application executable, compiled icon assets, production Info.plist, embedded distribution profile, and `Contents/Helpers/disk-witness-mcp`.

`Scripts/Distribution/verify-release` passed the exact app installed at `/Applications/Disk Steward.app`. Strict deep signature verification passed. The application is signed by `Developer ID Application: Marudan Kiji (G3P6TU385Y)`, uses the hardened runtime and secure timestamp, and the nested helper is signed and validated independently. Stapler validation succeeded and Gatekeeper accepted the app as Notarized Developer ID.

## Installed product journey

- The Applications copy launches as an LSUIElement accessory and remains registered with LaunchServices.
- Its status item smoke report exposes the Disk Steward accessibility label, status board, utility menu, capacity snapshot, and Agent Access state.
- A missing-icon report was reproduced while the process remained live. iBar Pro's persisted always-display rule contained the release bundle ID, but its live cache omitted the item. Restarting iBar and relaunching Disk Steward restored the drive icon without changing the product.
- The fresh 158-test Swift suite passes folder navigation and deduplication, success-only Finder export handoff, consistent eleven-role evidence bundles, capped multi-slice convergence, complete versus partial deletion semantics, provenance, retention, privacy, and Agent Access off/on behavior.
- The installed helper completed the MCP initialization handshake and listed ten local tools. Every tool is read-only, non-destructive, and closed-world; no deletion tool exists.

## Public distribution surfaces

- [KMerdan/disk_steward](https://github.com/KMerdan/disk_steward) is public on `main`, and GitHub recognizes its MIT license.
- Current promo and evidence commit: `5750d370d0ec8d0e22fd89dd2a050003e7950473`.
- The tracked-file and regression checks found no credentials, private keys, provisioning profiles, runtime database, app bundle, or xcarchive.
- The Homebrew tap `kmerdan/disk-steward` is public and installed. `brew style --cask disk-steward` reported no offenses; online cask audit completed successfully; `brew info` identifies version 1.0.0 and macOS 13 or newer.
- The Remotion composition is 900 frames at 30 fps and 1920×1080. The published H.264/AAC MP4 reports exactly 30 seconds. Representative frames confirm real product imagery, burned-in captions, the read-only MCP boundary, and the explicit no-delete-tool promise.

## Result

Pass. The exact immutable asset, installed application, public source and product story, and Homebrew distribution surface satisfy the release contract. No product requirement was weakened and no user credential was copied into the repository or release workflow.
