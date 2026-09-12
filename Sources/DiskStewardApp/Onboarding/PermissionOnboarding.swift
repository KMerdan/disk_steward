import DiskStewardCore
import Foundation

enum PermissionGrantState: String, Equatable, Sendable {
    case notRequested = "not-requested"
    case pendingUserApproval = "pending-user-approval"
    case granted
    case denied
    case unavailable
}

struct PermissionOnboardingState: Equatable, Sendable {
    let endpointSecurity: PermissionGrantState
    let fullDiskAccess: PermissionGrantState
    let metadataFallbackActive: Bool
    let headline: String
    let detail: String
    let exactProvenanceAvailable: Bool

    init(endpointSecurity: PermissionGrantState, fullDiskAccess: PermissionGrantState) {
        self.endpointSecurity = endpointSecurity
        self.fullDiskAccess = fullDiskAccess
        exactProvenanceAvailable = endpointSecurity == .granted && fullDiskAccess == .granted
        metadataFallbackActive = true
        if exactProvenanceAvailable {
            headline = "Detailed provenance is available"
            detail = "The optional observer can support exact process-to-file evidence. Standard metadata monitoring remains active."
        } else {
            headline = "Standard monitoring is active"
            detail = "Optional permissions affect attribution detail only. Snapshots, watched folders, exports, and agent queries continue without them."
        }
    }
}
