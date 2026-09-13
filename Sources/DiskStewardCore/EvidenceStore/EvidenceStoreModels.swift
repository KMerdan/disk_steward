import Foundation

public struct EvidenceStoreEvent: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case create
        case writeSummary = "write-summary"
        case rename
        case delete
        case truncate
        case snapshotDelta = "snapshot-delta"
        case baseline
        case modify
        case replace
        case scopeEnter = "scope-enter"
        case scopeExit = "scope-exit"
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

public struct EvidenceScopeVersion: Codable, Equatable, Sendable {
    public let scopeVersionID: String
    public let effectiveAt: Date
    public let rootPaths: [String]
    public let excludedPaths: [String]
    public let maximumEntries: Int
    public let maximumDepth: Int

    public init(
        scopeVersionID: String,
        effectiveAt: Date,
        rootPaths: [String],
        excludedPaths: [String],
        maximumEntries: Int,
        maximumDepth: Int
    ) {
        self.scopeVersionID = scopeVersionID
        self.effectiveAt = effectiveAt
        self.rootPaths = rootPaths.sorted()
        self.excludedPaths = excludedPaths.sorted()
        self.maximumEntries = maximumEntries
        self.maximumDepth = maximumDepth
    }
}

public enum EvidenceObservationTrigger: String, Codable, Equatable, Sendable {
    case startup
    case scheduled
    case fsevent
    case manual
    case recovery
}

public enum CurrentFilePresence: String, Codable, Equatable, Sendable {
    case present
    case unknown
    case stale
    case outOfScope = "out-of-scope"
}

public struct CurrentFileStateRecord: Codable, Equatable, Sendable {
    public let objectID: String
    public let identityMethod: FileIdentityMethod
    public let path: String
    public let rootPath: String
    public let scopeVersionID: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let modifiedAt: Date?
    public let presence: CurrentFilePresence
    public let stateAsOfObservationID: String
    public let observedAt: Date
    public let actionable: Bool
}

public struct EvidenceCoverageGap: Codable, Equatable, Sendable {
    public let gapID: String
    public let observationID: String
    public let rootPath: String
    public let reason: String
    public let startedAt: Date
    public let endedAt: Date?
}

public struct ObservationCommitResult: Equatable, Sendable {
    public let observationID: String
    public let events: [EvidenceStoreEvent]
    public let currentFiles: [CurrentFileStateRecord]
    public let coverageGaps: [EvidenceCoverageGap]
}

public struct PersistedFSEventHint: Codable, Equatable, Sendable {
    public let hintID: String
    public let observationID: String
    public let hint: TargetedChangeHint
    public let limitations: [String]
}

public struct PersistedEndpointObservation: Codable, Equatable, Sendable {
    public let observationID: String?
    public let evidenceEventID: String?
    public let event: NormalizedPrivilegedEvent
}

public struct EvidenceSummary: Equatable, Sendable {
    public let bucketStart: Date
    public let path: String
    public let operation: EvidenceStoreEvent.Operation
    public let eventCount: Int
    public let logicalDelta: Int64
    public let allocatedDelta: Int64
}

public struct EvidenceStoreRetentionPolicy: Codable, Equatable, Sendable {
    public let rawEventDays: Int
    public let anomalyDetailDays: Int
    public let hourlySummaryDays: Int
    public let dailySummaryDays: Int
    public let maxDatabaseBytes: Int64
    public let writeCoalesceSeconds: Int
    public let preserveUnreviewedAnomalies: Bool

    public init(
        rawEventDays: Int = 7,
        anomalyDetailDays: Int = 30,
        hourlySummaryDays: Int = 30,
        dailySummaryDays: Int = 365,
        maxDatabaseBytes: Int64 = 512 * 1_024 * 1_024,
        writeCoalesceSeconds: Int = 15,
        preserveUnreviewedAnomalies: Bool = true
    ) throws {
        guard (1 ... 30).contains(rawEventDays),
              (rawEventDays ... 30).contains(anomalyDetailDays),
              (7 ... 180).contains(hourlySummaryDays),
              (30 ... 730).contains(dailySummaryDays),
              (10 * 1_024 * 1_024 ... 10 * 1_024 * 1_024 * 1_024).contains(maxDatabaseBytes),
              (1 ... 300).contains(writeCoalesceSeconds)
        else { throw EvidenceStoreError.invalidRetentionPolicy }

        self.rawEventDays = rawEventDays
        self.anomalyDetailDays = anomalyDetailDays
        self.hourlySummaryDays = hourlySummaryDays
        self.dailySummaryDays = dailySummaryDays
        self.maxDatabaseBytes = maxDatabaseBytes
        self.writeCoalesceSeconds = writeCoalesceSeconds
        self.preserveUnreviewedAnomalies = preserveUnreviewedAnomalies
    }

    enum CodingKeys: String, CodingKey {
        case rawEventDays = "raw_event_days"
        case anomalyDetailDays = "anomaly_detail_days"
        case hourlySummaryDays = "hourly_summary_days"
        case dailySummaryDays = "daily_summary_days"
        case maxDatabaseBytes = "max_database_bytes"
        case writeCoalesceSeconds = "write_coalesce_seconds"
        case preserveUnreviewedAnomalies = "preserve_unreviewed_anomalies"
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
    public let observationCount: Int
    public let currentFileCount: Int
    public let coverageGapCount: Int
    public let retentionRunCount: Int
    public let exportRecordCount: Int
}

public struct RetentionReport: Equatable, Sendable {
    public let runID: String
    public let trigger: RetentionTrigger
    public let startedAt: Date
    public let completedAt: Date
    public let storageBytesBefore: Int64
    public let aggregatedRawEvents: Int
    public let aggregatedHourlySummaries: Int
    public let deletedDailySummaries: Int
    public let deletedSnapshots: Int
    public let deletedHistoricalRows: Int
    public let forcedEvictions: Int
    public let storageBytes: Int64
    public let limitations: [String]
}

public enum EvidenceStoreError: Error, Equatable, LocalizedError {
    case sqlite(code: Int32, message: String)
    case invalidEvent(String)
    case invalidObservation(String)
    case invalidRetentionPolicy
    case backupDestinationExists
    case closed

    public var errorDescription: String? {
        switch self {
        case let .sqlite(code, message): return "SQLite error \(code): \(message)"
        case let .invalidEvent(reason): return "Invalid evidence event: \(reason)"
        case let .invalidObservation(reason): return "Invalid evidence observation: \(reason)"
        case .invalidRetentionPolicy: return "Retention policy violates the bounded version 1 contract."
        case .backupDestinationExists: return "Backup destination already exists."
        case .closed: return "The evidence store is closed."
        }
    }
}
