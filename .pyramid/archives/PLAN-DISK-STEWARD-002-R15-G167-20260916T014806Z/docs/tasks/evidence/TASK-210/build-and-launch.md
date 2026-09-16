# TASK-210 build and launch evidence

Status: implementation complete; ready for Pyramid audit.

## Product shape

- Canonical project: `DiskSteward.xcodeproj`
- Shared scheme: `DiskSteward`
- Product: `Disk Steward.app`
- Bundle identifier: `com.marudankiji.disksteward`
- Minimum system: macOS 13
- Application policy: `LSUIElement = true` / accessory activation, with no Dock icon
- Optional Endpoint Security code is not a dependency of the standard app target
- Read-only helper: `Contents/Helpers/disk-witness-mcp`
- App icon: complete 16 through 1024 pixel macOS catalog, compiled to `AppIcon.icns` and `Assets.car`

`Config/Packaging/project.yml` is the maintainable source for the generated Xcode
project. `Scripts/Development/build_xcode_project` regenerates and builds it.

## Signing paths

- Debug: automatic Apple Development signing for team `G3P6TU385Y`.
- Release: manual Developer ID Application signing with hardened runtime.
- CI: explicit unsigned configuration (`CODE_SIGNING_ALLOWED = NO`).

The Debug build resolved a development profile and its signed entitlements report
application identifier `G3P6TU385Y.com.marudankiji.disksteward`, team identifier
`G3P6TU385Y`, and app group `group.com.marudankiji.disksteward`.

## Verification transcript

- Signed Debug build with `-allowProvisioningUpdates`: **BUILD SUCCEEDED**.
- Unsigned CI build: **BUILD SUCCEEDED**.
- `codesign --verify --deep --strict`: valid on disk and satisfies its designated requirement.
- Bundle metadata checks: version `1.0.0` build `1`, `LSUIElement = true`, permanent identifier, and Documents/Downloads privacy descriptions present.
- UI smoke launch created an accessory status item with accessibility label `Disk Steward`, a left-click status board, and a right-click utility menu.
- Real app launch stayed running as the menu-bar process (observed PID 37575 during verification).
- Bundled helper answered MCP `initialize` as `disk-witness-mcp` version `1.0.0` with read-only tool/resource capabilities.
- `swift test`: 111 tests, 0 failures.
- `git diff --check`: no whitespace errors.

The observed process identifier is transient evidence only; it is not a product
identifier or a release claim.
