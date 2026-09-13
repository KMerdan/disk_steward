# TASK-220 visual and accessibility verification

Verified on 2026-09-13 against the native SwiftUI render, the Xcode-built app,
and Apple's current popover, color, Dark Mode, and accessibility guidance.

## Information hierarchy

1. The startup disk and free bytes use the largest type, followed by capacity
   health, the usage bar, and an unambiguous `used of total` sentence.
2. Recent change is a separate row with signed growth, shrink, zero-change, or
   explicit no-baseline wording.
3. Monitoring health is secondary and includes one state-specific action,
   evidence timestamp, and compact database usage versus cap.
4. Agent Access is an independent privacy row whose copy says monitoring and
   stored evidence continue while access is off.
5. Export Evidence is the only prominent button and its accessibility hint
   identifies the export as metadata-only.

No raw file log, retained-window inventory, provenance chain, or destructive
action is displayed in the popover.

## State and accessibility matrix

| State | Text meaning | Deterministic action |
| --- | --- | --- |
| Active | monitoring is current | Pause |
| Paused | stored evidence remains, no new samples expected | Resume |
| Degraded | named monitoring limitation remains visible | Settings… |
| No baseline | a second complete sample is required | Refresh |
| Error | capacity operation and failure are named | Retry |

Every state has a title, detail, symbol, action title, and complete textual
accessibility summary. Capacity health, growth direction, monitoring health,
and Agent Access all have text equivalents and do not rely on color. Native
buttons, toggles, semantic colors, system typography, material, and focus
behavior are retained.

## Visual inspection

- `status-board-light.png`: 352-point compact render, no clipping, semantic
  light appearance, all primary and secondary copy visible.
- `status-board-dark.png`: identical geometry, system dark material and colors,
  no custom fixed backgrounds or ambiguous contrast.
- Both renders are 352 points wide and between 300 and 700 points high.

Apple references:

- https://developer.apple.com/design/human-interface-guidelines/popovers/
- https://developer.apple.com/design/human-interface-guidelines/color
- https://developer.apple.com/design/human-interface-guidelines/dark-mode
- https://developer.apple.com/design/human-interface-guidelines/accessibility

## Verification results

- `swift test --filter StatusBoardPresentationTests`: 3 tests, 0 failures.
- `swift test`: 135 tests, 0 failures.
- Unsigned Xcode Debug build: succeeded.
- Built-app `--ui-smoke`: launched as an accessory app, status item labeled
  `Disk Steward`, snapshot available, left/right click routes correct, Agent
  Access off, and all four utility-menu items present.
- Existing export-action test creates and integrity-checks a snapshot bundle.
- `git diff --check`: passed.
