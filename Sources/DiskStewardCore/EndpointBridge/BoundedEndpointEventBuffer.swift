import Foundation

public enum EndpointBufferResult: Equatable, Sendable {
    case accepted
    case coalesced
    case dropped(total: Int)
}

public struct BoundedEndpointEventBuffer: Sendable {
    public let maximumEvents: Int
    public let maximumEstimatedBytes: Int
    public let coalescingWindow: TimeInterval
    public private(set) var droppedEvents = 0
    public private(set) var hasGap = false
    private var events: [NormalizedPrivilegedEvent] = []

    public init(maximumEvents: Int = 4_096, maximumEstimatedBytes: Int = 4 * 1_024 * 1_024, coalescingWindow: TimeInterval = 1) {
        self.maximumEvents = min(max(1, maximumEvents), 65_536)
        self.maximumEstimatedBytes = min(max(1_024, maximumEstimatedBytes), 64 * 1_024 * 1_024)
        self.coalescingWindow = min(max(0.01, coalescingWindow), 10)
    }

    public mutating func append(_ event: NormalizedPrivilegedEvent) -> EndpointBufferResult {
        if let last = events.last, canCoalesce(last, event) {
            events[events.count - 1] = NormalizedPrivilegedEvent(
                raw: event.raw,
                watchedRoot: event.watchedRoot,
                logicalDelta: last.logicalDelta + event.logicalDelta,
                allocatedDelta: last.allocatedDelta + event.allocatedDelta,
                coalescedCount: last.coalescedCount + event.coalescedCount,
                gapBefore: last.gapBefore || event.gapBefore,
                confidence: weakest(last.confidence, event.confidence),
                method: last.confidence == .exact && event.confidence == .exact ? "endpoint-security-file-process" : "endpoint-security-incomplete",
                limitations: Array(Set(last.limitations + event.limitations)).sorted()
            )
            return .coalesced
        }
        if events.count >= maximumEvents || estimatedBytes + estimate(event) > maximumEstimatedBytes {
            droppedEvents += 1
            hasGap = true
            return .dropped(total: droppedEvents)
        }
        events.append(event)
        return .accepted
    }

    public mutating func drain() -> [NormalizedPrivilegedEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }

    public var count: Int { events.count }
    private var estimatedBytes: Int { events.reduce(0) { $0 + estimate($1) } }

    private func estimate(_ event: NormalizedPrivilegedEvent) -> Int {
        320 + event.raw.path.utf8.count + (event.raw.destinationPath?.utf8.count ?? 0) + (event.raw.process.executablePath?.utf8.count ?? 0)
    }

    private func canCoalesce(_ left: NormalizedPrivilegedEvent, _ right: NormalizedPrivilegedEvent) -> Bool {
        guard [.writeClose, .writeSummary].contains(left.raw.operation),
              [.writeClose, .writeSummary].contains(right.raw.operation),
              left.raw.process == right.raw.process,
              left.raw.fileIdentity == right.raw.fileIdentity,
              left.raw.path == right.raw.path,
              left.raw.destinationPath == right.raw.destinationPath,
              left.watchedRoot == right.watchedRoot,
              !left.gapBefore, !right.gapBefore
        else { return false }
        return right.raw.observedAt.timeIntervalSince(left.raw.observedAt) >= 0
            && right.raw.observedAt.timeIntervalSince(left.raw.observedAt) <= coalescingWindow
    }

    private func weakest(_ left: EvidenceStoreEvent.Confidence, _ right: EvidenceStoreEvent.Confidence) -> EvidenceStoreEvent.Confidence {
        let order: [EvidenceStoreEvent.Confidence] = [.exact, .toolLinked, .inferred, .unknown]
        return (order.firstIndex(of: left) ?? 3) >= (order.firstIndex(of: right) ?? 3) ? left : right
    }
}
