import Foundation

public struct ProvenanceSourceReference: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case endpointSecurity = "endpoint-security"
        case fsevents
        case metadataSnapshot = "metadata-snapshot"
        case processAncestry = "process-ancestry"
        case agentSession = "agent-session"
        case historicalRecord = "historical-record"
    }

    public let kind: Kind
    public let identifier: String
    public let supports: String

    public init(kind: Kind, identifier: String, supports: String) {
        self.kind = kind
        self.identifier = identifier
        self.supports = supports
    }
}

public struct ProvenanceActor: Codable, Equatable, Sendable {
    public let process: ProcessIdentity
    public let relationship: String

    public init(process: ProcessIdentity, relationship: String) {
        self.process = process
        self.relationship = relationship
    }
}

public struct ProvenanceSession: Codable, Equatable, Sendable {
    public let registrationID: UUID
    public let sessionID: String
    public let client: AgentClientKind
    public let relationship: String

    public init(registration: AgentSessionRegistration, relationship: String) {
        registrationID = registration.registrationID
        sessionID = registration.sessionID
        client = registration.client
        self.relationship = relationship
    }
}

public struct ProvenanceClaim: Codable, Equatable, Sendable {
    public let claimID: String
    public let event: EvidenceStoreEvent
    public let actor: ProvenanceActor?
    public let session: ProvenanceSession?
    public let confidence: EvidenceStoreEvent.Confidence
    public let method: String
    public let support: [ProvenanceSourceReference]
    public let limitations: [String]
    public let detectedAt: Date
    public let occurredStart: Date
    public let occurredEnd: Date
    public let observedAncestry: [ProcessAncestryRecord]
    public let contradictions: [String]
    public let supersedesClaimID: String?
    public let supersededByClaimID: String?

    public init(
        event: EvidenceStoreEvent,
        actor: ProvenanceActor?,
        session: ProvenanceSession?,
        confidence: EvidenceStoreEvent.Confidence,
        method: String,
        support: [ProvenanceSourceReference],
        limitations: [String],
        claimID: String? = nil,
        detectedAt: Date? = nil,
        occurredStart: Date? = nil,
        occurredEnd: Date? = nil,
        observedAncestry: [ProcessAncestryRecord] = [],
        contradictions: [String] = [],
        supersedesClaimID: String? = nil,
        supersededByClaimID: String? = nil
    ) {
        self.claimID = claimID ?? "claim:\(event.eventID):\(method)"
        self.event = event
        self.actor = actor
        self.session = session
        self.confidence = confidence
        self.method = method
        self.support = support.sorted {
            ($0.kind.rawValue, $0.identifier, $0.supports) < ($1.kind.rawValue, $1.identifier, $1.supports)
        }
        self.limitations = Array(Set(limitations)).sorted()
        self.detectedAt = detectedAt ?? event.observedAt
        self.occurredStart = min(occurredStart ?? event.observedAt, occurredEnd ?? event.observedAt)
        self.occurredEnd = max(occurredStart ?? event.observedAt, occurredEnd ?? event.observedAt)
        self.observedAncestry = observedAncestry
        self.contradictions = Array(Set(contradictions)).sorted()
        self.supersedesClaimID = supersedesClaimID
        self.supersededByClaimID = supersededByClaimID
    }
}

public struct ProvenanceInput: Sendable {
    public let event: EvidenceStoreEvent
    public let privilegedEvent: NormalizedPrivilegedEvent?
    public let fsevents: [TargetedChangeHint]
    public let fseventGap: Bool
    public let registrations: [AgentSessionRegistration]
    public let ancestry: ProcessAncestrySnapshot
    public let isHistorical: Bool
    public let detectedAt: Date
    public let occurredStart: Date
    public let occurredEnd: Date
    public let contradictions: [String]
    public let supersedesClaimID: String?
    public let claimID: String?

