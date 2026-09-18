import Foundation

/// Shared versioned MCP/export contract. Unknown fields are explicit nulls.
public struct EvidenceEventTimingPresentation: Codable, Equatable, Sendable {
    public let schema: String
    public let basis: String
    public let occurredStart: String?
    public let occurredEnd: String?
    public let detectedAt: String?
    public let limitations: [String]

    public init(timing: EvidenceEventTiming?) {
        schema = "event-timing-v1"
        basis = timing == nil ? "unverified" : "measured-observation"
        occurredStart = timing?.occurredStart.map(EvidenceTimestamp.format)
        occurredEnd = timing.map { EvidenceTimestamp.format($0.occurredEnd) }
        detectedAt = timing.map { EvidenceTimestamp.format($0.detectedAt) }
        limitations = timing == nil
            ? ["Verified occurrence bounds were not retained. observed_at must not be interpreted as the file creation time."]
            : ["Bounds describe observations, not exact creation or writer timestamps."]
                + (timing?.occurredStart == nil ? ["The occurrence lower bound is unknown."] : [])
    }

    enum CodingKeys: String, CodingKey {
        case schema, basis, limitations
        case occurredStart = "occurred_start"
        case occurredEnd = "occurred_end"
        case detectedAt = "detected_at"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(basis, forKey: .basis)
        try container.encode(occurredStart, forKey: .occurredStart)
        try container.encode(occurredEnd, forKey: .occurredEnd)
        try container.encode(detectedAt, forKey: .detectedAt)
        try container.encode(limitations, forKey: .limitations)
    }
}
