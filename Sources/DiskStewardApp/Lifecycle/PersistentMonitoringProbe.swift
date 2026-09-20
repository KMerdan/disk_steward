import DiskStewardCore
import Foundation

/// Session-local capacity evidence. Never borrows file-detail timestamps or
/// aggregates deltas from unrelated mounted volumes.
struct ObservedVolume: Equatable, Sendable {
    let observationID: String
    let observedAt: Date?
    let identity: String?
    let volume: VolumeCapacity
    private(set) var comparison: VolumeComparison?

    init?(snapshot: StorageSnapshot, identity: String?) {
        guard let volume = selectedCapacityVolume(in: snapshot) else { return nil }
        self.volume = volume
        self.observationID = snapshot.snapshotID
        self.observedAt = Self.parseDate(snapshot.observedAt)
        self.identity = identity.flatMap { $0.isEmpty ? nil : $0 }
    }

    func comparing(after previous: ObservedVolume?) -> ObservedVolume {
        var result = self
        result.comparison = nil
        guard let previous, let identity, previous.identity == identity,
              volume.totalBytes > 0,
              previous.observationID != observationID,
              previous.volume.mountPath == volume.mountPath,
              previous.volume.totalBytes == volume.totalBytes,
              previous.volume.isInternal == volume.isInternal,
              previous.volume.isReadOnly == volume.isReadOnly,
              let start = previous.observedAt, let end = observedAt, end > start
        else { return result }
        result.comparison = VolumeComparison(
            observationID: observationID, baselineObservationID: previous.observationID,
            volumeIdentity: identity, mountPath: volume.mountPath,
            start: start, end: end, usedByteDelta: volume.usedBytes - previous.volume.usedBytes
        )
        return result
    }

    static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func name(for mountPath: String) -> String {
        mountPath == "/" ? "Macintosh HD" : URL(fileURLWithPath: mountPath).lastPathComponent
    }
}

/// The same bounded value is used for Recent change, notification text and the
/// one latest alert. Later samples cannot rewrite a previous alert's interval.
struct VolumeComparison: Equatable, Sendable {
    let observationID: String
    let baselineObservationID: String
    let volumeIdentity: String
    let mountPath: String
    let start: Date
    let end: Date
    let usedByteDelta: Int64

    var amountText: String {
        if usedByteDelta == 0 { return "No change" }
        let bytes = ByteCountFormatter.string(fromByteCount: abs(usedByteDelta), countStyle: .file)
        return (usedByteDelta > 0 ? "+" : "−") + bytes
    }

