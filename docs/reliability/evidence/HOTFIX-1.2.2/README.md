# Local dashboard hotfix 1.2.2 (build 7)

**Subsequent release:** the user later authorized publication. The same focused
hotfix was notarized and published as v1.2.2, with the matching Homebrew update.
See [release notes](../../releases/1.2.2.md) and the 1.2.2 record in CONTEXT.md.
The local-installation and CI observations below remain historical evidence;
they do not describe the later artifact's notarization status.

This is a local installation record, not a public release or completion of the
object-scanner plan. No notarization, Homebrew update or release upload occurred.

## Source and compatibility

The `hotfix/dashboard-1.2.2` branch starts at `v1.2.1` and backports the live
dashboard/alert fixes and supervised verification. It excludes unfinished
schema-15/object changes on main. EvidenceStore remains unchanged at schema 14.

The app and MCP helper are universal Intel/Apple Silicon binaries, Developer ID
Application signed with hardened runtime. The installed app reports 1.2.2 (7).

## Checks and limits

- All 13 small supervisor bootstrap scenarios passed.
- 575 Swift tests executed: 5 intentional opt-in skips, zero failures.
- Signed-app isolated startup and MCP initialize/tools-list/ping checks passed.
- Strict signature verification passed for both architectures.
- Normal installed startup and a read-only live MCP query succeeded. Existing
  settings and evidence were preserved; the previous app remains recoverable
  from Trash. On-screen UI automation could not be completed; hosted-view
  regression tests supply the rendering checks.
- File-detail coverage remains partial; this hotfix addresses capacity display,
  not the unfinished object-scanning feature.

Xcode completed the archive successfully but left an Interface Builder worker
running. The supervisor stopped that owned worker and verified cleanup, and
correctly recorded a failed supervision stage. Independent artifact checks
supported local installation; they do not turn that result into a passing
automated-release gate. A bounded expected-worker lifecycle design remains
follow-up work.

Raw build/test logs and installation records are retained locally in ignored
`build/local-1.2.2/evidence/`, not published with this summary.

## CI follow-up

The first main-branch CI attempt exposed a pre-existing older-SDK concurrency
error in notification-permission handling. The separate main-only repair
extracts the authorization enum inside the native callback instead of passing
a non-Sendable settings object across actors. Ten isolated notification tests
passed. This repair is not included in the already installed hotfix; main and
the hotfix branch must not be treated as identical release inputs.

The CI rerun still fails on two further older-toolchain concurrency diagnostics:
the unfinished object-store collapse callback and the native async permission
request. CI is **not green**. These require follow-up; no claim of automated
release readiness is made by the local installation or passing local tests.
