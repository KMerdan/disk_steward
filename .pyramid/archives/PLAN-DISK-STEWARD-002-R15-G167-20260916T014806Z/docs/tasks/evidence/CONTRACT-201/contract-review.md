# CONTRACT-201 review

- Canonical Apple team and product identifiers are specified in
  `docs/architecture/distribution.md` and the signing configurations.
- The standard app is independent of the optional restricted Endpoint Security
  target; the standard entitlement file no longer requests system-extension
  installation.
- Development, unsigned CI, Developer ID release, notarization, and human
  ownership boundaries are explicit.
- MCP location, read-only scope, default-off Agent Access behavior, and socket
  lifecycle are explicit.
- Evidence tiers, pressure visibility, manual-export ownership, and temporary
  export destruction are explicit.
- `docs/design/status-board.md` defines hierarchy, state matrix, native visual
  behavior, accessibility, and honest evidence wording.

No Apple Developer portal identifier, certificate, profile, or credential was
created or modified by this contract task.
