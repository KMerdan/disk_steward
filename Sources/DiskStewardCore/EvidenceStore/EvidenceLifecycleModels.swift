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
}
