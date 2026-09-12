# Safe uninstall

Normal uninstall removes the app, deactivates its optional system extension, and removes only Disk Steward-owned Codex or Claude integration entries. The integration script creates a recoverable configuration backup and leaves unrelated settings untouched.

Evidence is preserved by default because it belongs to the user. Deleting evidence is a separate, explicit “export then delete” decision that must name the evidence location and confirm after a successful export. Removing the app or an integration is never implicit permission to delete evidence exports or the evidence database.
