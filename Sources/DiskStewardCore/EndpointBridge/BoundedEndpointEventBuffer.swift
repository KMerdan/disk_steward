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
    private var estimatedBytes = 0

    public init(maximumEvents: Int = 4_096, maximumEstimatedBytes: Int = 4 * 1_024 * 1_024, coalescingWindow: TimeInterval = 1) {
        self.maximumEvents = min(max(1, maximumEvents), 65_536)
        self.maximumEstimatedBytes = min(max(1_024, maximumEstimatedBytes), 64 * 1_024 * 1_024)
        self.coalescingWindow = min(max(0.01, coalescingWindow), 10)
    }

    public mutating func append(_ event: NormalizedPrivilegedEvent) -> EndpointBufferResult {
        if let last = events.last, canCoalesce(last, event) {
            let logical = last.logicalDelta.addingReportingOverflow(event.logicalDelta)
            let allocated = last.allocatedDelta.addingReportingOverflow(event.allocatedDelta)
            let count = last.coalescedCount.addingReportingOverflow(event.coalescedCount)
            guard !logical.overflow, !allocated.overflow, !count.overflow else { return recordDrop() }
            let replacement = NormalizedPrivilegedEvent(
                raw: event.raw,
                watchedRoot: event.watchedRoot,
                logicalDelta: logical.partialValue,
                allocatedDelta: allocated.partialValue,
                coalescedCount: count.partialValue,
                gapBefore: last.gapBefore || event.gapBefore,
                confidence: weakest(last.confidence, event.confidence),
                method: last.confidence == .exact && event.confidence == .exact ? "endpoint-security-file-process" : "endpoint-security-incomplete",
                limitations: Array(Set(last.limitations + event.limitations)).sorted()
            )
            let previousBytes = estimate(last)
            let replacementBytes = estimate(replacement)
            guard replacementBytes <= maximumEstimatedBytes - (estimatedBytes - previousBytes) else { return recordDrop() }
            estimatedBytes = estimatedBytes - previousBytes + replacementBytes
            events[events.count - 1] = replacement
            return .coalesced
        }
        let bytes = estimate(event)
        if events.count >= maximumEvents || bytes > maximumEstimatedBytes - estimatedBytes { return recordDrop() }
        events.append(event)
        estimatedBytes += bytes
        return .accepted
    }

    public mutating func drain() -> [NormalizedPrivilegedEvent] {
        defer { events.removeAll(keepingCapacity: true); estimatedBytes = 0 }
        return events
    }

    public var count: Int { events.count }

    private mutating func recordDrop() -> EndpointBufferResult {
        if droppedEvents < .max { droppedEvents += 1 }
        hasGap = true
        return .dropped(total: droppedEvents)
    }

    private func estimate(_ event: NormalizedPrivilegedEvent) -> Int {
        var bytes = event.raw.estimatedRetainedBytes
        for field in [event.watchedRoot, event.method] + event.limitations {
            let size = field.utf8.count.multipliedReportingOverflow(by: 2)
            let total = bytes.addingReportingOverflow(size.partialValue)
            if size.overflow || total.overflow { return .max }
            bytes = total.partialValue
        }
        return bytes
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
