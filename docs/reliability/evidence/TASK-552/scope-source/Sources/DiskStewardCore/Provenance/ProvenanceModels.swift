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
    private let recordedLimitations: [String]
    public let detectedAt: Date
    private let recordedOccurredStart: Date?
    private let timingVersion: Int?
    /// Old payloads cannot distinguish a supplied bound from the old discovery-time default.
    public var occurredStart: Date? { timingVersion == 1 ? recordedOccurredStart : nil }
    public var timingBasis: String { timingVersion == 1 ? "observation-bounds" : "legacy-unverified" }
    public var limitations: [String] {
        var values = recordedLimitations
        if timingVersion != 1 { values.append("Legacy occurrence timing is unverified; its original timestamps are retained, not promoted to measured evidence.") }
        if occurredStart == nil { values.append("The occurrence lower bound is unknown; observation time is not creation time.") }
        return Array(Set(values)).sorted()
    }
    public let occurredEnd: Date
    public let observedAncestry: [ProcessAncestryRecord]
    public let contradictions: [String]
    public let supersedesClaimID: String?
    public internal(set) var supersededByClaimID: String?

    enum CodingKeys: String, CodingKey {
        case claimID, event, actor, session, confidence, method, support, detectedAt, occurredEnd
        case observedAncestry, contradictions, supersedesClaimID, supersededByClaimID, timingVersion
        case recordedOccurredStart = "occurredStart"
        case recordedLimitations = "limitations"
    }

    func withSupersededBy(_ identifier: String?) -> Self {
        var copy = self
        copy.supersededByClaimID = identifier
        return copy
    }

    var hasValidChronology: Bool {
        ProvenanceChronology.isValid(start: occurredStart, end: occurredEnd, detected: detectedAt, observed: event.observedAt)
    }

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
        self.recordedLimitations = Array(Set(limitations)).sorted()
        self.detectedAt = detectedAt ?? event.timing?.detectedAt ?? event.observedAt
        // Preserve contradictory evidence for validation; sorting endpoints
        // would manufacture an apparently valid occurrence interval.
        self.recordedOccurredStart = occurredStart ?? event.timing?.occurredStart
        self.timingVersion = 1
        self.occurredEnd = occurredEnd ?? event.timing?.occurredEnd ?? event.observedAt
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
    public let occurredStart: Date?
    public let occurredEnd: Date
    public let contradictions: [String]
    public let supersedesClaimID: String?
    public let claimID: String?

    var hasValidChronology: Bool {
        ProvenanceChronology.isValid(start: occurredStart, end: occurredEnd, detected: detectedAt, observed: event.observedAt)
    }

    /// Query-time revalidation must retain the selected claim's facts exactly.
    /// In particular, nil is an explicit unknown here, not an omitted argument
    /// that may default back to an older event's measured lower bound.
    init(event: EvidenceStoreEvent, retainingOccurrenceOf claim: ProvenanceClaim,
         registrations: [AgentSessionRegistration], fseventGap: Bool) {
        self.event = event
        self.privilegedEvent = nil
        self.fsevents = []
        self.fseventGap = fseventGap
        self.registrations = registrations
        self.ancestry = .init(records: [])
        self.isHistorical = true
        self.detectedAt = claim.detectedAt
        self.occurredStart = claim.occurredStart
        self.occurredEnd = claim.occurredEnd
        self.contradictions = claim.contradictions
        self.supersedesClaimID = nil
        self.claimID = claim.claimID
    }

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
        self.detectedAt = detectedAt ?? event.timing?.detectedAt ?? event.observedAt
        self.occurredStart = occurredStart ?? event.timing?.occurredStart
        self.occurredEnd = occurredEnd ?? event.timing?.occurredEnd ?? event.observedAt
        self.contradictions = Array(Set(contradictions)).sorted()
        self.supersedesClaimID = supersedesClaimID
        self.claimID = claimID
    }
}

private enum ProvenanceChronology {
    /// Claim payloads keep reference-date seconds while the store keeps Unix
    /// seconds; converting the same instant between the bases can move it by
    /// one binary digit. Endpoints are never reordered; only representation
    /// error below a microsecond is tolerated when comparing them.
    static let tolerance: TimeInterval = ProvenanceEngine.observedAtTolerance

