import DiskStewardCore
import Foundation

struct MonitoringObservation: Sendable {
    let observedAt: Date
    let snapshot: StorageSnapshot
    let detailedEvents: [EvidenceStoreEvent]
    let growthReport: GrowthExplanationReport
    let evidenceLifecycle: EvidenceLifecycleStatus?
    let needsScanContinuation: Bool
    /// Continuation slices stopped making progress; the scheduler backs off
    /// to its regular interval instead of spinning on a stalled generation.
    let scanStalled: Bool
    let continuationSlices: Int

    init(
        observedAt: Date,
        snapshot: StorageSnapshot,
        detailedEvents: [EvidenceStoreEvent],
        growthReport: GrowthExplanationReport,
        evidenceLifecycle: EvidenceLifecycleStatus? = nil,
        needsScanContinuation: Bool = false,
        scanStalled: Bool = false,
        continuationSlices: Int = 0
    ) {
        self.observedAt = observedAt
        self.snapshot = snapshot
        self.detailedEvents = detailedEvents
        self.growthReport = growthReport
        self.evidenceLifecycle = evidenceLifecycle
        self.needsScanContinuation = needsScanContinuation
        self.scanStalled = scanStalled
        self.continuationSlices = continuationSlices
    }
}

struct RetentionSchedule: Sendable {
    static let maximumInterval: TimeInterval = 6 * 60 * 60

    func trigger(lastRunAt: Date?, now: Date, databaseBytes: Int64, capBytes: Int64) -> RetentionTrigger? {
        if lastRunAt == nil { return .startup }
        if databaseBytes >= (capBytes / 10) * 9 + (capBytes % 10) * 9 / 10,
           lastRunAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true { return .pressure }
        if let lastRunAt, now.timeIntervalSince(lastRunAt) >= Self.maximumInterval { return .scheduled }
        return nil
    }
}

protocol MonitoringProbing: Sendable {
    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation
    var changeInbox: MonitoringChangeInbox? { get }
    func persistPendingChanges() async throws
}

extension MonitoringProbing {
    var changeInbox: MonitoringChangeInbox? { nil }
    func persistPendingChanges() async throws {}
}

/// Callback-safe cumulative receipt state. Never retains a native batch or
/// creates a task. Its one wake reservation belongs to the controller's drain.
final class MonitoringChangeInbox: @unchecked Sendable {
    struct Receipt: Sendable {
        let revision: UUID
        let rootPaths: [String]
        let receivedAt: Date
    }

    static let maximumRoots = 64
    private let lock = NSLock()
    private let fence = ScanPublicationFence()
    private var streamID: UUID?
    private var streamRoots: [String]?
    private var pending: Receipt?
    private var wakeReserved = false

    init(at date: Date = Date()) {
        // A SinceNow stream cannot prove what changed while this process was
        // absent, including a crash before a volatile receipt reached SQLite.
        pending = Receipt(revision: fence.invalidate(), rootPaths: ["*"], receivedAt: date)
    }

    var hasPendingChanges: Bool { lock.withLock { pending != nil } }
    func snapshot() -> Receipt? { lock.withLock { pending } }
    func publicationPermit() throws -> ScanPublicationPermit { try fence.permit() }

