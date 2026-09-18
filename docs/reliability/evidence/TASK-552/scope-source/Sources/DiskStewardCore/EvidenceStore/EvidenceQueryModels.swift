import Foundation

public struct TaskImpactCandidate: Sendable {
    public let event: EvidenceStoreEvent
    public let currentClaim: ProvenanceClaim?
}

public enum TaskImpactQueryError: Error, Equatable, Sendable {
    case budgetExceeded
}

/// The user's current watched roots and exclusions, applied to evidence reads
/// at query time. Retained evidence outside this scope is hidden, not deleted:
/// a policy change must be visible immediately without waiting for a rescan,
/// and must never be reinterpreted as an observed removal.
public struct EvidenceQueryScope: Equatable, Sendable {
    public let scopeVersionID: String
    public let rootPaths: [String]
    public let excludedPaths: [String]

    public init(scopeVersionID: String, rootPaths: [String], excludedPaths: [String]) {
        self.scopeVersionID = scopeVersionID
        self.rootPaths = Self.normalizedUnique(rootPaths)
        self.excludedPaths = Self.normalizedUnique(excludedPaths)
    }

    public init(_ version: EvidenceScopeVersion) {
        self.init(scopeVersionID: version.scopeVersionID, rootPaths: version.rootPaths, excludedPaths: version.excludedPaths)
    }

    public func includes(path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard rootPaths.contains(where: { Self.contains(normalized, root: $0) }) else { return false }
        return !excludedPaths.contains(where: { Self.contains(normalized, root: $0) })
    }

    /// SQL predicate over a path column plus its ordered string bindings. Exact
    /// prefix comparison avoids LIKE wildcard escaping for arbitrary user paths.
    func predicate(column: String) -> (sql: String, bindings: [String]) {
        guard !rootPaths.isEmpty else { return ("0", []) }
        var bindings: [String] = []
        func clause(_ root: String) -> String {
            let prefix = root == "/" ? "/" : root + "/"
            bindings.append(root)
            bindings.append(prefix)
            bindings.append(prefix)
            return "(\(column) = ? OR substr(\(column), 1, length(?)) = ?)"
        }
        let included = "(" + rootPaths.map(clause).joined(separator: " OR ") + ")"
        let excluded = excludedPaths.map { "NOT " + clause($0) }
        return (([included] + excluded).joined(separator: " AND "), bindings)
    }

    private static func contains(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func normalizedUnique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.filter { seen.insert($0).inserted }
    }
}

public struct EvidenceQueryPage<Item: Sendable>: Sendable {
    public let matchedCount: Int
    public let items: [Item]
    public let nextCursor: String?
    /// Rows retained in the store but hidden by the applied query scope; nil
    /// when no scope was applied or the count was not measured.
    public let scopeHiddenCount: Int?

    public init(matchedCount: Int, items: [Item], nextCursor: String?, scopeHiddenCount: Int? = nil) {
        self.matchedCount = matchedCount
        self.items = items
        self.nextCursor = nextCursor
        self.scopeHiddenCount = scopeHiddenCount
    }

    public var truncated: Bool { nextCursor != nil }
}

public struct CurrentConsumerRecord: Equatable, Sendable {
    public let state: CurrentFileStateRecord
    public let consumerCategory: String

    public init(state: CurrentFileStateRecord, consumerCategory: String) {
        self.state = state
        self.consumerCategory = consumerCategory
    }
}

public struct EvidenceProvenanceChain: Sendable {
    public let objectIDs: [String]
    public let currentStates: [CurrentFileStateRecord]
    public let events: [EvidenceStoreEvent]
    public let claims: [ProvenanceClaim]
    public let sessions: [AgentSessionRegistration]
    public let observationGaps: [EvidenceCoverageGap]
    public let matchedCount: Int
    public let matchedCurrentStateCount: Int
    public let currentStateAsOf: Date?
    public let nextCursor: String?
    /// More file identities matched than the bounded identity search returns.
    public let identityLimitReached: Bool

    public init(
        objectIDs: [String],
        currentStates: [CurrentFileStateRecord],
        events: [EvidenceStoreEvent],
        claims: [ProvenanceClaim],
        sessions: [AgentSessionRegistration],
        observationGaps: [EvidenceCoverageGap],
        matchedCount: Int,
        nextCursor: String?,
        matchedCurrentStateCount: Int? = nil,
        currentStateAsOf: Date? = nil,
        identityLimitReached: Bool = false
    ) {
        self.identityLimitReached = identityLimitReached
        self.objectIDs = objectIDs
        self.currentStates = currentStates
        self.events = events
        self.claims = claims
        self.sessions = sessions
        self.observationGaps = observationGaps
        self.matchedCount = matchedCount
        self.matchedCurrentStateCount = matchedCurrentStateCount ?? currentStates.count
        self.currentStateAsOf = currentStateAsOf ?? currentStates.map(\.observedAt).max()
        self.nextCursor = nextCursor
    }
}

public struct SurvivingTaskImpact: Equatable, Sendable {
    public let objectCount: Int
    public let logicalBytes: Int64
    public let allocatedBytes: Int64

    public init(objectCount: Int, logicalBytes: Int64, allocatedBytes: Int64) {
        self.objectCount = objectCount
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
    }
}

public struct EvidenceGrowthAggregate: Equatable, Sendable {
    public let matchedCount: Int
    public let growthBytes: Int64
    public let shrinkBytes: Int64
    public let churnBytes: Int64
    public let netAllocatedDelta: Int64
    public let survivingObjectCount: Int
    public let survivingAllocatedBytes: Int64

    public init(
        matchedCount: Int,
        growthBytes: Int64,
        shrinkBytes: Int64,
        churnBytes: Int64,
        netAllocatedDelta: Int64,
        survivingObjectCount: Int,
        survivingAllocatedBytes: Int64
    ) {
        self.matchedCount = matchedCount
        self.growthBytes = growthBytes
        self.shrinkBytes = shrinkBytes
        self.churnBytes = churnBytes
        self.netAllocatedDelta = netAllocatedDelta
        self.survivingObjectCount = survivingObjectCount
        self.survivingAllocatedBytes = survivingAllocatedBytes
    }
}

public struct EvidenceGrowthItem: Equatable, Sendable {
    public let rowID: String
    public let observedAt: Date
    public let precision: String
    public let operation: EvidenceStoreEvent.Operation
    public let path: String
    public let eventCount: Int
    public let logicalDelta: Int64
    public let allocatedDelta: Int64
    public let consumerCategory: String
    public let confidence: EvidenceStoreEvent.Confidence
}

public struct EvidenceGrowthReadModel: Sendable {
    public let aggregate: EvidenceGrowthAggregate
    public let page: EvidenceQueryPage<EvidenceGrowthItem>
}

public struct PersistedTaskAttribution: Equatable, Sendable {
    public let eventID: String
    public let confidence: EvidenceStoreEvent.Confidence

    public init(eventID: String, confidence: EvidenceStoreEvent.Confidence) {
        self.eventID = eventID
        self.confidence = confidence
    }
}
