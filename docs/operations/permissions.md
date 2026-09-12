# Permission behavior

Endpoint Security and Full Disk Access are optional fidelity upgrades. If either is not requested, pending, denied, unavailable, or later revoked, the menu bar app continues snapshots, watched-root metadata monitoring, exports, and read-only MCP queries. The UI says “Standard monitoring is active,” identifies the missing permission, and never implies exact attribution.

Permission prompts must follow an explicit user action. Retry is bounded; a denial is not answered with a prompt loop. The app never attempts to bypass TCC, system-extension approval, code signing, or the Endpoint Security entitlement.
