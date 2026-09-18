import Foundation

public enum EvidencePathDetail: String, Codable, Sendable {
    case full
    case basename
    case hashed
}

/// Bounds serialized input before decoding and all emitted payload bytes. These
/// are per-export ceilings, independent of the separate database storage budget.
public struct EvidenceExportLimits: Equatable, Sendable {
    public let maximumReadBytes: Int
    public let maximumPayloadBytes: Int
    public static let manual = EvidenceExportLimits()
    public static let inline = EvidenceExportLimits(maximumReadBytes: 4 * 1_024 * 1_024, maximumPayloadBytes: 2 * 1_024 * 1_024)

    public init(maximumReadBytes: Int = 32 * 1_024 * 1_024, maximumPayloadBytes: Int = 64 * 1_024 * 1_024) {
        self.maximumReadBytes = min(32 * 1_024 * 1_024, max(0, maximumReadBytes))
        self.maximumPayloadBytes = min(64 * 1_024 * 1_024, max(0, maximumPayloadBytes))
    }
}

public struct EvidenceBundleExportOptions: Equatable, Sendable {
    public let from: Date
    public let through: Date
    public let pathDetail: EvidencePathDetail
    public let maximumEvents: Int
    public let limits: EvidenceExportLimits
    /// Current watched roots and exclusions; retained evidence outside them is
    /// omitted from the bundle at export time rather than waiting for a rescan.
    public let scope: EvidenceQueryScope?

    public init(from: Date, through: Date, pathDetail: EvidencePathDetail = .full, maximumEvents: Int = 100_000, limits: EvidenceExportLimits = .manual, scope: EvidenceQueryScope? = nil) {
        self.from = from
        self.through = through
        self.pathDetail = pathDetail
        self.maximumEvents = min(100_000, max(1, maximumEvents))
        self.limits = limits
        self.scope = scope
    }
}

public struct EvidenceBundleExportResult: Sendable {
    public let bundleURL: URL
    public let manifest: EvidenceBundleManifest
    public let exportID: String
    public let kind: EvidenceExportKind
    let ownership: OwnedExportDirectory

    /// Only temporary exports carry permission for caller-initiated destruction.
    /// A replacement pathname does not transfer ownership to this request.
    public func destroyTemporaryPayload() throws {
        guard kind == .temporary, ownership.removeIfOwned() else {
            throw EvidenceBundleExportError.destinationOwnershipChanged
        }
    }
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

    struct CurrentConsumer: Codable, Equatable {
        let path: String
        let kind: String
        let itemCount: Int
        let logicalBytes: Int64
        let allocatedBytes: Int64
        let actionable: Bool

        enum CodingKeys: String, CodingKey {
            case path
            case kind
            case itemCount = "item_count"
            case logicalBytes = "logical_bytes"
            case allocatedBytes = "allocated_bytes"
            case actionable
        }
    }

    let schema: String
    let requestedRange: EvidenceBundleManifest.RequestedRange
    let volumeCapacityScope: String
    let fileDetailRoots: [String]
    let exclusions: [String]
    let detailCoverage: String
    let stateAsOf: String?
    let lastCompleteObservationAt: String?
    let openGapCount: Int
    let activeGenerationID: String?
    let activeGenerationStartedAt: String?
    let scanCompletedRootCount: Int
    let scanRootCount: Int
    let scanProcessedEntryCount: Int
    let scanStagedFileCount: Int
    let currentStateCount: Int
    let currentStateAllocatedBytes: Int64
    let growthAssessment: String
    let rawEventCount: Int
    let snapshotCount: Int
    let hourlySummaryCount: Int
    let dailySummaryCount: Int
    let allocatedDelta: Int64
    let categories: [Category]
    let largestCurrentDirectories: [CurrentConsumer]
    let largestCurrentFiles: [CurrentConsumer]
    let cleanupReviewLeads: [CurrentConsumer]
    let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case requestedRange = "requested_range"
        case volumeCapacityScope = "volume_capacity_scope"
        case fileDetailRoots = "file_detail_roots"
        case exclusions
        case detailCoverage = "detail_coverage"
        case stateAsOf = "state_as_of"
        case lastCompleteObservationAt = "last_complete_observation_at"
        case openGapCount = "open_gap_count"
        case activeGenerationID = "active_generation_id"
        case activeGenerationStartedAt = "active_generation_started_at"
        case scanCompletedRootCount = "scan_completed_root_count"
        case scanRootCount = "scan_root_count"
        case scanProcessedEntryCount = "scan_processed_entry_count"
        case scanStagedFileCount = "scan_staged_file_count"
        case currentStateCount = "current_state_count"
        case currentStateAllocatedBytes = "current_state_allocated_bytes"
        case growthAssessment = "growth_assessment"
        case rawEventCount = "raw_event_count"
        case snapshotCount = "snapshot_count"
        case hourlySummaryCount = "hourly_summary_count"
        case dailySummaryCount = "daily_summary_count"
        case allocatedDelta = "allocated_delta"
        case categories
        case largestCurrentDirectories = "largest_current_directories"
        case largestCurrentFiles = "largest_current_files"
        case cleanupReviewLeads = "cleanup_review_leads"
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
            try container.encode(processID, forKey: .processID)
            try container.encode(executable, forKey: .executable)
            try container.encode(command, forKey: .command)
            try container.encode(workingDirectory, forKey: .workingDirectory)
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
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(title, forKey: .title)
            try container.encode(workingDirectory, forKey: .workingDirectory)
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
    let timing: EvidenceEventTimingPresentation
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
        case timing
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
    case budgetExceeded
    case invalidEvidence
    case destinationOwnershipChanged

    public var errorDescription: String? {
        switch self {
        case .invalidRange: "The requested export range is invalid."
        case .unsafeBundleIdentifier: "The bundle identifier is not a safe path component."
        case .destinationAlreadyExists: "An export with this bundle identifier already exists."
        case .compressionFailed: "The event detail stream is incomplete or could not be encoded or decoded."
        case .budgetExceeded: "The export exceeded its bounded input or output budget. Request a smaller range or fewer events."
        case .invalidEvidence: "The stored evidence contains invalid serialized data."
        case .destinationOwnershipChanged: "Temporary export ownership could not be verified; no replacement data was removed."
        }
    }
}
