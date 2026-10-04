# TASK-652 AC-03: FSEvents in Documents, Desktop and Downloads (ASM-604)

**Observed 2026-10-04 on macOS 15.6.1 (24G90), Darwin 24.6.0.**

[`tcc-probe.swift`](tcc-probe.swift) opens one directory-level stream with the
journal's flags (`UseCFTypes | WatchRoot`, no `FileEvents`) over
`~/Documents`, `~/Desktop` and `~/Downloads`. It then creates and removes a
hidden directory `.disk-steward-tcc-probe-<pid>` with one file in each, and
counts the events delivered under it. Raw output: [`output.txt`](output.txt).

| Folder | Write | Directory events delivered |
| --- | --- | --- |
| Documents | ok | 2 |
| Desktop | ok | 2 |
| Downloads | ok | 2 |

**Full Disk Access was not granted.** Opening
`~/Library/Application Support/com.apple.TCC/TCC.db` failed with `EPERM`,
which is what a process without Full Disk Access gets.

## What this shows, and what it does not

- **Shown:** FSEvents delivers directory-level changes inside the three
  protected folders to a process without Full Disk Access, on this macOS
  build. ASM-604 holds in that sense, and those scopes do not need to fall
  back to review only.
- **Not shown:** whether delivery depends on the per-folder consent.
  - The probe ran under the Claude Code app's TCC identity, and that identity
    can write to all three folders.
  - A process that was *refused* folder access might be filtered. The probe
    cannot show this, because the watcher and the writer share one identity.
- **Confirmed at GATE-659:** the installed Disk Steward candidate, under its
  own identity, must show the journal listing a change made in `~/Downloads`
  through `explain_growth`.
