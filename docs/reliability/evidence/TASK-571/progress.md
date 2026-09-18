# TASK-571 progress — isolated CI foundation

Historical checkpoint. See [packaged-verification.md](packaged-verification.md)
and `reviewed-run/candidate.json` for the later reviewed package/upgrade verifier.
The build directories named below have since been removed as documented there.

17 September 2026. Working, not implemented or verified. Current plan R8/G63
before this progress checkpoint. No signing, installation, Git push or release.

## Implemented in this checkpoint

- Credential-free hosted PR/main/manual CI with read-only repository permission,
  pinned checkout/upload actions, no persisted checkout credential and actionlint.
- A bounded source snapshot and private-cache runner; no inherited test opt-ins or
  credentials. Mistaken normal app startup is fail-closed and the default helper
  socket cannot point at the installed app.
- Exact Git revision + dirty flag + source input manifest/hash + debug binary
  hashes + stage/log identities + compatibility declarations/rollback prerequisites.
- Per-stage deadlines, bounded merged output, owned-process cleanup, no existing
  output replacement, no linked input paths, and explicit live-sentinel test proof.
- Log/report-only upload; caches, fixture directories and source/build copies are
  excluded from uploaded artifacts. Retention is 14 days.

## Accepted evidence and exact identity

Final source input digest: `a9878099be600f2906343f158d1c3844a437ea9a08cedb826209e0ca0fdc6e45`.
Git HEAD: `cf313e4527a3bd30dae217d2c1ff68d7a7a87b60`, **dirty worktree**. The commit by itself is
not the tested candidate. `final-run/candidate.json` enumerates the exact inputs.
The current authored workflow/runner/test sources are preserved in `final-source/`.

The final full runner exited 0 (session 49839, terminal). All six stages exited 0:
harness, toolchain, manifest, entitlements, build and tests. The harness has **9
passing tests**. Swift ran **434 tests, 4 opt-in skips, zero failures**, 30.657
seconds of test execution. The complete test command including build/discovery
lasted 46.351 seconds. The required live endpoint / sentinel state scenario
passed, including evidence/settings/safety/export/client fixtures and socket/lease
identity. This is fixture evidence, not an inspection of real user state.

Debug binary identities (not distributable artifacts):

- App: `28d17c91556dfcbea4e594dfc84ccba7be9c74898049661efbdee12165ef14ba` (8618720 B).
- Helper: `c6bedf98a6847789a8f0f0cd8a740e20aef15c786823c6075083f2cc7871f21c` (5459104 B).

Actionlint v1.7.12 passed on the final workflow. Its first invocation downloaded
pinned public modules and exited zero. Two later version-addressed invocations
failed because sandbox network/DNS and then offline deprecation lookup were
unavailable; those failures remain in `workflow-lint.log` and
`workflow-final-lint.log`. Running the **already downloaded same version's source**
in its module directory with GOPROXY=off then exited zero; empty
`workflow-lint-validated.log` is paired with this recorded exit, not treated as
self-proving success. Shellcheck/pyflakes integrations were disabled; actionlint's
own YAML/expression validation ran. No GitHub-hosted run has been dispatched.

The earlier `initial-candidate.json` corresponds to the first full pass before
log-only upload and the input traversal visit limit. Do not use that earlier hash
as the final candidate. The final full rerun above includes both corrections.

## Unfinished TASK-571 acceptance

1. Provide packaged-candidate construction/identity and isolated launch/MCP proof.
   Do not run an arbitrary old app on a personal Mac based only on its smoke flag.
   Build from an exact disposable source snapshot, record any generated project
   inputs, and keep package identity separate from these debug binary hashes.
2. Add safe synthetic upgrade/rollback orchestration and prerequisite reporting.
   Do not open real evidence, claim that a tiny forward-upgrade test proves
   downgrade compatibility, or fabricate a passing rollback result.
3. Review/reconcile the final candidate, source/asset declarations and assurance
   inspection, then submit an implemented result. No audit pass or release-readiness
   claim is justified at this checkpoint.

The existing packaging specification already has a CI configuration with signing
disabled. XcodeGen is locally available at /opt/homebrew/bin/xcodegen. The committed
Xcode project may not include newly added source files; generate only in a separate
disposable copy and retain both original and generated input identities. This is a
continuation entry point, not permission to regenerate the canonical project.

## Resource and history handoff

No tool process remains live. Final disposable build: `/private/tmp/ds-ci-2wu59ky_`.
Prior build: `/private/tmp/ds-ci-gwynn_3s`. Logs/tool cache root:
`/private/tmp/disk-steward-571-validation.pTkIn0`. They are generated test data;
retain the final build for the next packaged-candidate step and clean obsolete
exact leaves after confirming completion and archiving required evidence.

RESEARCH-530 is paused with canonical handoff
`HANDOFF-RESEARCH-530-20260917T103345606513Z-7C5921F6`. Its full-schema proof remains
unsatisfied and TASK-531/TASK-532 stay locked. This CI work does not approve the
prototype storage design. At G63, history doctor reported 11 records, 6 chronicles,
no pending transaction and no errors; no exact clean Git binding exists yet.
