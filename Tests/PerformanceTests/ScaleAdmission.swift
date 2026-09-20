import Foundation

/// A caller-controlled opt-in string is not proof of external containment.
/// Keep legacy scale/soak entry points closed until fixture construction,
/// storage quotas and the live supervisor handshake have been migrated.
func requireScaleSupervisor() throws {
    throw NSError(domain: "DiskSteward.VerificationSafety", code: 616, userInfo: [
        NSLocalizedDescriptionKey: "Scale/soak admission is closed pending a verified supervisor and bounded fixture setup. See Scripts/Testing/SUPERVISION.md."
    ])
}