    func beginStream(rootPaths: [String], at date: Date) -> UUID {
        lock.withLock {
            let id = UUID()
            streamID = id
            if rootPaths.count <= Self.maximumRoots, rootPaths.allSatisfy(Self.isBoundedAbsolutePath) {
                streamRoots = Array(Set(rootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
            } else {
                // Do not retain an unbounded second copy of configured roots.
                streamRoots = nil
            }
            recordLocked(roots: ["*"], at: date)
            return id
        }
    }

    func endStream(at date: Date) {
        lock.withLock {
            guard streamID != nil else { return }
            streamID = nil
            streamRoots = nil
            recordLocked(roots: ["*"], at: date)
        }
    }

    /// Returns true only for the first required wake, not once per batch.
    func receive(_ batch: TargetedChangeBatch, stream id: UUID, at date: Date) -> Bool {
        lock.withLock {
            guard id == streamID else { return false }
            guard batch.eventGap || !batch.hints.isEmpty else { return false }
            var roots: Set<String> = []
            if batch.eventGap || batch.hints.count > 256 || streamRoots == nil {
                roots = ["*"]
            } else if let streamRoots {
                for hint in batch.hints {
                    guard Self.isBoundedAbsolutePath(hint.path) else { roots = ["*"]; break }
                    let path = URL(fileURLWithPath: hint.path).standardizedFileURL.path
                    for root in streamRoots where Self.contains(path, root: root) || Self.contains(root, root: path) {
                        roots.insert(root)
                    }
                }
            }
            guard !roots.isEmpty else { return false }
            recordLocked(roots: roots, at: date)
            return reserveWakeLocked()
        }
    }

    /// Snapshot contents remain cumulative when another receipt arrives while
    /// persistence awaits. An old completion cannot acknowledge the newer set.
    @discardableResult
    func acknowledge(_ receipt: Receipt) -> Bool {
        lock.withLock {
            guard pending?.revision == receipt.revision, fence.acknowledge(receipt.revision) else { return false }
            pending = nil
            return true
        }
    }

    @discardableResult
    func reserveDrainWake() -> Bool { lock.withLock { reserveWakeLocked() } }

    func releaseDrainWakeIfClean() -> Bool {
        lock.withLock {
            guard pending == nil else { return false }
            wakeReserved = false
            return true
        }
    }

    private func recordLocked(roots: Set<String>, at date: Date) {
        var combined = Set(pending?.rootPaths ?? [])
        combined.formUnion(roots)
        if combined.contains("*") || combined.count > Self.maximumRoots { combined = ["*"] }
        pending = Receipt(revision: fence.invalidate(), rootPaths: combined.sorted(),
                          receivedAt: min(pending?.receivedAt ?? date, date))
    }

    private func reserveWakeLocked() -> Bool {
        guard pending != nil, !wakeReserved else { return false }
        wakeReserved = true
        return true
    }

    private static func isBoundedAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf16.prefix(4_097).count <= 4_096
    }

    private static func contains(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

actor PersistentMonitoringProbe: MonitoringProbing {
    static let maximumEntriesPerSafetySlice = 512
    /// Unfinished detail continues in bounded slices inside one sample until
    /// this much scan work has been done, the generation completes, or
    /// progress stalls. Volume sampling runs once per sample regardless.
    static let defaultContinuationBudget: TimeInterval = 2.0
    static let maximumContinuationSlices = 256
    static let stalledSliceThreshold = 3

    private let store: EvidenceStore
    private let databaseURL: URL
    private let resourceBudget: ResourceBudget
    private let resourceMeasurementSource: @Sendable (URL, Bool) -> ResourceMeasurement
    private let volumeSampleSource: @Sendable (StorageSnapshot?) throws -> (StorageSnapshot, VolumeGrowthSample)
    private let afterScanCommit: @Sendable () -> Void
    private let continuationBudget: TimeInterval
    private let metadataScanner = DirectoryMetadataScanner()
    private let writeCoalescer = WriteCoalescer()
    private let explanationEngine = GrowthExplanationEngine()
    private nonisolated let inbox = MonitoringChangeInbox()
    nonisolated var changeInbox: MonitoringChangeInbox? { inbox }
    private var persistenceTask: Task<Void, Error>?
    private var previousStorage: StorageSnapshot?
    private var lastRetentionAt: Date?
    private var hasSampledThisLaunch = false
    private var isSampling = false
    private var resourceHistory = BoundedResourceHistory(capacity: 120)

    init(
        databaseURL: URL,
        evidenceStore: EvidenceStore? = nil,
        resourceBudget: ResourceBudget = ResourceBudget(),
        resourceMeasurementSource: (@Sendable (URL, Bool) -> ResourceMeasurement)? = nil,
        volumeSampleSource: @escaping @Sendable (StorageSnapshot?) throws -> (StorageSnapshot, VolumeGrowthSample) = { try WholeVolumeSampler().sample(after: $0) },
        afterScanCommit: @escaping @Sendable () -> Void = {},
        continuationBudget: TimeInterval = PersistentMonitoringProbe.defaultContinuationBudget
    ) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.databaseURL = databaseURL
        self.resourceBudget = resourceBudget
        self.volumeSampleSource = volumeSampleSource
        self.afterScanCommit = afterScanCommit
        self.continuationBudget = max(0, continuationBudget)
        if let resourceMeasurementSource {
            self.resourceMeasurementSource = resourceMeasurementSource
        } else {
            let liveSource = LiveResourceMeasurementSource()
            self.resourceMeasurementSource = { liveSource.measure(databaseURL: $0, underLoad: $1) }
        }
        store = try evidenceStore ?? EvidenceStore(url: databaseURL)
    }

    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        try Task.checkCancellation()
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
        let retentionPolicy = try settings.retentionPolicy()
        try await persistPendingChanges()
        try Task.checkCancellation()
        let publicationPermit = try inbox.publicationPermit()
        try await recoverStorageBeforeSampling(settings: settings, policy: retentionPolicy, now: now)
        try Task.checkCancellation()
        let (snapshot, volumeGrowth) = try volumeSampleSource(previousStorage)
        let scope = policy.scopeVersion(at: now)
        let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: now)
        try Task.checkCancellation()
        let durableEventGap = try await store.hasPendingReconciliation()
        try Task.checkCancellation()
        let slice = autoreleasepool {
            metadataScanner.scanSlice(policy: policy, generation: generation, at: now)
        }
        try enforceResourceBudget(settings: settings, underLoad: true)
        try Task.checkCancellation()
        let sampleEventGap = durableEventGap
        var scanCommit = try await store.recordScanSlice(
            snapshot: snapshot,
            slice: slice,
            scope: scope,
            trigger: hasSampledThisLaunch ? .scheduled : .startup,
            eventGap: sampleEventGap,
            publicationPermit: publicationPermit
        )
        // A returned commit is durable even if cancellation arrives before UI
        // publication. Preserve its baseline before any further suspension or
        // cancellation check, so the next volume/detail interval stays aligned.
        previousStorage = snapshot
        if scanCommit.observation != nil {
            hasSampledThisLaunch = true
        }
        afterScanCommit()
        // Budgeted continuation: unfinished detail keeps advancing in bounded,
        // separately committed slices without another volume sample or a
        // scheduler round trip. Each slice re-checks cancellation, the resource
        // budget and the dirty-evidence fence, and a stall ends the loop.
        var continuationSlices = 0
        var stalledSlices = 0
        var scanStalled = false
        let continuationDeadline = ProcessInfo.processInfo.systemUptime + continuationBudget
        while scanCommit.observation == nil, scanCommit.generation.status == .active,
              continuationSlices < Self.maximumContinuationSlices,
              ProcessInfo.processInfo.systemUptime < continuationDeadline {
            try Task.checkCancellation()
            try enforceResourceBudget(settings: settings, underLoad: true)
            try await persistPendingChanges()
            let permit = try inbox.publicationPermit()
            let before = scanCommit.generation
            let next = autoreleasepool {
                metadataScanner.scanSlice(policy: policy, generation: before, at: Date())
            }
            let progressed = next.generation.processedEntryCount > before.processedEntryCount
                || !next.entries.isEmpty || !next.directoryPasses.isEmpty
                || next.generation.status != before.status
            scanCommit = try await store.recordScanSlice(
                snapshot: snapshot, slice: next, scope: scope, trigger: .scheduled,
                eventGap: try await store.hasPendingReconciliation(), publicationPermit: permit
            )
            continuationSlices += 1
            if scanCommit.observation != nil { hasSampledThisLaunch = true }
            afterScanCommit()
            if progressed {
                stalledSlices = 0
            } else {
                stalledSlices += 1
                if stalledSlices >= Self.stalledSliceThreshold { scanStalled = true; break }
            }
        }
        // Submitted store transactions are atomic and may finish on cancellation.
        // Do not start subsequent maintenance or publish UI after a stop.
        try Task.checkCancellation()
        let events = writeCoalescer.coalesce(scanCommit.observation?.events ?? [], within: policy.coalescingWindow)
        let volumeDelta = volumeGrowth.usedByteDeltas.values.filter { $0 > 0 }.reduce(0, +)
        var scanLimitations = scanCommit.generation.limitations
        if scanCommit.observation == nil, scanCommit.generation.status == .active {
            scanLimitations.append(
                "File-detail scan generation \(scanCommit.generation.generationID) is partial: \(scanCommit.generation.completedRootCount)/\(scanCommit.generation.rootPaths.count) roots complete and \(scanCommit.generation.processedEntryCount) entries processed."
            )
        }
        if scanStalled {
            scanLimitations.append(
                "File-detail scanning made no progress for \(Self.stalledSliceThreshold) consecutive slices; continuation backed off to the regular interval."
            )
        }
        let report = explanationEngine.explain(
            volumeUsedDelta: volumeDelta,
            detailedEvents: events,
            eventGap: sampleEventGap,
            scopeLimitations: volumeGrowth.limitations + policy.scopeLimitations(at: now) + scanLimitations
        )

        let diagnostics = try await store.diagnostics()
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        let evidenceLifecycle = try await store.lifecycleStatus(retentionPolicy, at: now)
        try Task.checkCancellation()
        try enforceResourceBudget(settings: settings, underLoad: false)
        return MonitoringObservation(
            observedAt: now,
            snapshot: snapshot,
            detailedEvents: events,
            growthReport: report,
            evidenceLifecycle: evidenceLifecycle,
            needsScanContinuation: scanCommit.generation.status == .active,
            scanStalled: scanStalled,
            continuationSlices: continuationSlices
        )
    }

