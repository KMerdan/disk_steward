# Disk Steward status-board contract

Status: normative for `PLAN-DISK-STEWARD-002`.

## Information hierarchy

The menu-bar item is always visible while the app is running. Its popover is a
compact status surface, not a file browser. Information is ordered as:

1. current free-space health and used capacity;
2. recent net growth, shrinkage, or no comparable baseline;
3. monitoring state and evidence freshness;
4. concise Agent Access privacy control;
5. one primary `Export Evidence…` action.

Detailed retention windows, current consumers, exact event records, provenance,
coverage gaps, and export inventory belong in Settings, evidence bundles, or
read-only MCP responses. They must not crowd the popover.

## Presentation states

| State | Required meaning | Available action |
| --- | --- | --- |
| Active | Samples are current and the last complete observation is identified | Pause monitoring |
| Paused | No new samples are expected; prior evidence remains readable | Resume monitoring |
| Degraded | Monitoring continues with a named unavailable source or coverage gap | Open relevant Settings guidance |
| No baseline | A comparison is not yet justified | Refresh or wait for the next complete sample |
| Error | The failed operation and last trustworthy observation are distinguished | Retry or open Settings |

Agent Access has independent `Off`, `Starting`, `On`, and `Degraded` states. It
must not be visually or logically conflated with monitoring state.

## Native behavior

- Use system typography, materials, semantic colors, SF Symbols, spacing,
  buttons, toggles, progress indicators, and standard macOS focus behavior.
- Capacity and growth form the first visual group. Monitoring and recency are a
  quieter secondary group; Agent Access is a privacy row; export is the single
  prominent action.
- Copy is concise, avoids duplicated status sentences, and uses consistent IEC
  or system-formatted units.
- Light and dark appearances, increased contrast, narrow content, keyboard
  traversal, Reduce Motion, and VoiceOver are supported.
- Every symbol and color-coded state has an accessible text equivalent.
- The board reports both the live capacity observation time and the latest
  persisted evidence time when they differ.

## Evidence wording

The UI never says a file was deleted after a partial observation and never says
an agent wrote a file merely because its session was active. `Unknown`,
`out of scope`, `partial coverage`, retained precision, and historical-only
states are valid and visible where relevant.
