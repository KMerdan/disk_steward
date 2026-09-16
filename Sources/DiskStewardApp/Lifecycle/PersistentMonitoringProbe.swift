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
    static let maximumEntriesPerSafetySlice = 512

    private let store: EvidenceStore
    private let databaseURL: URL
    private let resourceBudget: ResourceBudget
    private let resourceMeasurementSource: @Sendable (URL, Bool) -> ResourceMeasurement
    private let volumeSampler = WholeVolumeSampler()
    private let metadataScanner = DirectoryMetadataScanner()
    private let writeCoalescer = WriteCoalescer()
    private let explanationEngine = GrowthExplanationEngine()
    private var previousStorage: StorageSnapshot?
    private var pendingEventGap = false
    private var lastRetentionAt: Date?
    private var hasSampledThisLaunch = false
    private var isSampling = false
    private var resourceHistory = BoundedResourceHistory(capacity: 120)

    init(
        databaseURL: URL,
        resourceBudget: ResourceBudget = ResourceBudget(),
        resourceMeasurementSource: (@Sendable (URL, Bool) -> ResourceMeasurement)? = nil
    ) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.databaseURL = databaseURL
        self.resourceBudget = resourceBudget
        if let resourceMeasurementSource {
            self.resourceMeasurementSource = resourceMeasurementSource
        } else {
            let liveSource = LiveResourceMeasurementSource()
            self.resourceMeasurementSource = { liveSource.measure(databaseURL: $0, underLoad: $1) }
        }
        store = try EvidenceStore(url: databaseURL)
    }

    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        guard !isSampling else { throw MonitoringProbeSafetyError.sampleAlreadyRunning }
        isSampling = true
        defer { isSampling = false }

        let now = Date()
        let configuredPolicy = settings.monitoringPolicy(at: now)
        let policy = MonitoringPolicy(
            watchedRoots: configuredPolicy.watchedRoots,
            registeredRoots: configuredPolicy.registeredRoots,
            excludedRoots: configuredPolicy.excludedRoots,
            investigations: configuredPolicy.investigations,
            maximumEntries: min(configuredPolicy.maximumEntries, Self.maximumEntriesPerSafetySlice),
            maximumDepth: configuredPolicy.maximumDepth,
            coalescingWindow: configuredPolicy.coalescingWindow
        )
        try enforceResourceBudget(settings: settings, underLoad: false)
        let (snapshot, volumeGrowth) = try volumeSampler.sample(after: previousStorage)
        let scope = policy.scopeVersion(at: now)
        let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: now)
        let durableEventGap = try await store.hasPendingReconciliation()
        let slice = autoreleasepool {
            metadataScanner.scanSlice(policy: policy, generation: generation, at: now)
        }
        try enforceResourceBudget(settings: settings, underLoad: true)
        let scanCommit = try await store.recordScanSlice(
            snapshot: snapshot,
            slice: slice,
            scope: scope,
            trigger: hasSampledThisLaunch ? .scheduled : .startup,
            eventGap: pendingEventGap || durableEventGap
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
            eventGap: pendingEventGap || durableEventGap,
            scopeLimitations: volumeGrowth.limitations + policy.scopeLimitations(at: now) + scanLimitations
        )

        let retentionPolicy = try settings.retentionPolicy()
        let diagnostics = try await store.diagnostics()
        // Retention may remove unreferenced scope rows. A partial generation
        // still owns its scope and must finish or be abandoned first.
        if scanCommit.observation != nil, let trigger = RetentionSchedule().trigger(
            lastRunAt: lastRetentionAt,
            now: now,
            databaseBytes: diagnostics.storageBytes,
            capBytes: retentionPolicy.maxDatabaseBytes
        ) {
            _ = try await store.applyRetention(retentionPolicy, trigger: trigger)
            lastRetentionAt = now
        }
        let evidenceLifecycle = try await store.lifecycleStatus(retentionPolicy, at: now)
        try enforceResourceBudget(settings: settings, underLoad: false)
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

    func noteEventGap() async {
        pendingEventGap = true
        try? await store.recordReconciliationInvalidation()
    }

    func boundedResourceHistory() -> [ResourceMeasurement] {
        resourceHistory.samples
    }

    private func enforceResourceBudget(settings: MonitoringSettings, underLoad: Bool) throws {
        let measurement = resourceMeasurementSource(databaseURL, underLoad)
        resourceHistory.append(measurement)
        let configuredDatabaseBytes = Int64(settings.maxDatabaseMiB) * 1_024 * 1_024
        let effective = ResourceBudget(
            maximumIdleCPUPercent: resourceBudget.maximumIdleCPUPercent,
            maximumLoadCPUPercent: resourceBudget.maximumLoadCPUPercent,
            maximumResidentBytes: resourceBudget.maximumResidentBytes,
            maximumDatabaseBytes: min(resourceBudget.maximumDatabaseBytes, configuredDatabaseBytes),
            maximumPendingEvents: resourceBudget.maximumPendingEvents,
            maximumLossRatio: resourceBudget.maximumLossRatio
        )
        let assessment = ResourceBudgetEvaluator().assess(measurement, against: effective)
        if ResourceCircuitBreaker.mustStop(assessment) {
            throw MonitoringProbeSafetyError.resourceLimit(assessment.reasons)
        }
    }
}

enum MonitoringProbeSafetyError: LocalizedError {
    case sampleAlreadyRunning
    case resourceLimit([String])

    var errorDescription: String? {
        switch self {
        case .sampleAlreadyRunning:
            return "A detailed sample is already running; the duplicate request was coalesced."
        case let .resourceLimit(reasons):
            return "Detailed sampling stopped by the safety circuit breaker: \(reasons.joined(separator: " "))"
        }
    }
}
