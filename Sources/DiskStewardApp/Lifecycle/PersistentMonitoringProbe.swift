import DiskStewardCore
import Foundation

struct MonitoringObservation: Sendable {
    let observedAt: Date
    let snapshot: StorageSnapshot
    let detailedEvents: [EvidenceStoreEvent]
    let growthReport: GrowthExplanationReport
    let evidenceLifecycle: EvidenceLifecycleStatus?

    init(
        observedAt: Date,
        snapshot: StorageSnapshot,
        detailedEvents: [EvidenceStoreEvent],
        growthReport: GrowthExplanationReport,
        evidenceLifecycle: EvidenceLifecycleStatus? = nil
    ) {
        self.observedAt = observedAt
        self.snapshot = snapshot
        self.detailedEvents = detailedEvents
        self.growthReport = growthReport
        self.evidenceLifecycle = evidenceLifecycle
    }
}

struct RetentionSchedule: Sendable {
    static let maximumInterval: TimeInterval = 6 * 60 * 60

    func trigger(lastRunAt: Date?, now: Date, databaseBytes: Int64, capBytes: Int64) -> RetentionTrigger? {
        if lastRunAt == nil { return .startup }
        if databaseBytes >= (capBytes / 10) * 9 + (capBytes % 10) * 9 / 10 { return .pressure }
        if let lastRunAt, now.timeIntervalSince(lastRunAt) >= Self.maximumInterval { return .scheduled }
        return nil
    }
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
    private var pendingEventGap = false
    private var lastRetentionAt: Date?
    private var hasSampledThisLaunch = false

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        store = try EvidenceStore(url: databaseURL)
    }

    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        let now = Date()
        let policy = settings.monitoringPolicy(at: now)
        let (snapshot, volumeGrowth) = try volumeSampler.sample(after: previousStorage)
        let scope = policy.scopeVersion(at: now)
        let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: now)
        let slice = metadataScanner.scanSlice(policy: policy, generation: generation, at: now)
        let scanCommit = try await store.recordScanSlice(
            snapshot: snapshot,
            slice: slice,
            scope: scope,
            trigger: hasSampledThisLaunch ? .scheduled : .startup,
            eventGap: pendingEventGap
        )
        let events = writeCoalescer.coalesce(scanCommit.observation?.events ?? [], within: policy.coalescingWindow)
        let volumeDelta = volumeGrowth.usedByteDeltas.values.filter { $0 > 0 }.reduce(0, +)
        var scanLimitations = slice.generation.limitations
        if scanCommit.observation == nil, slice.generation.status == .active {
            scanLimitations.append(
                "File-detail scan generation \(slice.generation.generationID) is partial: \(slice.generation.completedRootCount)/\(slice.generation.rootPaths.count) roots complete and \(slice.generation.processedEntryCount) entries processed."
            )
        }
        let report = explanationEngine.explain(
            volumeUsedDelta: volumeDelta,
            detailedEvents: events,
            eventGap: pendingEventGap,
            scopeLimitations: volumeGrowth.limitations + policy.scopeLimitations(at: now) + scanLimitations
        )

        let retentionPolicy = try settings.retentionPolicy()
        let diagnostics = try await store.diagnostics()
        if let trigger = RetentionSchedule().trigger(
            lastRunAt: lastRetentionAt,
            now: now,
            databaseBytes: diagnostics.storageBytes,
            capBytes: retentionPolicy.maxDatabaseBytes
        ) {
            _ = try await store.applyRetention(retentionPolicy, trigger: trigger)
            lastRetentionAt = now
        }
        let evidenceLifecycle = try await store.lifecycleStatus(retentionPolicy, at: now)
        previousStorage = snapshot
        if scanCommit.observation != nil {
            hasSampledThisLaunch = true
            pendingEventGap = false
        }
        return MonitoringObservation(
            observedAt: now,
            snapshot: snapshot,
            detailedEvents: events,
            growthReport: report,
            evidenceLifecycle: evidenceLifecycle
        )
    }

    func noteEventGap() {
        pendingEventGap = true
    }
}
