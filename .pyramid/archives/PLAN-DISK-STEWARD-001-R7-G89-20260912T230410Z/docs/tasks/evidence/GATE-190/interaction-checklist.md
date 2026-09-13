# Increment One Interaction Checklist

Observed on macOS 15.6.1 arm64 with Swift 6.2.4.

- [x] A clean debug build compiles and links `DiskStewardCore` and `DiskStewardApp`.
- [x] Normal launch enters the AppKit run loop as an accessory application.
- [x] The live launch probe creates the status item with accessibility label `Disk Steward`.
- [x] Left mouse-up routes to the SwiftUI status board.
- [x] Right mouse-up routes to the utility menu.
- [x] The utility menu exposes Export Current Evidence, Settings, About, and Quit.
- [x] The status board renders current live volume capacity with refresh and export controls.
- [x] The deterministic export fixture contains a concise brief, structured snapshot, and integrity manifest.
- [x] Manifest byte counts and SHA-256 digests match every listed payload.
- [x] Privacy flags deny file contents and environment capture.
- [x] No cleanup, delete, or other destructive user action is exposed. Export rollback is limited to a newly created incomplete bundle.

The attached `rendered-status-board.png` is an offscreen native render because the desktop was locked during automated gate execution. The same view hierarchy is hosted by the runtime `NSPopover`; the live `--ui-smoke` probe independently verifies status-item creation, routes, accessibility label, required menu entries, and a real snapshot.