    func persistPendingChanges() async throws {
        if let persistenceTask { return try await persistenceTask.value }
        guard let receipt = inbox.snapshot() else { return }
        // One owner per probe, shared by sampling and the lifecycle drain.
        // Cancelling a sample must not orphan an accepted persistence attempt.
        let task = Task { [store, inbox] in
            for root in receipt.rootPaths {
                try await store.recordReconciliationInvalidation(
                    rootPath: root, reason: root == "*" ? "event-drop" : "file-change", at: receipt.receivedAt
                )
            }
            inbox.acknowledge(receipt)
        }
        persistenceTask = task
        defer { persistenceTask = nil }
        try await task.value
    }

    func boundedResourceHistory() -> [ResourceMeasurement] {
        resourceHistory.samples
    }

    /// Storage pressure is recoverable work, unlike memory or queue pressure.
    /// Run retention before the database circuit breaker so an over-budget
    /// legacy store cannot permanently lock itself out of its own cleanup path.
    private func recoverStorageBeforeSampling(
        settings: MonitoringSettings,
        policy: EvidenceStoreRetentionPolicy,
        now: Date
    ) async throws {
        let initial = resourceMeasurement(underLoad: false)
        try enforceNonDatabaseBudget(initial, settings: settings)

        let diagnostics = try await store.diagnostics()
        try Task.checkCancellation()
        let observedStorage = max(initial.databaseBytes, diagnostics.storageBytes)
        if let trigger = RetentionSchedule().trigger(
            lastRunAt: lastRetentionAt,
            now: now,
            databaseBytes: observedStorage,
            capBytes: policy.maxDatabaseBytes
        ) {
            _ = try await store.applyRetention(policy, trigger: trigger)
            lastRetentionAt = now
            try Task.checkCancellation()
            try enforceResourceBudget(settings: settings, underLoad: false)
        } else {
            try enforce(initial, settings: settings)
        }
    }