    static func isValid(start: Date?, end: Date, detected: Date, observed: Date) -> Bool {
        [end, detected, observed].allSatisfy { $0.timeIntervalSinceReferenceDate.isFinite }
            && (start.map { $0.timeIntervalSinceReferenceDate.isFinite && $0.timeIntervalSince(end) <= tolerance } ?? true)
            && end.timeIntervalSince(detected) <= tolerance && observed.timeIntervalSince(detected) <= tolerance
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
    public let occurredStart: Date?
    public let occurredEnd: Date
    public let timingBasis: String
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
        case timingBasis = "timing_basis"
        case observedAncestry = "observed_ancestry"
        case contradictions
        case supersedesClaimID = "supersedes_claim_id"
        case supersededByClaimID = "superseded_by_claim_id"
    }

    public init(claim: ProvenanceClaim) {
        schema = "provenance-presentation-v3"
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
        timingBasis = claim.timingBasis
        observedAncestry = claim.observedAncestry
        contradictions = claim.contradictions
        supersedesClaimID = claim.supersedesClaimID
        supersededByClaimID = claim.supersededByClaimID
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema)
        try values.encode(eventID, forKey: .eventID)
        try values.encode(claimID, forKey: .claimID)
        try values.encode(path, forKey: .path)
        try values.encode(operation, forKey: .operation)
        try values.encode(logicalDelta, forKey: .logicalDelta)
        try values.encode(allocatedDelta, forKey: .allocatedDelta)
        try values.encodeIfPresent(actorPID, forKey: .actorPID)
        try values.encodeIfPresent(actorExecutable, forKey: .actorExecutable)
        try values.encodeIfPresent(sessionID, forKey: .sessionID)
        try values.encodeIfPresent(sessionClient, forKey: .sessionClient)
        try values.encode(confidence, forKey: .confidence)
        try values.encode(method, forKey: .method)
        try values.encode(support, forKey: .support)
        try values.encode(limitations, forKey: .limitations)
        try values.encode(detectedAt, forKey: .detectedAt)
        try values.encode(occurredStart, forKey: .occurredStart)
        try values.encode(occurredEnd, forKey: .occurredEnd)
        try values.encode(timingBasis, forKey: .timingBasis)
        try values.encode(observedAncestry, forKey: .observedAncestry)
        try values.encode(contradictions, forKey: .contradictions)
        try values.encodeIfPresent(supersedesClaimID, forKey: .supersedesClaimID)
        try values.encodeIfPresent(supersededByClaimID, forKey: .supersededByClaimID)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sourceSchema = try values.decode(String.self, forKey: .schema)
        guard ["provenance-presentation-v2", "provenance-presentation-v3"].contains(sourceSchema) else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: values, debugDescription: "Unsupported provenance presentation")
        }
        schema = "provenance-presentation-v3"
        eventID = try values.decode(String.self, forKey: .eventID)
        claimID = try values.decode(String.self, forKey: .claimID)
        path = try values.decode(String.self, forKey: .path)
        operation = try values.decode(String.self, forKey: .operation)
        logicalDelta = try values.decode(Int64.self, forKey: .logicalDelta)
        allocatedDelta = try values.decode(Int64.self, forKey: .allocatedDelta)
        actorPID = try values.decodeIfPresent(Int32.self, forKey: .actorPID)
        actorExecutable = try values.decodeIfPresent(String.self, forKey: .actorExecutable)
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        sessionClient = try values.decodeIfPresent(String.self, forKey: .sessionClient)
        confidence = try values.decode(String.self, forKey: .confidence)
        method = try values.decode(String.self, forKey: .method)
        support = try values.decode([ProvenanceSourceReference].self, forKey: .support)
        let originalLimitations = try values.decode([String].self, forKey: .limitations)
        limitations = sourceSchema == "provenance-presentation-v2"
            ? Array(Set(originalLimitations + ["Legacy occurrence timing is unverified; observation time is not creation time."])).sorted()
            : originalLimitations
        detectedAt = try values.decode(Date.self, forKey: .detectedAt)
        occurredStart = sourceSchema == "provenance-presentation-v3" ? try values.decodeIfPresent(Date.self, forKey: .occurredStart) : nil
        occurredEnd = try values.decode(Date.self, forKey: .occurredEnd)
        timingBasis = sourceSchema == "provenance-presentation-v3" ? try values.decode(String.self, forKey: .timingBasis) : "legacy-unverified"
        observedAncestry = try values.decode([ProcessAncestryRecord].self, forKey: .observedAncestry)
        contradictions = try values.decode([String].self, forKey: .contradictions)
        supersedesClaimID = try values.decodeIfPresent(String.self, forKey: .supersedesClaimID)
        supersededByClaimID = try values.decodeIfPresent(String.self, forKey: .supersededByClaimID)
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
