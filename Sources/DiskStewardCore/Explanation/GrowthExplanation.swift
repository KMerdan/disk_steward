import Foundation

public struct GrowthCause: Equatable, Sendable {
    public let category: String
    public let allocatedDelta: Int64
    public let confidence: EvidenceStoreEvent.Confidence
    public let method: String
    public let samplePaths: [String]
}

public struct GrowthExplanationReport: Equatable, Sendable {
    public let volumeUsedDelta: Int64
    public let detailedPositiveDelta: Int64
    public let unexplainedDelta: Int64
    public let causes: [GrowthCause]
    public let limitations: [String]
}

public struct GrowthExplanationEngine: Sendable {
    public init() {}

    public func explain(
        volumeUsedDelta: Int64,
        detailedEvents: [EvidenceStoreEvent],
        eventGap: Bool = false,
        scopeLimitations: [String] = []
    ) -> GrowthExplanationReport {
        let positive = detailedEvents.filter { $0.allocatedDelta > 0 }
        let grouped = Dictionary(grouping: positive, by: \.consumerCategory)
        var causes = grouped.map { category, events in
            GrowthCause(
                category: category,
                allocatedDelta: events.reduce(0) { $0 + $1.allocatedDelta },
                confidence: eventGap ? .unknown : weakest(events.map(\.confidence)),
                method: eventGap ? "observation-gap" : "snapshot-delta",
                samplePaths: Array(events.map(\.path).sorted().prefix(5))
            )
        }.sorted { ($0.allocatedDelta, $0.category) > ($1.allocatedDelta, $1.category) }

        let detailed = causes.reduce(0) { $0 + $1.allocatedDelta }
        let unexplained = max(0, volumeUsedDelta - detailed)
        var limitations = scopeLimitations
        if eventGap { limitations.append("FSEvents reported a gap; targeted detail may be incomplete.") }
        if unexplained > 0 {
            limitations.append("Whole-volume growth exceeds observed watched-root detail by \(unexplained) bytes.")
            causes.append(
                GrowthCause(
                    category: "unexplained",
                    allocatedDelta: unexplained,
                    confidence: .unknown,
                    method: "snapshot-delta",
                    samplePaths: []
                )
            )
        }
        return GrowthExplanationReport(
            volumeUsedDelta: volumeUsedDelta,
            detailedPositiveDelta: detailed,
            unexplainedDelta: unexplained,
            causes: causes,
            limitations: Array(Set(limitations)).sorted()
        )
    }

    private func weakest(_ values: [EvidenceStoreEvent.Confidence]) -> EvidenceStoreEvent.Confidence {
        let order: [EvidenceStoreEvent.Confidence] = [.exact, .toolLinked, .inferred, .unknown]
        return values.max { (order.firstIndex(of: $0) ?? 3) < (order.firstIndex(of: $1) ?? 3) } ?? .unknown
    }
}
