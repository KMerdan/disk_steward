import Foundation

public struct EvidenceStoreEvent: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case create
        case writeSummary = "write-summary"
        case rename
        case delete
        case truncate
        case snapshotDelta = "snapshot-delta"
    }

    public enum Confidence: String, Codable, Sendable {
        case exact
        case toolLinked = "tool-linked"
        case inferred
        case unknown
    }

    public let eventID: String
    public let observedAt: Date
    public let operation: Operation
    public let path: String
    public let logicalDelta: Int64
    public let allocatedDelta: Int64
    public let consumerCategory: String
    public let confidence: Confidence
    public let isAnomaly: Bool
    public let isReviewed: Bool

    public init(
        eventID: String,
        observedAt: Date,
        operation: Operation,
        path: String,
        logicalDelta: Int64,
        allocatedDelta: Int64,
        consumerCategory: String,
        confidence: Confidence,
        isAnomaly: Bool = false,
        isReviewed: Bool = false
    ) {
        self.eventID = eventID
        self.observedAt = observedAt
        self.operation = operation
        self.path = path
        self.logicalDelta = logicalDelta
        self.allocatedDelta = allocatedDelta
        self.consumerCategory = consumerCategory
        self.confidence = confidence
        self.isAnomaly = isAnomaly
        self.isReviewed = isReviewed
    }
}

public struct EvidenceSummary: Equatable, Sendable {
    public let bucketStart: Date
    public let path: String
    public let operation: EvidenceStoreEvent.Operation
    public let eventCount: Int
    public let logicalDelta: Int64
    public let allocatedDelta: Int64
}

public struct EvidenceStoreRetentionPolicy: Equatable, Sendable {
    public let rawEventDays: Int
    public let hourlySummaryDays: Int
    public let dailySummaryDays: Int
    public let maxDatabaseBytes: Int64
    public let writeCoalesceSeconds: Int
    public let preserveUnreviewedAnomalies: Bool

    public init(
        rawEventDays: Int = 7,
        hourlySummaryDays: Int = 30,
        dailySummaryDays: Int = 365,
        maxDatabaseBytes: Int64 = 512 * 1_024 * 1_024,
        writeCoalesceSeconds: Int = 15,
        preserveUnreviewedAnomalies: Bool = true
    ) throws {
        guard (1 ... 30).contains(rawEventDays),
              (7 ... 180).contains(hourlySummaryDays),
              (30 ... 730).contains(dailySummaryDays),
              (10 * 1_024 * 1_024 ... 10 * 1_024 * 1_024 * 1_024).contains(maxDatabaseBytes),
              (1 ... 300).contains(writeCoalesceSeconds)
        else { throw EvidenceStoreError.invalidRetentionPolicy }

        self.rawEventDays = rawEventDays
        self.hourlySummaryDays = hourlySummaryDays
        self.dailySummaryDays = dailySummaryDays
        self.maxDatabaseBytes = maxDatabaseBytes
        self.writeCoalesceSeconds = writeCoalesceSeconds
        self.preserveUnreviewedAnomalies = preserveUnreviewedAnomalies
    }
}

public struct EvidenceStoreDiagnostics: Equatable, Sendable {
    public let schemaVersion: Int
    public let journalMode: String
    public let integrity: String
    public let eventCount: Int
    public let snapshotCount: Int
    public let hourlySummaryCount: Int
    public let dailySummaryCount: Int
    public let storageBytes: Int64
}

public struct RetentionReport: Equatable, Sendable {
    public let aggregatedRawEvents: Int
    public let aggregatedHourlySummaries: Int
    public let deletedDailySummaries: Int
    public let forcedEvictions: Int
    public let storageBytes: Int64
}

public enum EvidenceStoreError: Error, Equatable, LocalizedError {
    case sqlite(code: Int32, message: String)
    case invalidEvent(String)
    case invalidRetentionPolicy
    case backupDestinationExists
    case closed

    public var errorDescription: String? {
        switch self {
        case let .sqlite(code, message): return "SQLite error \(code): \(message)"
        case let .invalidEvent(reason): return "Invalid evidence event: \(reason)"
        case .invalidRetentionPolicy: return "Retention policy violates the bounded version 1 contract."
        case .backupDestinationExists: return "Backup destination already exists."
        case .closed: return "The evidence store is closed."
        }
    }
}