    private func enforceResourceBudget(settings: MonitoringSettings, underLoad: Bool) throws {
        try enforce(resourceMeasurement(underLoad: underLoad), settings: settings)
    }

    private func resourceMeasurement(underLoad: Bool) -> ResourceMeasurement {
        let measurement = resourceMeasurementSource(databaseURL, underLoad)
        resourceHistory.append(measurement)
        return measurement
    }

    private func enforceNonDatabaseBudget(_ measurement: ResourceMeasurement, settings: MonitoringSettings) throws {
        let withoutDatabasePressure = ResourceMeasurement(
            cpuPercent: measurement.cpuPercent,
            residentBytes: measurement.residentBytes,
            databaseBytes: 0,
            pendingEvents: measurement.pendingEvents,
            receivedEvents: measurement.receivedEvents,
            droppedEvents: measurement.droppedEvents,
            underLoad: measurement.underLoad
        )
        try enforce(withoutDatabasePressure, settings: settings)
    }

    private func enforce(_ measurement: ResourceMeasurement, settings: MonitoringSettings) throws {
        let configuredDatabaseBytes = Int64(settings.maxDatabaseMiB) * 1_024 * 1_024
        let effective = ResourceBudget(
            maximumIdleCPUPercent: resourceBudget.maximumIdleCPUPercent,
            maximumLoadCPUPercent: resourceBudget.maximumLoadCPUPercent,
            maximumResidentBytes: resourceBudget.maximumResidentBytes,
            // The persisted retention setting is the single source of truth for
            // live-store capacity. ResourceBudget still owns process limits.
            maximumDatabaseBytes: configuredDatabaseBytes,
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
