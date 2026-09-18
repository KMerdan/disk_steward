import Foundation

/// Wire names of the storage summary the app publishes over IPC and the
/// helper's self-check reads back. Both sides use these constants, so the
/// evidence-freshness field cannot be renamed on one side only.
public enum StorageSummaryContract {
    public static let schema = "storage-summary-v1"
    /// When the live volume figures were sampled: the moment of the query,
    /// which says nothing about how fresh the evidence is.
    public static let liveVolumeObservedAt = "live_volume_observed_at"
    /// The newest persisted observation, or null when nothing has been
    /// observed yet. This is the freshness a verification reports.
    public static let persistedStateAsOf = "persisted_state_as_of"
}
