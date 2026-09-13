# TASK-252 interaction regression

## Trigger evidence

- User reproduction: choosing a third watched folder closed the system folder picker and no root was added.
- Four matching reports were present for `com.apple.appkit.xpc.openAndSavePanelService` on 2026-09-13.
- The latest report records `NSInvalidArgumentException: -[__NSCFNumber length]` on the AppKit panel service's Core Animation / Metal submission queue.
- Disk Steward previously called `NSOpenPanel.runModal()` synchronously, so the selected URL was never delivered when Apple's panel service terminated.

## Repair

- `MonitoringSettingsView` now presents an in-app SwiftUI directory browser. It does not instantiate `NSOpenPanel` or `openAndSavePanelService`.
- The browser supports Home, parent navigation, direct path entry, visible subdirectory navigation, readable-directory validation, cancel, and purpose-specific confirmation.
- Selected URLs are standardized before the existing settings normalization and persistence path; duplicate roots collapse to one entry.
- The durable export callback now calls `NSWorkspace.open` with the completed bundle URL, which opens that evidence directory itself. The callback remains success-only.

## Verification

- Focused picker/export tests: 6 passed, 0 failures.
- Full Swift suite: 158 passed, 0 failures.
- Xcode Debug build: succeeded and signed with Apple Development; deployed product is `/private/tmp/disk-steward-derived/Build/Products/Debug/Disk Steward.app`.
- Exact rebuilt process was launched and observed running as PID 61531.
- Source search found no remaining `NSOpenPanel`, `openAndSavePanelService`, or `runModal()` use under `Sources` or `Tests`.
- `git diff --check`: passed.

The menu-bar-only app cannot be attached through the available accessibility automation surface, so the final click-through is intentionally left to the cumulative application audit with the user. The stale release archive must not be notarized.
