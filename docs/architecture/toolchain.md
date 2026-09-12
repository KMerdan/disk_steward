# Toolchain and Packaging Decision

Status: accepted for the greenfield foundation on 2026-09-12.

## Observed environment

- Host: macOS 15.6.1 (24G90), Apple Silicon (`arm64`).
- Xcode: 26.3 (17C529).
- Swift: 6.2.4, targeting `arm64-apple-macosx15.0` in the current shell.
- Installed macOS SDK: 26.2 through `/Applications/Xcode.app`.
- Code signing: `security find-identity -v -p codesigning` reports zero valid identities.
- The repository was empty before Pyramid Task creation; there is no compatibility surface to preserve.

Raw command evidence is captured under `docs/tasks/evidence/RESEARCH-101/environment.md`.

## Decision

Use one native Swift codebase with explicit product boundaries:

1. `DiskStewardCore`: a platform-aware Swift library containing evidence models, snapshot collection, persistence interfaces, explanation, export, privacy, and retention logic.
2. `DiskStewardApp`: a macOS application target. AppKit owns `NSStatusItem`, mouse-event routing, popover lifetime, and application lifecycle. SwiftUI owns the popover, settings, onboarding, and about views.
3. `disk-steward-mcp`: a small Swift executable using the official MCP Swift SDK and stdio transport. It has no direct database ownership and delegates sanitized requests over local IPC.
4. `DiskStewardEndpoint`: an optional, notification-only Endpoint Security system-extension target added after its contract and feasibility gate. The standard snapshot/FSEvents product must run without it.

Use Swift Package Manager for reusable modules, the MCP executable, dependencies, and unit tests. Keep an Xcode project for the application bundle, UI tests, signing, entitlements, and later system-extension packaging; it should consume the local package rather than duplicate core source.

Minimum deployment target: macOS 13. This matches the native `SMAppService` startup-management boundary and the current official MCP Swift SDK platform requirement. Any API newer than the minimum must be availability-gated and have a tested fallback.

## Dependency policy

- Prefer Foundation, AppKit, SwiftUI, CoreServices/FSEvents, ServiceManagement, UserNotifications, OSLog, and SQLite system capabilities.
- Pin third-party dependencies in `Package.resolved` and introduce them only in the increment that consumes them.
- Add the official `modelcontextprotocol/swift-sdk` only when the MCP contract is implemented.
- Evaluate GRDB when the persistent evidence store is implemented; do not add it during scaffolding merely because it is planned.
- Avoid Electron, an embedded web runtime, a second implementation language, a cloud service, and a persistent localhost HTTP listener.

## Reproducible command boundary

Foundation and shared-module checks:

```sh
swift package resolve
swift build
swift test
```

Application-bundle checks after the Xcode project exists:

```sh
xcodebuild -project DiskSteward.xcodeproj -scheme DiskSteward -configuration Debug build
```

The first runnable-increment gate must record the exact derived product path and launch command rather than assuming it in advance.

## Packaging and distribution boundary

Development may proceed with local debug builds. Developer ID distribution, notarization, and production system-extension installation are unavailable until an appropriate signing identity and entitlements are actually present. No task may report them as passing based only on project settings.

Endpoint Security remains a separate risk boundary because Apple requires a restricted entitlement and user authorization. Its absence must produce an explicit degraded state while preserving whole-volume snapshots, watched-root monitoring, export, and MCP evidence access.

## Known limitations and follow-up validation

- `xcodebuild -showsdks` completed but emitted cache/FSEvents warnings in the current automated shell. `TASK-110` must prove clean project resolution and builds without assuming those warnings are harmless.
- Zero valid signing identities were observed. Signing and notarization checks must report unavailable rather than simulate success.
- The exact Xcode target layout and local-package linkage must be exercised by `TASK-110`; this record selects the boundary but is not build evidence.
- Endpoint Security API, entitlement, and fallback details remain owned by `RESEARCH-401` and `CONTRACT-401`.
- Live Codex and Claude configuration is intentionally deferred to isolated integration fixtures; no personal agent settings are modified by this decision.

