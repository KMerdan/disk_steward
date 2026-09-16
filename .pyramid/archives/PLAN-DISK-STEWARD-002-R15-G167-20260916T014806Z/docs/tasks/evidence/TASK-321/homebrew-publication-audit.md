# TASK-321 — Homebrew publication audit

Date: 2026-09-13 (Asia/Tokyo)

## Result

Pass for the fail-closed developer-preview contract.

- Public tap: <https://github.com/KMerdan/homebrew-disk-steward>
- Visibility: `PUBLIC`
- Default branch: `main`
- License detected by GitHub: `MIT License`
- Published commit: `ce50961100453ed589d3a14603b21936c6728011`
- Canonical source manifest: `Packaging/Homebrew/Casks/disk-steward.rb`
- Tap manifest: `Casks/disk-steward.rb`
- GitHub releases in `KMerdan/disk_steward`: none at the time of validation

The canonical and published casks match. Both are disabled with the reason `has no notarized release artifact yet`, so no source build or unnotarized application can be installed through this tap.

## Homebrew validation

After explicitly trusting the user's own tap under Homebrew's current third-party tap trust model:

```text
brew trust KMerdan/disk-steward
PASS — Trusted tap: kmerdan/disk-steward

brew tap KMerdan/disk-steward
PASS — Tapped 1 cask

brew style --cask kmerdan/disk-steward/disk-steward
PASS — 1 file inspected, no offenses detected

brew audit --cask --strict kmerdan/disk-steward/disk-steward
PASS — exit status 0, no findings

brew install --cask kmerdan/disk-steward/disk-steward
EXPECTED REFUSAL — Cask 'disk-steward' has been disabled because it has no notarized release artifact yet
```

The initial style pass identified two issues (a non-tarball GitHub placeholder URL and verbose macOS dependency syntax). Both were corrected before the successful style and audit results above.

## Activation controls

`Packaging/Homebrew/README.md` requires all of the following before the disabled guard is removed:

1. Developer ID Application signing and hardened runtime;
2. notarization of the exact archive distributed to users;
3. stapling, Gatekeeper assessment, and launch verification;
4. an immutable versioned GitHub release asset;
5. a pinned semantic version and 64-character SHA-256 in the cask;
6. style, strict audit, install, uninstall, and post-install Gatekeeper checks.

The current `version :latest`, `sha256 :no_check`, and source-tarball URL are non-installable placeholders protected by `disable!`. The checklist explicitly forbids carrying them into an enabled cask.

## Public safety

The tap contains only `Casks/disk-steward.rb`, `README.md`, and `LICENSE`. It contains no application binary, Apple credentials, private keys, provisioning profiles, notarization profile, runtime database, or user evidence.
