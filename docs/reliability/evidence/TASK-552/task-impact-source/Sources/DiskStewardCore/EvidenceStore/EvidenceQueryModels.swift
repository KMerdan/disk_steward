import Foundation

public struct TaskImpactCandidate: Sendable {
    public let event: EvidenceStoreEvent
    public let currentClaim: ProvenanceClaim?
}

public enum TaskImpactQueryError: Error, Equatable, Sendable {
    case budgetExceeded
}

public struct EvidenceQueryPage<Item: Sendable>: Sendable {
    public let matchedCount: Int
    public let items: [Item]
    public let nextCursor: String?

    public init(matchedCount: Int, items: [Item], nextCursor: String?) {
        self.matchedCount = matchedCount
        self.items = items
        self.nextCursor = nextCursor
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
    public let nextCursor: String?

    public init(
        objectIDs: [String],
        currentStates: [CurrentFileStateRecord],
        events: [EvidenceStoreEvent],
        claims: [ProvenanceClaim],
        sessions: [AgentSessionRegistration],
        observationGaps: [EvidenceCoverageGap],
        matchedCount: Int,
        nextCursor: String?
    ) {
        self.objectIDs = objectIDs
        self.currentStates = currentStates
        self.events = events
        self.claims = claims
        self.sessions = sessions
        self.observationGaps = observationGaps
        self.matchedCount = matchedCount
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
