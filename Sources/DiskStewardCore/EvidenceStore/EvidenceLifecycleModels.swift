import Foundation

public enum RetentionTrigger: String, Codable, Equatable, Sendable {
    case startup
    case scheduled
    case pressure
    case manual
}

public enum RetentionRunResult: String, Codable, Equatable, Sendable {
    case started
    case completed
    case failed
}

public struct RetentionRunRecord: Codable, Equatable, Sendable {
    public let runID: String
    public let trigger: RetentionTrigger
    public let startedAt: Date
    public let completedAt: Date?
    public let storageBytesBefore: Int64
    public let storageBytesAfter: Int64?
    public let aggregatedRawEvents: Int
    public let aggregatedHourlySummaries: Int
    public let deletedDailySummaries: Int
    public let deletedSnapshots: Int
    public let deletedHistoricalRows: Int
    public let forcedEvictions: Int
    public let result: RetentionRunResult
    public let limitations: [String]
}

public struct RetentionCoverageGap: Codable, Equatable, Sendable {
    public let gapID: String
    public let retentionRunID: String
    public let reason: String
    public let affectedPrecision: String
    public let startedAt: Date
    public let rowsRemoved: Int
}

public enum EvidenceExportKind: String, Codable, Equatable, Sendable {
    case manual
    case temporary
}

public enum EvidenceExportStatus: String, Codable, Equatable, Sendable {
    case creating
    case available
    case missing
    case served
    case destroyed
    case failed
}

public struct EvidenceExportRecord: Codable, Equatable, Sendable {
    public let exportID: String
    public let kind: EvidenceExportKind
    public let requestedFrom: Date
    public let requestedThrough: Date
    public let actualFrom: Date?
    public let actualThrough: Date?
    public let precision: String
    public let pathDetail: EvidencePathDetail
    public let path: String?
    public let bytes: Int64
    public let manifestSHA256: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let status: EvidenceExportStatus
    public let failure: String?
}

public struct EvidenceTierStatus: Codable, Equatable, Sendable {
    public let tier: String
    public let requestedFrom: Date
    public let actualOldest: Date?
    public let actualNewest: Date?
    public let count: Int
    public let precision: String
}

/// One accounting of everything that competes for the evidence store's cap:
/// live pages, reusable free pages, the write-ahead log and shared memory,
/// plus the headroom the next publication of staged rows will need. Admission,
/// retention pressure and the public lifecycle DTO all read this one model.
public struct EvidenceStorageAccounting: Codable, Equatable, Sendable {
    public enum Admission: String, Codable, Sendable {
        /// New work fits under the cap with the publication reserve intact.
        case available
        /// Committed bytes and reserve exceed the cap but evictable history exists.
        case retentionRequired = "retention-required"
        /// Authoritative current state alone leaves no room; nothing is evicted.
        case capacityLimited = "capacity-limited"
        /// An open reader keeps write-ahead-log frames from being checkpointed.
        case walPinned = "wal-pinned"
        /// The volume cannot hold the transient publication log.
        case diskSpaceLimited = "disk-space-limited"
    }

    public let capBytes: Int64
    public let fileBytes: Int64
    public let liveBytes: Int64
    public let reusableBytes: Int64
    public let walBytes: Int64
    public let sharedMemoryBytes: Int64
    public let stagedRowCount: Int64
    public let reservedPublicationBytes: Int64
    /// Headroom held for the next unit of work (one nominal 512-entry slice)
    /// while a scan generation is active; zero between generations.
    public let nextWorkReserveBytes: Int64
    public let publicationLogEstimateBytes: Int64
    public let availableDiskBytes: Int64?
    public let walPinnedByReader: Bool
    public let evictableHistory: Bool
    public let admission: Admission
    public let limitations: [String]

    public init(
        capBytes: Int64, fileBytes: Int64, liveBytes: Int64, reusableBytes: Int64, walBytes: Int64, sharedMemoryBytes: Int64,
        stagedRowCount: Int64, reservedPublicationBytes: Int64, nextWorkReserveBytes: Int64, publicationLogEstimateBytes: Int64,
        availableDiskBytes: Int64?, walPinnedByReader: Bool, evictableHistory: Bool, admission: Admission, limitations: [String]
    ) {
        self.capBytes = capBytes; self.fileBytes = fileBytes; self.liveBytes = liveBytes; self.reusableBytes = reusableBytes
        self.walBytes = walBytes; self.sharedMemoryBytes = sharedMemoryBytes; self.stagedRowCount = stagedRowCount
        self.reservedPublicationBytes = reservedPublicationBytes; self.nextWorkReserveBytes = nextWorkReserveBytes
        self.publicationLogEstimateBytes = publicationLogEstimateBytes
        self.availableDiskBytes = availableDiskBytes; self.walPinnedByReader = walPinnedByReader; self.evictableHistory = evictableHistory
        self.admission = admission; self.limitations = limitations
    }

    /// Bytes that count against the cap right now.
    public var committedBytes: Int64 { liveBytes + walBytes + sharedMemoryBytes }
    /// Cap headroom after the publication and next-work reserves; negative when over.
    public var headroomBytes: Int64 { capBytes - committedBytes - reservedPublicationBytes - nextWorkReserveBytes }
}

public struct EvidenceLifecycleStatus: Codable, Equatable, Sendable {
    public let observedAt: Date
    public let tiers: [EvidenceTierStatus]
    public let databaseBytes: Int64
    public let databaseCapBytes: Int64
    public let lastCompaction: RetentionRunRecord?
    public let totalForcedEvictions: Int
    public let currentStateCount: Int
    public let currentStateAllocatedBytes: Int64
    public let exportInventory: [EvidenceExportRecord]
    public let observationGaps: [EvidenceCoverageGap]
    public let retentionGaps: [RetentionCoverageGap]
    public var scanCoverage: EvidenceScanCoverageStatus? = nil
    /// Unified storage accounting; nil only for projections that omit it.
    public var storage: EvidenceStorageAccounting? = nil
}
