# Isolated verification and candidate evidence

The `Isolated verification` workflow runs on pull requests, pushes to `main`, and
manual dispatch. It uses GitHub-hosted runners, read-only repository permission,
and no signing/notary/release secrets. Checkout credentials are not persisted.
Do not change this to `pull_request_target`, a privileged reusable workflow, or a
self-hosted runner for untrusted contributions.

The Linux job validates workflow syntax and expressions using pinned actionlint.
The macOS job invokes the same runner available locally:

```sh
task_directory=$(mktemp -d /private/tmp/disk-steward-verification.XXXXXX)
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/Testing/verify_candidate.py \
  --xcodegen "$(command -v xcodegen)" \
  --output "$task_directory/evidence"
```

Requires Xcode with Swift 6, Python 3, XcodeGen, a macOS GUI session for the existing smoke
tests, and at least 8 GiB free scratch space. The output must be a **new absolute
directory outside the checkout**, with an existing canonical parent. Existing
output is never overwritten. Local tests need permission to terminate their own
child process groups; a host sandbox denial is not a test assertion failure.

## What the runner establishes

1. Hashes the explicit source/configuration/test input set, including executable
   modes; rejects linked inputs and oversized snapshots. Records Git HEAD and
   whether the source worktree is dirty. A commit alone never identifies dirty work.
2. Builds from a byte-checked disposable source copy. Swift cache/config/security
   paths and module cache are task-owned. The original checkout is not built in.
3. Passes a small environment allowlist to subprocesses. It does not forward
   credentials, native-client/scale opt-ins, export destinations or signing settings.
   A mistaken normal app launch receives a fail-closed support override; the default
   helper socket points to a nonexistent fixture address.
4. Runs harness tests, manifest/entitlement checks, build and the full ordinary
   Swift suite. Heavy/native tests stay explicitly opt-in. It requires a **passed**
   `testSmokeStartupPreservesLiveFixtureEndpointAndAllSentinelState`, not merely
   that name appearing in discovered/skipped test output.
5. Applies per-command deadlines, retains at most 8 MiB of merged output per stage,
   and terminates only its owned process group. Records exit/stop reason and log
   hashes. Checks source inputs again after verification and records the exact
   debug app/helper binary hashes.
6. With `--xcodegen` (enabled in CI), copies the tested inputs again, generates the
   Xcode project only there, and builds the unsigned `CI` configuration with two
   jobs and private derived-data/package paths. It records the generator's binary
   hash/version, Xcode version, original and generated input manifests. Generation
   may change only the project and generated app Info.plist, not product sources.
7. Hashes every regular file and mode in the bounded app bundle, checks its bundle
   identity, and records both executable architectures. Runs only that freshly
   built app with `--ui-smoke`, requiring typed isolation fields, zero watched
   roots, ephemeral settings, disabled notifications, Agent Access off and removal
   of its fresh UUID smoke directory. Its parent must match either the configured
   temporary directory or the account's OS temporary directory read independently
   through `getconf DARWIN_USER_TEMP_DIR` before launch; Foundation can ignore
   `TMPDIR`. The verifier never deletes a child-reported path. The full bounded
   sentinel tree must remain identical, including no new sidecars, exports or
   directories. A listening fixture socket and held lifetime lock must preserve
   ownership; the socket must receive no connection.
8. Sends the bundled helper a bounded initialization/initialized/tools-list/ping
   transcript with EOF. It requires exact typed IDs, initialization metadata and
   capabilities, usable object input schemas and a non-destructive read-only
   catalog. This is **helper protocol proof, not real app connectivity**. The helper
   points to a nonexistent private socket; `--self-check` is deliberately not used
   because it now makes an app-backed query.
9. Requires all four named historical migration cases to have actually passed in
   the full Swift log. Records the fixture/test source hashes and their scope:
   v5/v6 synthetic stores, 513 staged rows, actual occurrence-time handling, four
   migration interruption boundaries and insufficient-headroom refusal. Discovery,
   skips and a generic green suite do not satisfy this requirement.

Without `--xcodegen`, the runner performs source/debug verification only and reports
`packagedApp: not-tested`. The CI job prepares XcodeGen through Homebrew on its
disposable hosted runner, never on the developer's Mac. Its version is recorded,
not assumed fixed by the moving runner image or package formula. No signing
identity or provisioning profile is used; these CI bundles are not distributable.

Fixture isolation prevents accidental interference; it is **not a security sandbox
for hostile code**. A Swift package/test can execute code. Run untrusted PRs only
on disposable hosted runners without sensitive state, never on a developer Mac.

`candidate.json` distinguishes source test results from release readiness. Its
compatibility section records source macOS/schema declarations and the outstanding
rollback prerequisites; declarations are not compatibility proof. The report does
not include inherited environment values or credentials.

Only logs and `candidate.json` are uploaded, for 14 days. Module caches, temporary
fixtures and build trees are not uploaded. A local run retains its unique scratch
path in the report for diagnosis; remove that exact generated tree after evidence
collection and confirmed process completion. Do not clean a broad temporary root.
Compiler intermediates have no aggregate byte quota; command deadlines and two
build jobs are not disk quotas. Local scratch retention is explicit and manual,
while hosted runners are disposable. Bundle hashes identify the built artifact,
but CI does not preserve the bundle itself for subsequent distribution.

## What is deliberately not claimed

- Debug binaries are not signed/notarized distribution artifacts. No installation,
  Homebrew update, Git push or release publication occurs in this workflow.
- The four opt-in skips do not count as large-scale or real-client coverage.
- Existing tiny forward-migration tests do not prove downgrade compatibility or a
  large/near-cap conversion. Preserve a consistent old-schema backup and verify the
  exact old/new binary and schema relationship before any rollback.
- Synthetic forward-upgrade/interruption orchestration is included. Downgrade
  rollback remains explicitly **not verified**: the current migration does not
  retain the original database after a successful atomic switch. A retained
  consistent backup, exact compatible old binary, sufficient restore space and
  interruption-safe restoration must be established by the recovery gate. Do
  not launch an arbitrary old `.app` on a personal Mac merely because it recognizes
  `--ui-smoke`: old isolation behavior was defective. The packaged verifier accepts
  a source snapshot, not an external app path. Signed-release gates remain separate.
- Scale, overnight monitoring, native clients, EndpointSecurity activation,
  signing/notarization and the final Pyramid gates remain separate requirements.

The workflow pins were checked against upstream release commits:
[checkout v4.2.2](https://github.com/actions/checkout/commit/11bd71901bbe5b1630ceea73d27597364c9af683),
[upload-artifact v4.6.2](https://github.com/actions/upload-artifact/commit/ea165f8d65b6e75b540449e92b4886f43607fa02).
Syntax and permission choices follow the
[GitHub Actions workflow reference](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax);
validation uses [actionlint](https://github.com/rhysd/actionlint/blob/main/docs/usage.md).
