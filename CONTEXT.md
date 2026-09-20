# Disk Steward development and release context

Last updated: 2026-09-20. This is a continuation guide, not proof that the
current source or a newly built artifact is already notarized or released.

## Project and safety boundaries

- Native Swift 6 / SwiftUI / AppKit macOS menu bar app; minimum macOS 13.
- `Sources/DiskStewardApp` owns the UI; `DiskStewardCore` owns evidence;
  `DiskStewardMCP` supplies the bundled read-only `disk-witness-mcp` helper.
- Use `.pyramid` for canonical implementation history. Reliability plan
  `PLAN-DISK-STEWARD-005` was completed at R17/G175 before the release follow-ups
  described here. Do not rewrite that completed history or claim its evidence
  covers subsequent changes.
- Preserve unrelated worktree changes. Do not replace the installed app, modify
  live evidence/settings, publish, push, or upload an artifact without the
  user's authorization for that action.
- Use `Scripts/Testing/verify_candidate.py` for isolated verification. Do not
  run the normal app or tests against the user's live evidence database.

## Notarization failure and proven repair

On September 18, the first 1.2.0 upload failed locally at Xcode's signing-assets
step, before submitting anything to Apple's notary service:

```text
error: exportArchive "Disk Steward.app" requires a provisioning profile with the App Groups feature.
** EXPORT FAILED **
```

The archive's Developer ID signature and embedded provisioning profile were
valid. The profile already authorized `group.com.marudankiji.disksteward`.
The actual problem was **manual export options without a `provisioningProfiles`
mapping**. An embedded profile and `PROVISIONING_PROFILE_SPECIFIER` at build time
do not replace this export-time selection.

The durable fix is in `Config/ExportOptions/DeveloperID.plist`:

```xml
<key>provisioningProfiles</key>
<dict>
  <key>com.marudankiji.disksteward</key>
  <string>Disk Steward Developer ID Distribution</string>
</dict>
```

Keep these identities consistent:

| Setting | Value |
| --- | --- |
| Distribution method | `developer-id` |
| Signing style | `manual` |
| Certificate class | `Developer ID Application` |
| Team | `G3P6TU385Y` |
| App bundle ID | `com.marudankiji.disksteward` |
| Helper identifier | `com.marudankiji.disksteward.mcp` |
| Profile name | `Disk Steward Developer ID Distribution` |
| App Group | `group.com.marudankiji.disksteward` |

The successful local retry selected the installed profile by UUID
`193d15aa-43f8-4477-bdab-58cf2e59964f`. This UUID is historical evidence, not a
permanent requirement: regenerated profiles can have a different UUID. The
checked-in template uses the profile name. No profile is mapped to the
standalone MCP helper.

After explicit user approval, `xcodebuild -exportArchive` succeeded at
**2026-09-18 19:38:41 JST**, reporting `Uploaded DiskSteward-Release` and
`EXPORT SUCCEEDED`. This proved the upload repair, not notarization acceptance.
The archive's distribution record was still **Processing** at the last check.

Local incident evidence (temporary paths may disappear):

- Failed attempt: `/private/tmp/ds-release-1.2.0/upload.out`
- Corrected upload options: `/private/tmp/ds-release-1.2.0/upload-options.plist`
- Successful upload log: `/private/tmp/ds-release-1.2.0/upload-fixed.out`
- Submitted archive: `/private/tmp/ds-release-1.2.0/upload-copy.xcarchive`
- Xcode distribution record: `9C72B602-05CE-4810-900D-3C72B81871B6`

Do not assume the Xcode distribution-record UUID is a `notarytool` submission
ID. Obtain the actual service ID from the relevant upload/status output if
using that interface.

## Repeatable release workflow

1. Set the intended version/build in `Config/Packaging/project.yml`. XcodeGen
   generates `Config/Packaging/DiskSteward-Info.plist` from those properties;
   keep them synchronized. Check the built bundle's plist, not only source.
   Use a new build number when rebuilding a submitted candidate with changes.
2. Verify source in isolation, with a new output directory outside the repo:

   ```sh
   check_work=$(/usr/bin/mktemp -d /private/tmp/disk-steward-check.XXXXXX)
   python3 Scripts/Testing/verify_candidate.py --output "$check_work/evidence"
   ```

3. Build a fresh signed archive with
   `Scripts/Distribution/archive-release --release /absolute/new-path/DiskSteward.xcarchive`.
   It finalizes the app/helper signatures with hardened runtime and timestamps.
   Never overwrite an earlier submitted artifact.
