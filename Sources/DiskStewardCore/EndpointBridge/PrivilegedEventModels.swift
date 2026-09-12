import Foundation

public enum PrivilegedFileOperation: String, Codable, Sendable {
    case create
    case rename
    case writeClose = "write-close"
    case writeSummary = "write-summary"
}

public struct PrivilegedFileIdentity: Codable, Hashable, Sendable {
    public let volumeID: String
    public let fileID: UInt64
    public let generation: UInt64?

    public init(volumeID: String, fileID: UInt64, generation: UInt64? = nil) {
        self.volumeID = volumeID
        self.fileID = fileID
        self.generation = generation
    }
}

public struct PrivilegedSizeObservation: Codable, Equatable, Sendable {
    public let logicalBefore: Int64?
    public let logicalAfter: Int64?
    public let allocatedBefore: Int64?
    public let allocatedAfter: Int64?
    public let method: String

    public init(logicalBefore: Int64?, logicalAfter: Int64?, allocatedBefore: Int64?, allocatedAfter: Int64?, method: String) {
        self.logicalBefore = logicalBefore
        self.logicalAfter = logicalAfter
        self.allocatedBefore = allocatedBefore
        self.allocatedAfter = allocatedAfter
        self.method = method
    }

    public var isComplete: Bool {
        logicalBefore != nil && logicalAfter != nil && allocatedBefore != nil && allocatedAfter != nil && method != "unknown"
    }
}

public struct RawPrivilegedNotification: Codable, Equatable, Sendable {
    public let eventID: String
    public let streamID: String
    public let sequence: UInt64
    public let observedAt: Date
    public let operation: PrivilegedFileOperation
    public let path: String
    public let destinationPath: String?
    public let process: ProcessIdentity
    public let fileIdentity: PrivilegedFileIdentity?
    public let size: PrivilegedSizeObservation
    public let deadlineMet: Bool

    public init(eventID: String, streamID: String, sequence: UInt64, observedAt: Date, operation: PrivilegedFileOperation, path: String, destinationPath: String? = nil, process: ProcessIdentity, fileIdentity: PrivilegedFileIdentity?, size: PrivilegedSizeObservation, deadlineMet: Bool = true) {
        self.eventID = eventID
        self.streamID = streamID
        self.sequence = sequence
        self.observedAt = observedAt
        self.operation = operation
        self.path = path
        self.destinationPath = destinationPath
        self.process = process
        self.fileIdentity = fileIdentity
        self.size = size
        self.deadlineMet = deadlineMet
    }
}

public struct NormalizedPrivilegedEvent: Codable, Equatable, Sendable {
    public let raw: RawPrivilegedNotification
    public let watchedRoot: String
    public let logicalDelta: Int64
    public let allocatedDelta: Int64
    public let coalescedCount: Int
    public let gapBefore: Bool
    public let confidence: EvidenceStoreEvent.Confidence
    public let method: String
    public let limitations: [String]

    public init(raw: RawPrivilegedNotification, watchedRoot: String, logicalDelta: Int64, allocatedDelta: Int64, coalescedCount: Int = 1, gapBefore: Bool, confidence: EvidenceStoreEvent.Confidence, method: String, limitations: [String]) {
        self.raw = raw
        self.watchedRoot = watchedRoot
        self.logicalDelta = logicalDelta
        self.allocatedDelta = allocatedDelta
        self.coalescedCount = coalescedCount
        self.gapBefore = gapBefore
        self.confidence = confidence
        self.method = method
        self.limitations = limitations
    }

    public var event: EvidenceStoreEvent {
        EvidenceStoreEvent(eventID: raw.eventID, observedAt: raw.observedAt, operation: .writeSummary, path: raw.destinationPath ?? raw.path, logicalDelta: logicalDelta, allocatedDelta: allocatedDelta, consumerCategory: "privileged-observation", confidence: confidence)
    }
}

public struct EndpointBridgePeerProof: Equatable, Sendable {
    public let teamID: String
    public let bundleID: String
    public let appGroupContainer: String
    public let designatedRequirementSatisfied: Bool
    public let challengeDigest: String

    public init(teamID: String, bundleID: String, appGroupContainer: String, designatedRequirementSatisfied: Bool, challengeDigest: String) {
        self.teamID = teamID
        self.bundleID = bundleID
        self.appGroupContainer = appGroupContainer
        self.designatedRequirementSatisfied = designatedRequirementSatisfied
        self.challengeDigest = challengeDigest
    }
}

public enum EndpointBridgeState: String, Codable, Sendable {
    case available
    case pendingUserApproval = "pending-user-approval"
    case notEntitled = "not-entitled"
    case notPermitted = "not-permitted"
    case tooManyClients = "too-many-clients"
    case overloaded
    case droppedEvents = "dropped-events"
    case unavailable
}

public struct EndpointBridgeStatus: Codable, Equatable, Sendable {
    public let state: EndpointBridgeState
    public let eventGap: Bool
    public let droppedEvents: Int
    public let fallbackActive: Bool
    public let maximumConfidence: EvidenceStoreEvent.Confidence
    public let automaticRetry: Bool
    public let retryAfter: TimeInterval
    public let requiresUserAction: Bool
    public let limitations: [String]
}

public enum EndpointBridgeError: Error, Equatable, LocalizedError {
    case unauthenticated
    case invalidNotification(String)
    case unavailable(EndpointBridgeState)

    public var errorDescription: String? {
        switch self {
        case .unauthenticated: "The privileged bridge peer failed code-signing or challenge validation."
        case let .invalidNotification(reason): "Invalid privileged notification: \(reason)"
        case let .unavailable(state): "The privileged observer is \(state.rawValue); standard monitoring remains active."
        }
    }
}
