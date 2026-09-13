# Homebrew publication

The canonical cask is [`Casks/disk-steward.rb`](Casks/disk-steward.rb). It resolves the immutable, notarized Disk Steward 1.0.0 release archive and pins its SHA-256 digest.

## Current behavior

```sh
brew trust KMerdan/disk-steward
brew tap KMerdan/disk-steward
brew install --cask disk-steward
```

Current Homebrew releases require explicit trust before loading a third-party tap. Trust the KMerdan tap only if you intend to accept its current and future casks. The commands above install Disk Steward into `/Applications`.

## Activate a release

For future releases, do not update the cask until the exact archive intended for Homebrew has passed the release gate.

1. Archive with the `DiskSteward-Release` scheme and export a Developer ID application.
2. Verify every executable signature, hardened runtime, production entitlements, and secure timestamp with `Scripts/Distribution/verify`.
3. Submit the exact distributable archive for Apple notarization, staple the accepted ticket, validate the staple, run Gatekeeper assessment, and launch-test the extracted app.
4. Upload one immutable GitHub release asset, named `Disk-Steward-<version>.zip`.
5. Calculate its SHA-256:

   ```sh
   shasum -a 256 Disk-Steward-<version>.zip
   ```

6. Replace the placeholder cask header with exact values:

   ```ruby
   version "<version>"
   sha256 "<64-character SHA-256>"

   url "https://github.com/KMerdan/disk_steward/releases/download/v#{version}/Disk-Steward-#{version}.zip"
   ```

7. Remove `disable!`, copy the same reviewed cask to `KMerdan/homebrew-disk-steward`, and run:

   ```sh
   brew style --cask Casks/disk-steward.rb
   brew audit --cask --strict disk-steward
   brew install --cask disk-steward
   brew uninstall --cask disk-steward
   ```

8. Confirm a fresh tap/install resolves the immutable asset and that the installed app passes `spctl --assess --type execute --verbose=4`.

An enabled cask must use an immutable release URL and the exact version and checksum above.

## Why this is gated

Apple's direct-distribution process expects Developer ID signing, hardened runtime, notarization, and testing of the file users actually receive. Homebrew casks identify that file by URL and checksum. The release gate joins those two trust chains rather than treating a successful build as a distributable release.

- [Apple: Developer ID](https://developer.apple.com/developer-id/)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Homebrew: Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [Homebrew: How to create and maintain a tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Homebrew: Tap trust](https://docs.brew.sh/Tap-Trust)
