import Foundation

public struct WriteCoalescer: Sendable {
    public init() {}

    public func coalesce(_ events: [EvidenceStoreEvent], within window: TimeInterval) -> [EvidenceStoreEvent] {
        let ordered = events.sorted { ($0.path, $0.observedAt) < ($1.path, $1.observedAt) }
        var output: [EvidenceStoreEvent] = []
        for event in ordered {
            guard let last = output.last,
                  last.path == event.path,
                  last.operation == event.operation,
                  event.observedAt.timeIntervalSince(last.observedAt) <= window
            else {
                output.append(event)
                continue
            }
            output.removeLast()
            output.append(
                EvidenceStoreEvent(
                    eventID: last.eventID,
                    observedAt: event.observedAt,
                    operation: event.operation,
                    path: event.path,
                    logicalDelta: last.logicalDelta + event.logicalDelta,
                    allocatedDelta: last.allocatedDelta + event.allocatedDelta,
                    consumerCategory: event.consumerCategory,
                    confidence: weaker(last.confidence, event.confidence),
                    isAnomaly: last.isAnomaly || event.isAnomaly,
                    isReviewed: last.isReviewed && event.isReviewed
                )
            )
        }
        return output
    }

    private func weaker(_ left: EvidenceStoreEvent.Confidence, _ right: EvidenceStoreEvent.Confidence) -> EvidenceStoreEvent.Confidence {
        let order: [EvidenceStoreEvent.Confidence] = [.exact, .toolLinked, .inferred, .unknown]
        return order[max(order.firstIndex(of: left) ?? 3, order.firstIndex(of: right) ?? 3)]
    }
}
