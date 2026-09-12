# Signing, notarization, and release runbook

Development preflight is `Scripts/Distribution/verify --development`. It validates the package, property lists, required app-group/Endpoint Security entitlement declarations, and hardened-runtime release configuration without claiming that a build is signed or entitled.

A release remains blocked until the placeholder team ID is replaced, Apple grants the Endpoint Security client entitlement, matching app and extension provisioning profiles exist, the extension is embedded in the signed app, and a valid Developer ID identity is installed. Run `Scripts/Distribution/verify --release`, archive with the release configuration, verify entitlements with `codesign -d --entitlements :-`, submit the exact archive to Apple notarization, staple the ticket, install into `/Applications`, approve the extension and Full Disk Access on a clean test Mac, then verify activation, event receipt, fallback, upgrade, restart-required, deactivation, and uninstall behavior.

No telemetry upload is part of the product or release process.