    var intervalText: String {
        // Include seconds and both dates: cross-midnight and multi-day gaps are
        // explicit, and rapid continuation samples don't appear simultaneous.
        "\(start.formatted(date: .abbreviated, time: .standard)) – \(end.formatted(date: .abbreviated, time: .standard))"
    }
}

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
    private(set) var capacity: ObservedVolume?

    init(
        observedAt: Date,
        snapshot: StorageSnapshot,
        detailedEvents: [EvidenceStoreEvent],
        growthReport: GrowthExplanationReport,
        evidenceLifecycle: EvidenceLifecycleStatus? = nil,
        needsScanContinuation: Bool = false,
        scanStalled: Bool = false,
        continuationSlices: Int = 0,
        volumeIdentity: String? = nil
    ) {
        self.observedAt = observedAt
        self.snapshot = snapshot
        self.detailedEvents = detailedEvents
        self.growthReport = growthReport
        self.evidenceLifecycle = evidenceLifecycle
        self.needsScanContinuation = needsScanContinuation
        self.scanStalled = scanStalled
        self.continuationSlices = continuationSlices
        self.capacity = ObservedVolume(snapshot: snapshot, identity: volumeIdentity)
    }

    func comparingCapacity(after previous: MonitoringObservation?) -> MonitoringObservation {
        var result = self
        result.capacity = capacity?.comparing(after: previous?.capacity)
        return result
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
        await store.updateStorageCap(retentionPolicy.maxDatabaseBytes)
        try await persistPendingChanges()
        try Task.checkCancellation()
        let publicationPermit = try inbox.publicationPermit()
        let storageLimitations = try await recoverStorageBeforeSampling(settings: settings, policy: retentionPolicy, now: now)
        try Task.checkCancellation()
        let (snapshot, volumeGrowth) = try volumeSampleSource(previousStorage)
        let scope = policy.scopeVersion(at: now)
        let generation: MetadataScanGeneration
        switch try await withStorageRecovery(policy: retentionPolicy, { try await store.beginOrResumeScanGeneration(scope: scope, at: now) }) {
        case .admitted(let value):
            generation = value
        case .refused(let refusal):
            return try await storageRefusedObservation(
                refusal, snapshot: snapshot, volumeGrowth: volumeGrowth, policy: policy,
                retentionPolicy: retentionPolicy, storageLimitations: storageLimitations, now: now
            )
        }
        try Task.checkCancellation()
        let durableEventGap = try await store.hasPendingReconciliation()
        try Task.checkCancellation()
        let slice = autoreleasepool {
            metadataScanner.scanSlice(policy: policy, generation: generation, at: now)
        }
        try await enforceResourceBudget(settings: settings, underLoad: true)
        try Task.checkCancellation()
        let sampleEventGap = durableEventGap
        var scanCommit: ScanGenerationCommitResult
        switch try await withStorageRecovery(policy: retentionPolicy, {
            try await store.recordScanSlice(
                snapshot: snapshot,
                slice: slice,
                scope: scope,
                trigger: hasSampledThisLaunch ? .scheduled : .startup,
                eventGap: sampleEventGap,
                publicationPermit: publicationPermit
            )
        }) {
        case .admitted(let commit):
            scanCommit = commit
        case .refused(let refusal):
            return try await storageRefusedObservation(
                refusal, snapshot: snapshot, volumeGrowth: volumeGrowth, policy: policy,
                retentionPolicy: retentionPolicy, storageLimitations: storageLimitations, now: now
            )
        }
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
        var continuationLimitations: [String] = []
        let continuationDeadline = ProcessInfo.processInfo.systemUptime + continuationBudget
        while scanCommit.observation == nil, scanCommit.generation.status == .active,
              continuationSlices < Self.maximumContinuationSlices,
              ProcessInfo.processInfo.systemUptime < continuationDeadline {
            try Task.checkCancellation()
            try await enforceResourceBudget(settings: settings, underLoad: true)
            try await persistPendingChanges()
            let permit = try inbox.publicationPermit()
            let before = scanCommit.generation
            let next = autoreleasepool {
                metadataScanner.scanSlice(policy: policy, generation: before, at: Date())
            }
            let progressed = next.generation.processedEntryCount > before.processedEntryCount
                || !next.entries.isEmpty || !next.directoryPasses.isEmpty
                || next.generation.status != before.status
            let continuationGap = try await store.hasPendingReconciliation()
            do {
                scanCommit = try await store.recordScanSlice(
                    snapshot: snapshot, slice: next, scope: scope, trigger: .scheduled,
                    eventGap: continuationGap, publicationPermit: permit
                )
            } catch let error where Self.storageRefusalReason(error) != nil {
                // Storage refused the next slice. The committed generation stays
                // active; the next sample's bounded recovery decides whether
                // retention can help. Never loop on the refusal here.
                let accounting = try await store.storageAccounting()
                continuationLimitations = Self.refusalLimitations(reason: Self.storageRefusalReason(error) ?? "storage", accounting: accounting, retentionAttempted: false)
                scanStalled = true
                break
            }
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
        let volumeDelta = selectedCapacityVolume(in: snapshot).flatMap { volumeGrowth.usedByteDeltas[$0.mountPath] } ?? 0
        var scanLimitations = scanCommit.generation.limitations
        if scanCommit.observation == nil, scanCommit.generation.status == .active {
            scanLimitations.append(
                "File-detail scan generation \(scanCommit.generation.generationID) is partial: \(scanCommit.generation.completedRootCount)/\(scanCommit.generation.rootPaths.count) roots complete and \(scanCommit.generation.processedEntryCount) entries processed."
            )
        }
        if scanStalled, continuationLimitations.isEmpty {
            scanLimitations.append(
                "File-detail scanning made no progress for \(Self.stalledSliceThreshold) consecutive slices; continuation backed off to the regular interval."
            )
        }
        scanLimitations.append(contentsOf: continuationLimitations)
        let report = explanationEngine.explain(
            volumeUsedDelta: volumeDelta,
            detailedEvents: events,
            eventGap: sampleEventGap,
            scopeLimitations: volumeGrowth.limitations + policy.scopeLimitations(at: now) + storageLimitations + scanLimitations
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
        try await enforceResourceBudget(settings: settings, underLoad: false)
        return MonitoringObservation(
            observedAt: now,
            snapshot: snapshot,
            detailedEvents: events,
            growthReport: report,
            evidenceLifecycle: evidenceLifecycle,
            needsScanContinuation: scanCommit.generation.status == .active,
            scanStalled: scanStalled,
            continuationSlices: continuationSlices,
            volumeIdentity: volumeGrowth.selectedVolumeIdentity
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
    /// The database dimension of the budget is judged on the store's own
    /// accounting (live pages, log and shared memory, never reusable free
    /// pages). When nothing evictable remains, the store refuses new work
    /// explicitly and volume sampling continues with the reason stated, so an
    /// over-cap store never turns into a repeating error.
    private func recoverStorageBeforeSampling(
        settings: MonitoringSettings,
        policy: EvidenceStoreRetentionPolicy,
        now: Date
    ) async throws -> [String] {
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
        }
        let accounting = try await store.storageAccounting()
        let measurement = resourceMeasurement(underLoad: false)
        let accounted = ResourceMeasurement(
            cpuPercent: measurement.cpuPercent, residentBytes: measurement.residentBytes,
            databaseBytes: accounting.committedBytes, pendingEvents: measurement.pendingEvents,
            receivedEvents: measurement.receivedEvents, droppedEvents: measurement.droppedEvents, underLoad: measurement.underLoad
        )
        switch accounting.admission {
        case .available:
            try enforce(accounted, settings: settings)
            return []
        case .retentionRequired, .capacityLimited, .walPinned, .diskSpaceLimited:
            try enforceNonDatabaseBudget(accounted, settings: settings)
            return accounting.limitations
        }
    }

    private enum StorageAdmitted<Value: Sendable>: Sendable {
        case admitted(Value)
        case refused(StorageRefusal)
    }

    struct StorageRefusal: Sendable {
        let reason: String
        let accounting: EvidenceStorageAccounting
        let retentionAttempted: Bool
        var limitations: [String] {
            PersistentMonitoringProbe.refusalLimitations(reason: reason, accounting: accounting, retentionAttempted: retentionAttempted)
        }
    }

    /// The store's typed refusals plus SQLite's own disk-full result.
    static func storageRefusalReason(_ error: Error) -> String? {
        switch error as? EvidenceStoreError {
        case .storageCapacityExceeded: return "capacity"
        case .storageHeadroomUnavailable(let reason, _, _): return reason
        case .sqlite(let code, _) where code == 13: return "disk-full"
        default: return nil
        }
    }

    /// The exact demand a refusal carried, so retention can target it without
    /// relying on store state that other writers may have moved on from.
    static func storageRefusalDemand(_ error: Error) -> Int64 {
        switch error as? EvidenceStoreError {
        case .storageHeadroomUnavailable(_, let demand, _): return demand
        case .storageCapacityExceeded(let current, let cap): return max(0, current - cap)
        default: return 0
        }
    }

    static func refusalLimitations(reason: String, accounting: EvidenceStorageAccounting, retentionAttempted: Bool) -> [String] {
        var limitations = ["Evidence storage refused new file detail (\(reason)); the scan generation stays where it committed and no evidence was lost."]
        limitations.append(contentsOf: accounting.limitations)
        if reason == "disk-full" {
            limitations.append("The volume holding the evidence database is full; the refused transaction was rolled back.")
        }
        if retentionAttempted {
            limitations.append("One bounded pressure retention run could not make enough room.")
        }
        return limitations
    }

    /// Storage refusals are recoverable work, never an error loop. When
    /// evictable history exists, one bounded pressure retention run is tried
    /// and the same work retried once; anything else becomes explicit
    /// non-progress on the observation.
    private func withStorageRecovery<Value: Sendable>(
        policy: EvidenceStoreRetentionPolicy,
        _ work: () async throws -> Value
    ) async throws -> StorageAdmitted<Value> {
        do {
            return .admitted(try await work())
        } catch let error where Self.storageRefusalReason(error) != nil {
            let reason = Self.storageRefusalReason(error) ?? "storage"
            let accounting = try await store.storageAccounting()
            guard accounting.evictableHistory, reason != "disk-full", reason != "disk-space", reason != "wal-pinned" else {
                return .refused(StorageRefusal(reason: reason, accounting: accounting, retentionAttempted: false))
            }
            _ = try await store.applyRetention(policy, trigger: .pressure, demandBytes: Self.storageRefusalDemand(error))
            lastRetentionAt = Date()
            try Task.checkCancellation()
            do {
                return .admitted(try await work())
            } catch let retried where Self.storageRefusalReason(retried) != nil {
                let after = try await store.storageAccounting()
                return .refused(StorageRefusal(reason: Self.storageRefusalReason(retried) ?? reason, accounting: after, retentionAttempted: true))
            }
        }
    }

    /// Explicit non-progress: the volume sample is reported with the storage
    /// reason, nothing is persisted, the active generation keeps its committed
    /// progress, and the scheduler backs off as for a stalled scan.
    private func storageRefusedObservation(
        _ refusal: StorageRefusal,
        snapshot: StorageSnapshot,
        volumeGrowth: VolumeGrowthSample,
        policy: MonitoringPolicy,
        retentionPolicy: EvidenceStoreRetentionPolicy,
        storageLimitations: [String],
        now: Date
    ) async throws -> MonitoringObservation {
        try Task.checkCancellation()
        let eventGap = try await store.hasPendingReconciliation()
        let volumeDelta = selectedCapacityVolume(in: snapshot).flatMap { volumeGrowth.usedByteDeltas[$0.mountPath] } ?? 0
        var limitations = volumeGrowth.limitations + policy.scopeLimitations(at: now) + storageLimitations
        for limitation in refusal.limitations where !limitations.contains(limitation) { limitations.append(limitation) }
        let report = explanationEngine.explain(
            volumeUsedDelta: volumeDelta, detailedEvents: [], eventGap: eventGap, scopeLimitations: limitations
        )
        let evidenceLifecycle = try await store.lifecycleStatus(retentionPolicy, at: now)
        let active = try await store.activeScanGeneration()
        try Task.checkCancellation()
        return MonitoringObservation(
            observedAt: now,
            snapshot: snapshot,
            detailedEvents: [],
            growthReport: report,
            evidenceLifecycle: evidenceLifecycle,
            needsScanContinuation: active?.status == .active,
            scanStalled: true,
            continuationSlices: 0,
            volumeIdentity: volumeGrowth.selectedVolumeIdentity
        )
    }

    /// Process limits come from the live measurement; the database dimension is
    /// judged on the store's own accounting (live pages, log and shared memory),
    /// exactly as before sampling. The raw file size also counts reusable free
    /// pages and a write-ahead log that grows transiently during every commit,
    /// so a store sitting near its cap would otherwise trip the breaker in the
    /// middle of each sample even though retention and admission keep it
    /// bounded. Storage pressure is admission's job, not the breaker's.
    private func enforceResourceBudget(settings: MonitoringSettings, underLoad: Bool) async throws {
        let measurement = resourceMeasurement(underLoad: underLoad)
        try enforceNonDatabaseBudget(measurement, settings: settings)
        let accounting = try await store.storageAccounting()
        guard accounting.admission == .available else { return }
        try enforce(ResourceMeasurement(
            cpuPercent: measurement.cpuPercent, residentBytes: measurement.residentBytes,
            databaseBytes: accounting.committedBytes, pendingEvents: measurement.pendingEvents,
            receivedEvents: measurement.receivedEvents, droppedEvents: measurement.droppedEvents, underLoad: measurement.underLoad
        ), settings: settings)
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