4. Copy the checked-in export template and change only the destination for an
   upload. Confirm the intended archive and obtain user approval before sending
   the compiled app to Apple. Run from the repository:

   ```sh
   upload_work=$(/usr/bin/mktemp -d /private/tmp/disk-steward-upload.XXXXXX)
   cp Config/ExportOptions/DeveloperID.plist "$upload_work/options.plist"
   /usr/bin/plutil -replace destination -string upload "$upload_work/options.plist"
   /usr/bin/plutil -lint "$upload_work/options.plist"
   /usr/bin/xcodebuild -exportArchive \
     -archivePath /absolute/path/DiskSteward.xcarchive \
     -exportOptionsPlist "$upload_work/options.plist" \
     -exportPath "$upload_work/export" > "$upload_work/upload.log" 2>&1
   ```

5. Distinguish **upload succeeded** from **notarization accepted**. Check the
   exact archive in Xcode Organizer. If processing is pending, do not repeatedly
   resubmit. If rejected, inspect the status log. Once ready, export the notarized
   app and run `Scripts/Distribution/verify-release /absolute/path/Disk\ Steward.app`.
6. Only after verification, package the final stapled app and calculate the
   checksum of that exact archive. GitHub release, Homebrew cask update, commit,
   push, and installation are separate authorized steps—not upload retries.

For GUI and verification details see `docs/release/direct-distribution-handoff.md`.

## Two fallback-script traps

The temporary `release-1.2.0.sh` script was **not** used for the successful retry.

- It expected a `notarytool` Keychain profile named `disk-steward-notary`, but
  that profile did not exist when checked. Xcode account login does not create
  named `notarytool` credentials. Its preflight now checks availability before
  creating/uploading a ZIP. Configure credentials privately, not in this repo
  or chat; the working Xcode route does not require that named profile.
- It assigned to `status`, a read-only zsh parameter. This was renamed to
  `notary_status` in both assignment and comparisons. Shell syntax checking
  alone does not detect this runtime error.
- That script also publishes, pushes, updates Homebrew, and installs. Do not
  execute it just to retry notarization. Keep those phases explicit and separate.

