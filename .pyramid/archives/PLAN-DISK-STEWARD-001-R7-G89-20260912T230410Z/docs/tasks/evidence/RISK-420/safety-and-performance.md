# RISK-420 safety and performance evidence

- Privacy property test: 500 unique secret values across paths, commands, and executables; zero values remained in encoded output.
- Exclusion/path-detail tests: excluded trees are omitted; basename and hashed modes are deterministic.
- Permission matrix: denial, unavailable, pending, and not-requested states keep standard monitoring visible and active.
- Event storm: 100,000 unique normalized events enter a 512-event/256 KiB bounded queue; every non-retained event is counted and the evidence gap becomes visible.
- Resource history: 10,000 samples retain only the configured final 60.
- Uninstall: preservation is the default; evidence deletion requires an explicit export-then-delete choice.
- Development distribution preflight validates entitlements, app group, package structure, and release hardened-runtime declaration. Live signing, Apple entitlement approval, activation, and notarization remain external release gates.
