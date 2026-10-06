# Homebrew Publication & Development AI Preset Guide

This document describes how to build, notarize, package, and publish **Disk Steward** via Homebrew, including how to configure its **Development AI** preset (Model Context Protocol / MCP server integration for Claude Code, Codex, Cursor, VS Code, and Claude Desktop).

---

## Architecture Overview

Disk Steward packages two binaries:
1. `Disk Steward.app` — The native macOS menu bar status board and storage review application.
2. `disk-witness-mcp` — The bundled, read-only Model Context Protocol (MCP) server helper located at `Contents/Helpers/disk-witness-mcp`.

When distributed via Homebrew Cask, the cask links `disk-witness-mcp` directly into Homebrew's binary directory (`/opt/homebrew/bin/disk-witness-mcp` or `/usr/local/bin/disk-witness-mcp`), making it immediately reachable in `$PATH` by coding assistants and terminal environments.

---

## 1. End-User Installation & AI Preset

### Install via Homebrew Tap

```sh
# 1. Trust and tap the repository
brew trust KMerdan/disk-steward
brew tap KMerdan/disk-steward

# 2. Install the Cask
brew install --cask disk-steward
```

### Configure the Development AI Preset

Once installed, the `disk-witness-mcp` tool is accessible in `$PATH`. You can configure all development AI assistants in either of two ways:

#### Option A: One-Click UI Preset (Recommended)
1. Open **Disk Steward** from Applications.
2. Open **Settings** (⌘,) → select the **AI & Agents** tab.
3. Switch on **AI Access (read only)** to activate the local evidence socket.
4. Under **Detected AI Clients**, select your assistants (Codex, Claude Code, Cursor, VS Code, Claude Desktop) and click **Set Up Selected**.

#### Option B: Terminal CLI Automation
Run the bundled preset configuration script:
```sh
# Automatically registers disk-steward MCP server with all detected AI environments
./Scripts/Distribution/setup-ai-presets

# Or dry-run to preview actions:
./Scripts/Distribution/setup-ai-presets --dry-run
```

Or configure individual clients manually:
* **Claude Code**:
  ```sh
  claude mcp add --scope user disk-steward -- $(brew --prefix)/bin/disk-witness-mcp
  ```
* **Codex CLI**:
  ```sh
  codex mcp add disk-steward -- $(brew --prefix)/bin/disk-witness-mcp
  ```
* **Cursor**: Add to `~/Library/Application Support/Cursor/User/globalStorage/cursor.mcp/config.json`:
  ```json
  {
    "mcpServers": {
      "disk-steward": {
        "command": "/opt/homebrew/bin/disk-witness-mcp",
        "args": []
      }
    }
  }
  ```
* **VS Code (Cline / Continue / MCP)**: Add to `cline_mcp_settings.json`:
  ```json
  {
    "mcpServers": {
      "disk-steward": {
        "command": "/opt/homebrew/bin/disk-witness-mcp",
        "args": []
      }
    }
  }
  ```

---

## 2. Release & Publication Pipeline

Follow these steps to produce an immutable, notarized release and publish it to the Homebrew tap:

### Step 1: Create Release Archive
```sh
# Archive with Developer ID signing identity
Scripts/Distribution/archive-release --release /tmp/DiskSteward-1.5.1.xcarchive
```
*(If building without Developer ID for local rehearsal testing, use `--unsigned-rehearsal`)*.

### Step 2: Verify Signatures and Entitlements
```sh
Scripts/Distribution/verify-release /tmp/DiskSteward-1.5.1.xcarchive
```

### Step 3: Notarize with Apple
Export the `.app` from the archive and zip it:
```sh
ditto -c -k --keepParent "/tmp/DiskSteward-1.5.1.xcarchive/Products/Applications/Disk Steward.app" "Disk-Steward-1.5.1.zip"

# Submit for notarization via notarytool
xcrun notarytool submit "Disk-Steward-1.5.1.zip" \
  --keychain-profile "DeveloperID" \
  --wait

# Staple notarization ticket to the app bundle
xcrun stapler staple "/tmp/DiskSteward-1.5.1.xcarchive/Products/Applications/Disk Steward.app"

# Re-create final distributable zip with stapled ticket
ditto -c -k --keepParent "/tmp/DiskSteward-1.5.1.xcarchive/Products/Applications/Disk Steward.app" "Disk-Steward-1.5.1.zip"
```

### Step 4: Calculate SHA-256 Checksum
```sh
shasum -a 256 "Disk-Steward-1.5.1.zip"
```

### Step 5: Upload GitHub Release Asset
1. Tag and release on GitHub:
   ```sh
   git tag v1.5.1
   git push origin v1.5.1
   ```
2. Create a GitHub Release for `v1.5.1` at `https://github.com/KMerdan/disk_steward/releases`.
3. Upload the notarized `Disk-Steward-1.5.1.zip` as a release binary asset.

### Step 6: Update Homebrew Cask
1. Update [`Packaging/Homebrew/Casks/disk-steward.rb`](Casks/disk-steward.rb) with the version and calculated SHA-256 checksum:
   ```ruby
   version "1.5.1"
   sha256 "<64-character-sha256-hash>"
   ```
2. Copy `Casks/disk-steward.rb` into your tap repository (`KMerdan/homebrew-disk-steward`):
   ```sh
   cd ~/localGit/homebrew-disk-steward
   cp /path/to/disk_steward/Packaging/Homebrew/Casks/disk-steward.rb Casks/disk-steward.rb
   git commit -am "Update disk-steward to 1.5.1"
   git push origin main
   ```
3. Validate Homebrew style and audit:
   ```sh
   brew style --cask Casks/disk-steward.rb
   brew audit --cask --strict disk-steward
   ```