    public init(
        event: EvidenceStoreEvent,
        privilegedEvent: NormalizedPrivilegedEvent? = nil,
        fsevents: [TargetedChangeHint] = [],
        fseventGap: Bool = false,
        registrations: [AgentSessionRegistration] = [],
        ancestry: ProcessAncestrySnapshot = .init(records: []),
        isHistorical: Bool = false,
        detectedAt: Date? = nil,
        occurredStart: Date? = nil,
        occurredEnd: Date? = nil,
        contradictions: [String] = [],
        supersedesClaimID: String? = nil,
        claimID: String? = nil
    ) {
        self.event = event
        self.privilegedEvent = privilegedEvent
        self.fsevents = fsevents
        self.fseventGap = fseventGap
        self.registrations = registrations
        self.ancestry = ancestry
        self.isHistorical = isHistorical
        self.detectedAt = detectedAt ?? event.observedAt
        self.occurredStart = min(occurredStart ?? event.observedAt, occurredEnd ?? event.observedAt)
        self.occurredEnd = max(occurredStart ?? event.observedAt, occurredEnd ?? event.observedAt)
        self.contradictions = Array(Set(contradictions)).sorted()
        self.supersedesClaimID = supersedesClaimID
        self.claimID = claimID
    }
}

public struct ProvenancePresentationRecord: Codable, Equatable, Sendable {
    public let schema: String
    public let eventID: String
    public let claimID: String
    public let path: String
    public let operation: String
    public let logicalDelta: Int64
    public let allocatedDelta: Int64
    public let actorPID: Int32?
    public let actorExecutable: String?
    public let sessionID: String?
    public let sessionClient: String?
    public let confidence: String
    public let method: String
    public let support: [ProvenanceSourceReference]
    public let limitations: [String]
    public let detectedAt: Date
    public let occurredStart: Date
    public let occurredEnd: Date
    public let observedAncestry: [ProcessAncestryRecord]
    public let contradictions: [String]
    public let supersedesClaimID: String?
    public let supersededByClaimID: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case claimID = "claim_id"
        case eventID = "event_id"
        case path
        case operation
        case logicalDelta = "logical_delta"
        case allocatedDelta = "allocated_delta"
        case actorPID = "actor_pid"
        case actorExecutable = "actor_executable"
        case sessionID = "session_id"
        case sessionClient = "session_client"
        case confidence
        case method
        case support
        case limitations
        case detectedAt = "detected_at"
        case occurredStart = "occurred_start"
        case occurredEnd = "occurred_end"
        case observedAncestry = "observed_ancestry"
        case contradictions
        case supersedesClaimID = "supersedes_claim_id"
        case supersededByClaimID = "superseded_by_claim_id"
    }

    public init(claim: ProvenanceClaim) {
        schema = "provenance-presentation-v2"
        claimID = claim.claimID
        eventID = claim.event.eventID
        path = claim.event.path
        operation = claim.event.operation.rawValue
        logicalDelta = claim.event.logicalDelta
        allocatedDelta = claim.event.allocatedDelta
        actorPID = claim.actor?.process.pid
        actorExecutable = claim.actor?.process.executablePath
        sessionID = claim.session?.sessionID
        sessionClient = claim.session?.client.rawValue
        confidence = claim.confidence.rawValue
        method = claim.method
        support = claim.support
        limitations = claim.limitations
        detectedAt = claim.detectedAt
        occurredStart = claim.occurredStart
        occurredEnd = claim.occurredEnd
        observedAncestry = claim.observedAncestry
        contradictions = claim.contradictions
        supersedesClaimID = claim.supersedesClaimID
        supersededByClaimID = claim.supersededByClaimID
    }
}

public enum ProvenancePresentationChannel: String, CaseIterable, Sendable {
    case userInterface = "ui"
    case export
    case mcp
}

public struct ProvenancePresentationAdapter: Sendable {
    public init() {}

    /// Every channel receives the same evidence-bearing record. A surface may
    /// change layout, but it cannot silently alter confidence or causal support.
    public func record(for claim: ProvenanceClaim, channel _: ProvenancePresentationChannel) -> ProvenancePresentationRecord {
        ProvenancePresentationRecord(claim: claim)
    }
}
