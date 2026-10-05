import Foundation

/// Wire names of the storage summary the app publishes over IPC and the
/// helper's self-check reads back. Both sides use these constants, so the
/// evidence-freshness field cannot be renamed on one side only.
public enum StorageSummaryContract {
    public static let schema = "storage-summary-v1"
    /// When the live volume figures were sampled: the moment of the query,
    /// which says nothing about how fresh the evidence is.
    public static let liveVolumeObservedAt = "live_volume_observed_at"
    /// The newest persisted file-detail observation, or null when nothing has
    /// been observed yet. File detail is retired, so this stays null on a
    /// current install.
    public static let persistedStateAsOf = "persisted_state_as_of"
    /// The capacity history object: `status` is `available`, `empty` or
    /// `unavailable`, and only an available history has samples.
    public static let capacityHistory = "capacity_history"
    public static let capacityHistoryStatus = "status"
    public static let capacityHistoryAvailable = "available"
    /// The newest capacity sample Monitoring persisted. A verification takes
    /// freshness from the newer of this and `persistedStateAsOf`.
    public static let newestSampleAt = "newest_sample_at"
}
