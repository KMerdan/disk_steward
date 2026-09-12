import Foundation

public enum EvidencePathDetail: String, Codable, Sendable {
    case full
    case basename
    case hashed
}

public struct EvidenceBundleExportOptions: Equatable, Sendable {
    public let from: Date
    public let through: Date
    public let pathDetail: EvidencePathDetail
    public let maximumEvents: Int

    public init(from: Date, through: Date, pathDetail: EvidencePathDetail = .full, maximumEvents: Int = 100_000) {
        self.from = from
        self.through = through
        self.pathDetail = pathDetail
        self.maximumEvents = min(100_000, max(1, maximumEvents))
    }
}

public struct EvidenceBundleExportResult: Sendable {
    public let bundleURL: URL
    public let manifest: EvidenceBundleManifest
}

public struct EvidenceBundleManifest: Codable, Equatable, Sendable {
    public struct Producer: Codable, Equatable, Sendable {
        public let name: String
        public let version: String
        public let evidenceSchemaVersion: Int

        enum CodingKeys: String, CodingKey {
            case name
            case version
            case evidenceSchemaVersion = "evidence_schema_version"
        }
    }

    public struct RequestedRange: Codable, Equatable, Sendable {
        public let from: String
        public let through: String
    }

    public struct FileEntry: Codable, Equatable, Sendable {
        public let path: String
        public let role: String
        public let sha256: String
        public let bytes: Int
    }

    public struct Privacy: Codable, Equatable, Sendable {
        public let containsFileContents: Bool
        public let containsEnvironment: Bool
        public let pathDetail: EvidencePathDetail

        enum CodingKeys: String, CodingKey {
            case containsFileContents = "contains_file_contents"
            case containsEnvironment = "contains_environment"
            case pathDetail = "path_detail"
        }
    }

    public let schema: String
    public let bundleID: String
    public let createdAt: String
    public let producer: Producer
    public let requestedRange: RequestedRange
    public let files: [FileEntry]
    public let limitations: [String]
    public let privacy: Privacy

    enum CodingKeys: String, CodingKey {
        case schema
        case bundleID = "bundle_id"
        case createdAt = "created_at"
        case producer
        case requestedRange = "requested_range"
        case files
        case limitations
        case privacy
    }
}

struct EvidenceBundleSummary: Codable, Equatable {
    struct Category: Codable, Equatable {
        let name: String
        let eventCount: Int
        let allocatedDelta: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case eventCount = "event_count"
            case allocatedDelta = "allocated_delta"
        }
    }

    let schema: String
    let requestedRange: EvidenceBundleManifest.RequestedRange
    let rawEventCount: Int
    let snapshotCount: Int
    let hourlySummaryCount: Int
    let dailySummaryCount: Int
    let allocatedDelta: Int64
    let categories: [Category]
    let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case requestedRange = "requested_range"
        case rawEventCount = "raw_event_count"
        case snapshotCount = "snapshot_count"
        case hourlySummaryCount = "hourly_summary_count"
        case dailySummaryCount = "daily_summary_count"
        case allocatedDelta = "allocated_delta"
        case categories
        case limitations
    }
}

struct EvidenceBundleRollups: Codable {
    struct Row: Codable {
        let bucketStart: String
        let path: String
        let operation: String
        let eventCount: Int
        let logicalDelta: Int64
        let allocatedDelta: Int64

        enum CodingKeys: String, CodingKey {
            case bucketStart = "bucket_start"
            case path
            case operation
            case eventCount = "event_count"
            case logicalDelta = "logical_delta"
            case allocatedDelta = "allocated_delta"
        }
    }

    let schema: String
    let hourly: [Row]
    let daily: [Row]
}

struct EvidenceBundleSnapshots: Codable {
    let schema: String
    let snapshots: [StorageSnapshot]
}

struct EvidenceBundleIntegrity: Codable {
    struct Entry: Codable {
        let path: String
        let sha256: String
        let bytes: Int
    }

    let schema: String
    let algorithm: String
    let files: [Entry]
}

struct ExportedEvidenceEvent: Codable {
    struct Size: Codable {
        let logicalBefore: Int64?
        let logicalAfter: Int64?
        let logicalDelta: Int64
        let allocatedBefore: Int64?
        let allocatedAfter: Int64?
        let allocatedDelta: Int64

        enum CodingKeys: String, CodingKey {
            case logicalBefore = "logical_before"
            case logicalAfter = "logical_after"
            case logicalDelta = "logical_delta"
            case allocatedBefore = "allocated_before"
            case allocatedAfter = "allocated_after"
            case allocatedDelta = "allocated_delta"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNil(forKey: .logicalBefore)
            try container.encodeNil(forKey: .logicalAfter)
            try container.encode(logicalDelta, forKey: .logicalDelta)
            try container.encodeNil(forKey: .allocatedBefore)
            try container.encodeNil(forKey: .allocatedAfter)
            try container.encode(allocatedDelta, forKey: .allocatedDelta)
        }
    }

    struct Actor: Codable {
        let processID: Int?
        let executable: String?
        let command: String?
        let workingDirectory: String?
        let ancestorExecutables: [String]

        enum CodingKeys: String, CodingKey {
            case processID = "process_id"
            case executable
            case command
            case workingDirectory = "working_directory"
            case ancestorExecutables = "ancestor_executables"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNil(forKey: .processID)
            try container.encodeNil(forKey: .executable)
            try container.encodeNil(forKey: .command)
            try container.encodeNil(forKey: .workingDirectory)
            try container.encode(ancestorExecutables, forKey: .ancestorExecutables)
        }
    }

    struct Session: Codable {
        let provider: String
        let sessionID: String?
        let title: String?
        let workingDirectory: String?

        enum CodingKeys: String, CodingKey {
            case provider
            case sessionID = "session_id"
            case title
            case workingDirectory = "working_directory"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(provider, forKey: .provider)
            try container.encodeNil(forKey: .sessionID)
            try container.encodeNil(forKey: .title)
            try container.encodeNil(forKey: .workingDirectory)
        }
    }

    struct Attribution: Codable {
        let confidence: String
        let method: String
        let limitations: [String]
    }

    struct Classification: Codable {
        let consumerCategory: String
        let reclaimability: String
        let cleanupSafety: String

        enum CodingKeys: String, CodingKey {
            case consumerCategory = "consumer_category"
            case reclaimability
            case cleanupSafety = "cleanup_safety"
        }
    }

    struct Reference: Codable {
        let kind: String
        let reference: String
    }

    let schema: String
    let eventID: String
    let observedAt: String
    let operation: String
    let path: String
    let size: Size
    let actor: Actor
    let session: Session
    let attribution: Attribution
    let classification: Classification
    let evidence: [Reference]

    enum CodingKeys: String, CodingKey {
        case schema
        case eventID = "event_id"
        case observedAt = "observed_at"
        case operation
        case path
        case size
        case actor
        case session
        case attribution
        case classification
        case evidence
    }
}

public enum EvidenceBundleExportError: Error, Equatable, LocalizedError {
    case invalidRange
    case unsafeBundleIdentifier
    case destinationAlreadyExists
    case compressionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidRange: "The requested export range is invalid."
        case .unsafeBundleIdentifier: "The bundle identifier is not a safe path component."
        case .destinationAlreadyExists: "An export with this bundle identifier already exists."
        case .compressionFailed: "The event detail stream could not be compressed."
        }
    }
}
