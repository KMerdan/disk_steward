# Disk Steward development and release context

Last updated: 2026-09-18. This is a continuation guide, not proof that the
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

Progress at revision 2 (graph 32): RESEARCH-601, CONTRACT-601, TASK-611,
TASK-612, TASK-613 and TASK-615 are verified. Replan R2 added TASK-615 because
nothing owned wiring the object model into the running app. **TASK-614**, the
capacity guard, is the last task before GATE-619 closes rung 1.

State, decisions, the hang that was found and fixed, and the first action for
the next session are in
`docs/reliability/handoffs/HANDOFF-DISK-STEWARD-20260920-OBJECTS.md`. The
isolated test harness that produced every suite and mutation red lives in
`docs/reliability/handoffs/harness/`; never run `swift test` in the worktree.

The candidate plans and reviews are in
`docs/reliability/planning/plan-006-{candidate,review}.json` and
`plan-006-r2-{candidate,review}.json`.

Measured evidence behind it, all from 2026-09-20 and recorded in the plan:
888,469 of 1,214,531 files in the watched roots sit inside 2,618 build-output
directories holding 65.2 GB; git reported 30 artifact-named directories as
tracked source, so name matching alone is unsafe; about 90 GB more sits in
shared caches outside the watched roots; and the installed app's scan had
processed fourteen times its scope without publishing.
