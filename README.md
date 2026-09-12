# Disk Steward

Disk Steward is a native macOS menu-bar evidence recorder for understanding disk growth and sharing trustworthy, structured storage evidence with humans, Codex, and Claude.

The repository is being delivered through the Pyramid Task graph in `.pyramid/`. The first demonstrable increment will show a real volume snapshot in a menu-bar status board and export a safe snapshot bundle. Monitoring, historical evidence, MCP integration, and optional privileged provenance arrive as separately audited cumulative increments.

## Requirements

- macOS 13 or newer
- Xcode 26.3 or another toolchain capable of Swift 6
- No signing identity is required for Swift package development and tests

Developer ID distribution, notarization, and production Endpoint Security installation require credentials and entitlements that are not currently available on the observed development machine.

## Foundation commands

Resolve, build, and test the current package:

```sh
swift package resolve
swift build
swift test
```

Run the current accessory-process skeleton:

```sh
swift run DiskStewardApp
```

The skeleton intentionally has no visible status item yet. `TASK-112` owns the menu-bar interface and first user-visible launch behavior.

## Architecture

See [`docs/architecture/toolchain.md`](docs/architecture/toolchain.md) for the selected target layout, packaging boundary, dependency policy, and currently unavailable prerequisites.

## Safety boundary

The current product intent observes, explains, and exports evidence. It does not delete files, purge caches, terminate processes, inspect file contents, upload evidence, or expose destructive MCP tools.