The export mapping has credential-free regression coverage in
`Scripts/Testing/test_distribution_export_options.py`. Run it with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s Scripts/Testing -p test_distribution_export_options.py -v
```

## About version bug and current artifact boundary

The installed app reported `0.1.0` because `AboutView` hard-coded
`Text("Version 0.1.0")`. Its actual installed bundle was **1.1.1 (3)**; the
submitted candidate was **1.2.0 (4)**. Do not confuse the UI label, installed
bundle version, source configuration, and submitted binary.

`AboutView` now reads `CFBundleShortVersionString` and `CFBundleVersion` from
`Bundle.main.infoDictionary`, displaying e.g. **Version 1.2.0 (4)**. It handles
string/integer build numbers and missing metadata without inventing a version;
an unbundled executable with neither key displays **Development build**.
`Tests/DiskStewardAppTests/AboutVersionTests.swift` covers these cases.

This source fix does **not** modify the installed app or the previously uploaded
archive. A fresh build and notarization are required before distributing the
corrected About view. Do not patch the plist or executable inside a signed app.
No new archive, installation, publication, or commit is implied by this fix.

### Verification of this source fix

The isolated candidate verifier passed on 2026-09-18 at 19:46 JST:

- All six stages passed: harness, toolchain, manifest, entitlements, build, tests.
- 22 Python harness tests passed, including the export-profile regressions.
- 560 Swift tests executed, 5 skipped, 0 failures; all 8 About-version tests passed.
- The live-fixture sentinel preservation check passed.
- Candidate input SHA-256:
  `6cd69c99775ed428ff9dddb333144f52e09de7523d1725039c53a743c847bc81`.
- Local report: `/private/tmp/ds-about-version-check.DApevv/evidence/candidate.json`.

This is isolated source/build evidence, not an installed-app UI observation,
packaged-release verification, or notarization of the updated code. Re-run
verification after further changes; temporary reports may not persist.

## References

- [Apple: accessing app group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)
- [Apple: customizing notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- `xcodebuild -help`: `provisioningProfiles` maps bundle IDs to profile names or UUIDs for manual exports.

## 1.2.0 release record (2026-09-18)

- Released **1.2.0 (5)**, not the earlier build 4 upload: build 5 contains the
  About-version fix. Build 4's notarization was accepted but it was never
  published.
- Isolated verification: `/private/tmp/disk-steward-check.P6cOGB/evidence`,
  input `582f827bd197…`, all fifteen stages passed, 555 tests, 0 failures.
- Upload through the Xcode route above at 19:51 JST; `xcodebuild
  -exportNotarizedApp` succeeded on its second attempt, about a minute later.
  No `notarytool` profile was needed.
- `verify-release` passed on the notarized app and on the app unpacked from
  `Disk-Steward-1.2.0.zip` (SHA-256 `f913ee840ff1b3b91519ba3abdb748a851e89321597fb95f9e5c66b365a3bb2a`).
- The cask in `Packaging/Homebrew/Casks/disk-steward.rb` and
  `KMerdan/homebrew-disk-steward` points at the v1.2.0 GitHub release asset.
- For the next release, bump `CFBundleVersion` and follow the repeatable
  workflow; poll `xcodebuild -exportNotarizedApp` instead of resubmitting.

## 1.2.1 release record (2026-09-18)

Two upgrade regressions reported from the installed 1.2.0 app:

- **Agent Access "existing endpoint is not owned by this instance"**: 1.1.x
  never removed `disk-steward.sock` on quit and never wrote the lease record,
  so 1.2.0 refused the leftover forever. `LegacyEndpointInspector` (Core IPC)
  now treats an unowned socket as stale only when the process table shows no
  process holds an AF_UNIX socket bound to that path and no other
  `Disk Steward.app` process runs. It never connects to the socket; an
  unreadable table fails closed.
- **"Evidence-database budget exceeded" circuit breaker**: the in-sample
  budget checks in `PersistentMonitoringProbe` judged the database on raw file
  size (free pages plus a transiently growing WAL). A store near its cap
  (the live one was 503 MiB against 512 MiB, 482 MiB live) tripped mid-sample.
  All in-sample checks now use store accounting, as the pre-sample check did.

Evidence: focused suites 74 tests green; mutation reds revert each fix and fail
exactly the new test; full verifier `/private/tmp/disk-steward-check.byToyo`
(input `ab220436864e…`) 559 tests, 0 failures. 1.2.1 (6) notarized on the
second poll; zip SHA-256 `494348588a2b6207898f53aae3a015ee607db601130275557080cc6a1d0d6812`.

## 1.2.2 release record (2026-09-20)

- After separate user authorization, released **1.2.2 (7)** from
  `hotfix/dashboard-1.2.2`, not unfinished schema-15 `main`. Tag `v1.2.2`
  points to `303fdfbad69d99ca4f87114cb22bd3535f840fcd`; the archive is the
  previously tested schema-14 hotfix (575 tests, 5 intentional skips, zero
  failures). Release metadata changes do not change its compiled source.
- **The notarization problem is solved.** Reused the documented Xcode account
  route and the existing manual export template with its provisioning-profile
  mapping. No new certificate, account password, or named `notarytool` profile
  was needed. Uploaded once using `xcodebuild -exportArchive`, then exported
  the accepted/stapled app with `xcodebuild -exportNotarizedApp` on the first
  status check. Do not confuse this established working path with unrelated
  CI compiler or build-worker supervision follow-ups.
- `Scripts/Distribution/verify-release` passed for both the exported app and
  the app extracted from the final ZIP: universal architectures, Developer ID
  and helper signatures, production entitlements, timestamp, hardened runtime,
  valid staple, Gatekeeper acceptance and isolated startup. Upload, export and
  verification commands ran under the bounded supervisor with verified cleanup.
- Downloaded the uploaded GitHub draft asset and confirmed its SHA-256 before
  publishing it as the latest release. Public release:
  https://github.com/KMerdan/disk_steward/releases/tag/v1.2.2
- Exact asset: `Disk-Steward-1.2.2.zip`, SHA-256
  `f7cf38fe52a81f6f96fee84b297d24de2426ca80a62c5c4b65960fc091565a26`.
- The project cask and `KMerdan/homebrew-disk-steward` pin that exact asset.
  Homebrew style and strict online audit passed, including the public download.
  Tap publication commit: `79cb95c`. No uninstall/zap or user evidence reset
  was performed. This release step did not replace the already-running local
  app again; use the published Homebrew upgrade to install the stapled artifact.
- Raw upload/account/build records stay local under ignored
  `build/releases/1.2.2/`. Publish only the app ZIP and sanitized notes, never
  the raw diagnostic logs. Public notes: `docs/reliability/releases/1.2.2.md`.
- Older-Xcode development CI errors and the earlier archive-worker warning
  remain separate follow-up work. Do not claim main/CI or object-model increment
  gates passed merely because this focused binary release was notarized.

## Handoff

Development paused on 2026-09-20. State, decisions, open observations and the
first action for the next session are in
`docs/reliability/handoffs/HANDOFF-DISK-STEWARD-20260920.md` (machine-readable
copy alongside it). The plan is completed with no owned task, so this is a
hand-written record in the `pyramid-handoff-draft-v1` shape, not a runtime
handoff; `pyramid pause` cannot issue one without a claim.

## Current intent: PLAN-DISK-STEWARD-006

Started 2026-09-20 after archiving the completed reliability plan
(`PLAN-DISK-STEWARD-005-R17-G176-20260920T030413Z`). The brownfield baseline
carried over at revision 4; assurance starts empty, so impact records and the
rollback and monitoring controls are open blockers until the first task
records them.

Intent: represent build output, shared developer caches and repositories as
single evidence objects instead of per-file rows. Three rungs: scans that
finish on a real-sized scope, reclaimable space made visible and explained,
then shared caches under the same contract behind an explicit opt-in.

Progress at revision 3 (graph 42): RESEARCH-601, CONTRACT-601, TASK-611,
TASK-612, TASK-613, TASK-615, **TASK-616** (test-process supervision) and
**TASK-617** (live dashboard/alert consistency) are verified. No increment
gate has passed. TASK-614 (capacity guard) and TASK-621 (object sizing) are
the next ready nodes; no worker is left claimed. Wider object-model,
real-scope and rollback assurance remains unfinished. Node verification
does not authorize a release of the schema-15 main branch.

Current continuation instructions and evidence limits are in
`docs/reliability/handoffs/HANDOFF-DISK-STEWARD-20260920-R3.md`. The earlier
OBJECTS handoff is historical: its assertion that no verifier was active was
disproved by orphaned XCTest PID 60334, which survived a recorded 300-second
timeout, reached an 86.9G sampled footprint, and was stopped with user approval.
Current source fixes that old snapshot's ancestor loop. TASK-616 established
birth-identity-bound descendant supervision with independently bounded
bootstrap fixtures and a 2 GiB aggregate physical-footprint default limit.
Use only the supervised snapshot verifier; legacy scale/soak/rollback entry
points remain fail-closed. Never run `swift test` in the worktree or open
the live evidence database from tests. See `Scripts/Testing/SUPERVISION.md`
for containment boundaries, including launchd/XPC delegation limitations.

The two R3 material findings are resolved in the audited scope. TASK-617's
final isolated source candidate passed 604 tests (6 intentional skips), with
zero failures and verified process cleanup. Its hosted-view tests prove live
rendered updates, single-flight refresh, signed per-volume deltas, explicit
baseline/interval, distinct file/capacity freshness, and one bounded latest
growth alert. A historical alert and the newest sample can show different
numbers. See `docs/reliability/evidence/TASK-617/README.md` and `after.json`.

On September 20 the user separately authorized a local replacement build,
removal of the old installed copy, and commit/push. The hotfix was built on
`hotfix/dashboard-1.2.2` from `v1.2.1`, backporting TASK-617 and the supervised
test harness without the unfinished schema-15/object changes. Developer ID
signed universal **1.2.2 (7)** is installed and running from Applications;
1.2.1 is recoverable from Trash. Evidence/settings were preserved, the live
store remains schema 14, and MCP storage-summary succeeds. The hotfix passed
575 tests (5 intentional skips), signed-app smoke and helper protocol checks.
The archive runner detected and cleaned up a retained Xcode ibtoold worker;
the original failed supervisor receipt and independent artifact acceptance
are retained locally in ignored `build/local-1.2.2/evidence/`; a sanitized
summary is in `docs/reliability/evidence/HOTFIX-1.2.2/README.md`. This is not a clean
automated release gate or completion of object-scanner work. Native UI
inspection timed out; hosted-view regression tests provide the rendering proof.
The archive is retained in ignored `build/local-1.2.2/`. No GitHub release,
Homebrew update or Apple notarization submission was performed.

The first pushed-main CI run (35508020675) failed with the older macOS 15.5
SDK's non-Sendable UNNotificationSettings crossing the main actor. A separate
main-only compatibility fix extracts UNAuthorizationStatus within the native
callback; it does not alter permissions or suppress Swift concurrency checks.
Ten isolated notification tests passed under the supervisor, with unchanged
source inputs and verified cleanup. This change is not in the installed
hotfix's recorded source digest; do not conflate main with the hotfix branch.

CI rerun 35508618140 still fails on the older toolchain: the object-store
collapse callback is non-Sendable across actors, and the native async
notification-authorization request sends a main-actor-owned center into a
nonisolated call. The first settings-result diagnostic is gone, but CI is not
green. Do not describe the compatibility follow-up or automated release as
complete. These are recorded follow-up blockers, separate from the tested,
installed Xcode-26 local hotfix. Both CI reports remain in local build evidence.

Candidate plans, reviews and R3 assurance are in
`docs/reliability/planning/plan-006-{candidate,review}.json`,
`plan-006-r2-{candidate,review}.json`, and
`plan-006-r3-{candidate,review,assurance}.json`. Incident evidence and the user
screenshot are retained in `docs/reliability/evidence/REPLAN-006-R3/`.

Measured evidence behind it, all from 2026-09-20 and recorded in the plan:
888,469 of 1,214,531 files in the watched roots sit inside 2,618 build-output
directories holding 65.2 GB; git reported 30 artifact-named directories as
tracked source, so name matching alone is unsafe; about 90 GB more sits in
shared caches outside the watched roots; and the installed app's scan had
processed fourteen times its scope without publishing.
