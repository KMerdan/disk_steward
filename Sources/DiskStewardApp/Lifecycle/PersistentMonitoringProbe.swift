import DiskStewardCore
import Foundation

struct MonitoringObservation: Sendable {
    let observedAt: Date
    let snapshot: StorageSnapshot
    let detailedEvents: [EvidenceStoreEvent]
    let growthReport: GrowthExplanationReport
}

protocol MonitoringProbing: Sendable {
    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation
    func noteEventGap() async
}

extension MonitoringProbing {
    func noteEventGap() async {}
}

actor PersistentMonitoringProbe: MonitoringProbing {
    private let store: EvidenceStore
    private let volumeSampler = WholeVolumeSampler()
    private let metadataScanner = DirectoryMetadataScanner()
    private let writeCoalescer = WriteCoalescer()
    private let explanationEngine = GrowthExplanationEngine()
    private var previousStorage: StorageSnapshot?
    private var previousMetadata: MetadataSnapshot?
    private var pendingEventGap = false
    private var lastRetentionAt: Date?

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        store = try EvidenceStore(url: databaseURL)
    }

    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        let now = Date()
        let policy = settings.monitoringPolicy(at: now)
        let (snapshot, volumeGrowth) = try volumeSampler.sample(after: previousStorage)
        let metadata = metadataScanner.scan(policy: policy, at: now)
        let rawEvents = previousMetadata.map { metadataScanner.changes(from: $0, to: metadata) } ?? []
        let events = writeCoalescer.coalesce(rawEvents, within: policy.coalescingWindow)
        let volumeDelta = volumeGrowth.usedByteDeltas.values.filter { $0 > 0 }.reduce(0, +)
        let report = explanationEngine.explain(
            volumeUsedDelta: volumeDelta,
            detailedEvents: events,
            eventGap: pendingEventGap,
            scopeLimitations: volumeGrowth.limitations + metadata.limitations
        )

        try await store.recordSnapshot(snapshot, observedAt: now)
        if !events.isEmpty { try await store.insert(events) }
        if lastRetentionAt.map({ now.timeIntervalSince($0) >= 21_600 }) ?? true {
            _ = try await store.applyRetention(settings.retentionPolicy())
            lastRetentionAt = now
        }
        previousStorage = snapshot
        previousMetadata = metadata
        pendingEventGap = false
        return MonitoringObservation(
            observedAt: now,
            snapshot: snapshot,
            detailedEvents: events,
            growthReport: report
        )
    }

    func noteEventGap() {
        pendingEventGap = true
    }
}
