import Combine
import DiskStewardCore
import Foundation

enum MonitoringStateKind: String, Equatable, Sendable {
    case active
    case degraded
    case recovered
    case paused
}

struct UnavailableMonitoringProbe: MonitoringProbing {
    let reason: String

    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        throw NSError(domain: "DiskSteward.Monitoring", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }
}

struct MonitoringStatus: Equatable, Sendable {
    let kind: MonitoringStateKind
    let title: String
    let detail: String
    let changedAt: Date

    var accessibilitySummary: String { "Monitoring \(title.lowercased()). \(detail)" }
}

/// One clock boundary for scheduling, freshness transitions and shutdown tests.
/// The sleep implementation must respond to cancellation.
struct MonitoringLifecycleClock: Sendable {
    var now: @Sendable () -> Date
    var uptime: @Sendable () -> TimeInterval
    var sleep: @Sendable (TimeInterval) async throws -> Void

    static let live = MonitoringLifecycleClock(
        now: { Date() },
        uptime: { ProcessInfo.processInfo.systemUptime },
        sleep: { try await Task.sleep(for: .seconds($0)) }
    )
}

protocol MonitoringChangeCollecting: Sendable {
    func restart(policy: MonitoringPolicy, at date: Date, latency: TimeInterval, handler: @escaping TargetedFSEventsCollector.Handler) throws
    func stop()
}

extension TargetedFSEventsCollector: MonitoringChangeCollecting {}

@MainActor
final class MonitoringLifecycleController: ObservableObject {
    @Published private(set) var status: MonitoringStatus
    @Published private(set) var latestObservation: MonitoringObservation?
    @Published private(set) var history: [MonitoringStatus] = []
    @Published private(set) var isSampling = false
    /// One threshold event, not an unbounded history or a delivery receipt.
    /// Cleared on process restart; retained across pause and later small changes.
    @Published private(set) var latestGrowthAlert: VolumeComparison?
    private var needsCapacityBaseline = true

    private let settingsStore: MonitoringSettingsStore
    private let probe: MonitoringProbing
    private let notificationDelivery: MonitoringNotificationDelivering
    private let changeCollector: (any MonitoringChangeCollecting)?
    private let safetyState: MonitoringSafetyStateStore
    private let clock: MonitoringLifecycleClock
    private var notificationPolicy = ThresholdNotificationPolicy()
    private var loopTask: Task<Void, Never>?
    private var loopID: UUID?
    private var eventSampleTask: Task<Void, Never>?
    private var settingsResumeTask: Task<Void, Never>?
    private var settingsSubscription: AnyCancellable?
    private var collectorLimitation: String?
    private var sampleTask: Task<Void, Never>?
    private var receiptDrainTask: Task<Void, Never>?
    private var safetyWorkCount = 0
    private var sampleRequestedWhileBusy = false
    private var shutdownDrainTask: Task<Bool, Never>?
    private var shutdownTimeoutTask: Task<Void, Never>?
    private var shutdownContinuation: CheckedContinuation<Bool, Never>?
    private var requiresRecoveryConfirmation: Bool
    private var suspendedForSystemSleep = false
    private var startRequested = false
    private var stopped = false
    private var epoch: UInt64 = 0

    private var canSample: Bool {
        !stopped && !suspendedForSystemSleep && !settingsStore.settings.monitoringPaused && !requiresRecoveryConfirmation
    }

    var canRequestSample: Bool { canSample }

    init(
        settingsStore: MonitoringSettingsStore,
        probe: MonitoringProbing,
        notificationDelivery: MonitoringNotificationDelivering,
        changeCollector: (any MonitoringChangeCollecting)?,
        safetyState: MonitoringSafetyStateStore? = nil,
        now: Date? = nil,
        clock: MonitoringLifecycleClock = .live
    ) {
        self.settingsStore = settingsStore
        self.probe = probe
        self.notificationDelivery = notificationDelivery
        self.changeCollector = changeCollector
        self.clock = clock
        let safetyState = safetyState ?? MonitoringSafetyStateStore(persistence: settingsStore.persistence)
        self.safetyState = safetyState
        requiresRecoveryConfirmation = safetyState.hasInterruptedSample
        if requiresRecoveryConfirmation, !settingsStore.settings.monitoringPaused {
            settingsStore.update { $0.monitoringPaused = true }
        }
        let paused = settingsStore.settings.monitoringPaused
        status = MonitoringStatus(
            kind: requiresRecoveryConfirmation ? .degraded : (paused ? .paused : .active),
            title: requiresRecoveryConfirmation ? "Safety Pause" : (paused ? "Paused" : "Starting"),
            detail: requiresRecoveryConfirmation
                ? "The previous detailed sample did not finish. Monitoring is paused until you resume it. Retained evidence may be stale."
                : (paused ? "Disk sampling is paused by the user." : "Preparing the first disk sample."),
            changedAt: now ?? clock.now()
        )
        settingsSubscription = settingsStore.$settings.dropFirst().sink { [weak self] settings in
            guard let self, !self.stopped else { return }
            self.settingsResumeTask?.cancel()
            self.settingsResumeTask = nil
            self.epoch &+= 1
            self.needsCapacityBaseline = true
            self.sampleTask?.cancel()
            if settings.monitoringPaused {
                self.sampleRequestedWhileBusy = false
                self.loopTask?.cancel()
                self.loopTask = nil
                self.loopID = nil
                self.eventSampleTask?.cancel()
                self.eventSampleTask = nil
                if !self.requiresRecoveryConfirmation {
                    self.transition(.paused, title: "Paused", detail: "Disk sampling is paused by the user.")
                }
            }
            // @Published emits in willSet. Reading settingsStore here would
            // restart the previous scope, or even restart a paused collector.
            self.restartChangeCollector(settings: settings)
            if self.startRequested && !settings.monitoringPaused && self.loopTask == nil {
                let settingsEpoch = self.epoch
                self.settingsResumeTask = Task { [weak self] in
                    guard let self else { return }
                    defer {
                        if self.epoch == settingsEpoch { self.settingsResumeTask = nil }
                    }
                    // Wait until @Published has stored its new value. Explicit
                    // resume() may already have started the loop in the meantime.
                    guard !Task.isCancelled, self.epoch == settingsEpoch,
                          self.canSample, self.loopTask == nil else { return }
                    self.transition(.active, title: "Starting", detail: "Preparing a fresh disk sample.")
                    self.start()
                }
            }
        }
    }

    deinit {
        loopTask?.cancel()
        eventSampleTask?.cancel()
        settingsResumeTask?.cancel()
        sampleTask?.cancel()
        receiptDrainTask?.cancel()
        shutdownTimeoutTask?.cancel()
        changeCollector?.stop()
    }

    func start() {
        guard !stopped else { return }
        startRequested = true
        guard canSample,
              loopTask == nil
        else { return }
        restartChangeCollector()
        let id = UUID()
        loopID = id
        loopTask = Task { [weak self] in
            defer {
                // An old cancelled loop must never clear a replacement loop.
                if self?.loopID == id {
                    self?.loopTask = nil
                    self?.loopID = nil
                }
            }
            while let self, !Task.isCancelled, self.canSample {
                let started = self.clock.uptime()
                await self.sampleNow()
                guard !Task.isCancelled, self.canSample else { return }
                let minutes = self.settingsStore.settings.sampleIntervalMinutes
                let elapsed = max(0, self.clock.uptime() - started)
                // Unfinished detail resumes promptly; a stalled generation or a
                // degraded probe falls back to the configured interval.
                let continuing = self.latestObservation?.needsScanContinuation == true
                    && self.latestObservation?.scanStalled != true && self.status.kind != .degraded
                let delay = continuing ? min(5, max(0.5, elapsed)) : Double(minutes) * 60
                do { try await self.clock.sleep(delay) } catch { return }
            }
        }
    }

    func pause() {
        guard !stopped else { return }
        settingsResumeTask?.cancel()
        settingsResumeTask = nil
        epoch &+= 1
        sampleRequestedWhileBusy = false
        loopTask?.cancel()
        loopTask = nil
        loopID = nil
        eventSampleTask?.cancel()
        eventSampleTask = nil
        sampleTask?.cancel()
        stopChangeCollector()
        settingsStore.update { $0.monitoringPaused = true }
        transition(.paused, title: "Paused", detail: "Disk sampling is paused by the user.")
    }

    func resume() {
        guard !stopped else { return }
        if requiresRecoveryConfirmation {
            // Acknowledgement releases the previous launch's claim, not this
            // launch's sample/drain or receipts still awaiting durable storage.
            if safetyWorkCount == 0, probe.changeInbox?.hasPendingChanges != true {
                safetyState.acknowledgeInterruptedSample()
            }
            requiresRecoveryConfirmation = false
        }
        settingsStore.update { $0.monitoringPaused = false }
        guard !suspendedForSystemSleep else { return }
        transition(.active, title: "Starting", detail: "Preparing a fresh disk sample.")
        start()
    }

    func prepareForSystemSleep() {
        guard !stopped else { return }
        settingsResumeTask?.cancel()
        settingsResumeTask = nil
        epoch &+= 1
        needsCapacityBaseline = true
        sampleRequestedWhileBusy = false
        suspendedForSystemSleep = true
        loopTask?.cancel()
        loopTask = nil
        loopID = nil
        eventSampleTask?.cancel()
        eventSampleTask = nil
        sampleTask?.cancel()
        stopChangeCollector()
        guard !settingsStore.settings.monitoringPaused else { return }
        transition(
            .paused,
            title: "Sleeping",
            detail: "Disk sampling is suspended while this Mac sleeps. It will refresh after wake."
        )
    }

    func resumeAfterSystemWake() {
        guard !stopped else { return }
        suspendedForSystemSleep = false
        guard !settingsStore.settings.monitoringPaused else { return }
        transition(.active, title: "Waking", detail: "Refreshing disk evidence after system wake.")
        start()
    }

    func sampleNow() async {
        guard canSample, !Task.isCancelled else { return }
        guard sampleTask == nil else {
            sampleRequestedWhileBusy = true
            return
        }
        let task = launchSample()
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Synchronous UI entry: one owned sample and at most one coalesced request.
    /// No detached per-click tasks and no bypass of pause/sleep/quit fencing.
    func requestSample() {
        guard canSample else { return }
        if sampleTask != nil { sampleRequestedWhileBusy = true }
        else { launchSample() }
    }

    /// Every caller (timer, debounce or manual refresh) shares one owned task.
    /// Cancelling it stops new phases; already-submitted atomic store work may
    /// finish. The safety marker is released only after the probe returns.
    @discardableResult
    private func launchSample() -> Task<Void, Never> {
        let sampleEpoch = epoch
        let settings = settingsStore.settings
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSample(settings: settings, epoch: sampleEpoch)
            self.sampleTask = nil
            self.isSampling = false
            self.finishShutdownDrainIfIdle()
            if self.sampleRequestedWhileBusy, self.canSample {
                self.sampleRequestedWhileBusy = false
                self.launchSample()
            }
        }
        sampleTask = task
        isSampling = true
        return task
    }

    private func performSample(settings: MonitoringSettings, epoch sampleEpoch: UInt64) async {
        guard sampleEpoch == epoch, canSample, !Task.isCancelled else { return }
        beginSafetyWork()
        defer {
            endSafetyWork()
        }
        do {
            let sampled = try await probe.sample(settings: settings)
            guard sampleEpoch == epoch, canSample, !Task.isCancelled else { return }
            let observation = sampled.comparingCapacity(after: needsCapacityBaseline ? nil : latestObservation)
            needsCapacityBaseline = false
            latestObservation = observation
            let recovering = status.kind == .degraded
            if probe.changeInbox?.hasPendingChanges == true {
                transition(.degraded, title: "Reconciling", detail: "New file changes are awaiting durable reconciliation. Retained evidence may be older.")
            } else if let collectorLimitation {
                transition(.degraded, title: "Degraded", detail: "Scheduled sampling is active, but targeted change hints are unavailable: \(collectorLimitation)")
            } else if !observation.needsScanContinuation, let coverage = observation.evidenceLifecycle?.scanCoverage, coverage.detailCoverage != "complete" {
                transition(.degraded, title: "Partial coverage", detail: "Volume sampling finished, but some watched locations could not be fully observed. Last-known files remain uncertain, not deleted.")
            } else {
                transition(
                    recovering ? .recovered : .active,
                    title: recovering ? "Recovered" : "Active",
                    detail: observation.needsScanContinuation
                        ? "Volume capacity is current. File-detail scanning is still in progress; retained file evidence may be older."
                        : (recovering ? "Disk sampling is healthy again after a degraded sample." : "Volume sampling finished. Check file-detail coverage and observation times before using retained evidence.")
                )
            }
            // Capacity alerts describe the measured volume, not dirty file
            // attribution, so detail reconciliation does not consume/drop them.
            let notifications = notificationPolicy.evaluate(observation: observation, settings: settingsStore.settings)
            // Record before permission/delivery suspension: a threshold fact,
            // not a promise that macOS displayed it.
            if let comparison = notifications.compactMap(\.growthComparison).last { latestGrowthAlert = comparison }
            for notification in notifications {
                guard sampleEpoch == epoch, canSample, !Task.isCancelled else { return }
                await notificationDelivery.deliver(notification)
            }
        } catch {
            guard sampleEpoch == epoch, canSample, !Task.isCancelled else { return }
            needsCapacityBaseline = true
            transition(.degraded, title: "Degraded", detail: "Sampling failed: \(error.localizedDescription)")
        }
    }

    private func restartChangeCollector(settings incomingSettings: MonitoringSettings? = nil) {
        guard let changeCollector else { return }
        let settings = incomingSettings ?? settingsStore.settings
        guard !stopped, !suspendedForSystemSleep, !settings.monitoringPaused, !requiresRecoveryConfirmation
        else { stopChangeCollector(); return }
        let inbox = probe.changeInbox
        let now = clock.now()
        let policy = settings.monitoringPolicy(at: now)
        let streamID = inbox?.beginStream(rootPaths: policy.activeRoots(at: now).map(\.path), at: now)
        let receivedAt = clock.now
        do {
            try changeCollector.restart(policy: policy, at: now, latency: 0.2) { [weak self] batch in
                // Admission is synchronous on the native callback, before any
                // actor hop. One reserved wake replaces a task per batch.
                guard let inbox, let streamID,
                      inbox.receive(batch, stream: streamID, at: receivedAt()) else { return }
                Task { @MainActor [weak self] in
                    self?.startReceiptDrain()
                }
            }
            collectorLimitation = nil
        } catch {
            inbox?.endStream(at: clock.now())
            collectorLimitation = error.localizedDescription
            transition(.degraded, title: "Degraded", detail: "Scheduled sampling remains available; targeted change hints failed: \(error.localizedDescription)")
        }
        startReceiptDrain()
    }

    private func stopChangeCollector() {
        // Fence queued callbacks before stopping the OS stream. Its missing
        // history is represented explicitly, even while sampling stays paused.
        probe.changeInbox?.endStream(at: clock.now())
        changeCollector?.stop()
        startReceiptDrain()
    }

    private func startReceiptDrain() {
        guard receiptDrainTask == nil, let inbox = probe.changeInbox, inbox.hasPendingChanges else { return }
        inbox.reserveDrainWake()
        receiptDrainTask = Task { [weak self] in
            guard let self else { return }
            self.beginSafetyWork()
            defer {
                self.endSafetyWork()
                self.receiptDrainTask = nil
                self.finishShutdownDrainIfIdle()
            }
            while !Task.isCancelled {
                do {
                    try await self.probe.persistPendingChanges()
                    if inbox.releaseDrainWakeIfClean() {
                        self.scheduleEventSample()
                        return
                    }
                } catch {
                    if self.canSample {
                        self.transition(.degraded, title: "Reconciliation pending", detail: "File changes could not be recorded: \(error.localizedDescription). New detail publication is fenced until retry succeeds.")
                    }
                    // Quit does not loop forever or falsely clear the marker.
                    // A future launch establishes a fresh durable gap.
                    if self.stopped { return }
                }
                // Bound retries and let newer callbacks coalesce in one set.
                do { try await self.clock.sleep(1) } catch { return }
            }
        }
    }

    private func scheduleEventSample() {
        guard canSample else { return }
        eventSampleTask?.cancel()
        eventSampleTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(0.5) } catch { return }
            guard !Task.isCancelled, self.canSample else { return }
            await self.sampleNow()
        }
    }

    private func beginSafetyWork() {
        if safetyWorkCount == 0 { safetyState.markSampleStarted(at: clock.now()) }
        safetyWorkCount += 1
    }

    private func endSafetyWork() {
        safetyWorkCount -= 1
        if safetyWorkCount == 0, !requiresRecoveryConfirmation,
           probe.changeInbox?.hasPendingChanges != true {
            safetyState.markSampleFinished(at: clock.now())
        }
    }

    private func finishShutdownDrainIfIdle() {
        guard stopped, sampleTask == nil, receiptDrainTask == nil else { return }
        finishShutdownDrain(drained: probe.changeInbox?.hasPendingChanges != true)
    }

    func shutdown() {
        guard !stopped else { return }
        settingsResumeTask?.cancel()
        settingsResumeTask = nil
        stopped = true
        epoch &+= 1
        sampleRequestedWhileBusy = false
        loopTask?.cancel()
        loopTask = nil
        loopID = nil
        eventSampleTask?.cancel()
        eventSampleTask = nil
        sampleTask?.cancel()
        stopChangeCollector()
        // Do not clear an active marker just because Quit was requested. The
        // sample's completion owns it, including when a shutdown times out.
    }

    /// Returns false at the deadline if work still has not drained. It does not
    /// force a thread/transaction to stop or disguise an unfinished sample.
    func shutdownAndDrain(timeout: TimeInterval = 5) async -> Bool {
        shutdown()
        if let shutdownDrainTask { return await shutdownDrainTask.value }
        guard sampleTask != nil || receiptDrainTask != nil else { return probe.changeInbox?.hasPendingChanges != true }
        let task = Task { [weak self] in
            guard let self else { return true }
            guard self.sampleTask != nil || self.receiptDrainTask != nil else { return self.probe.changeInbox?.hasPendingChanges != true }
            return await withCheckedContinuation { continuation in
                self.shutdownContinuation = continuation
                self.shutdownTimeoutTask = Task { [weak self, clock = self.clock] in
                    do { try await clock.sleep(max(0, timeout)) } catch { return }
                    self?.finishShutdownDrain(drained: false)
                }
            }
        }
        shutdownDrainTask = task
        return await task.value
    }

    private func finishShutdownDrain(drained: Bool) {
        let continuation = shutdownContinuation
        shutdownContinuation = nil
        shutdownTimeoutTask?.cancel()
        shutdownTimeoutTask = nil
        continuation?.resume(returning: drained)
    }

    private func transition(_ kind: MonitoringStateKind, title: String, detail: String) {
        let next = MonitoringStatus(kind: kind, title: title, detail: detail, changedAt: clock.now())
        guard next.kind != status.kind || next.detail != status.detail else { return }
        status = next
        history.insert(next, at: 0)
        history = Array(history.prefix(20))
    }
}

struct MonitoringSafetyState: Codable, Equatable {
    var sampleInProgress = false
    var lastStartedAt: Date?
    var lastFinishedAt: Date?
}

final class MonitoringSafetyStateStore {
    private let persistence: SettingsPersisting
    private let key: String

    init(
        persistence: SettingsPersisting = UserDefaults.standard,
        key: String = "monitoring-safety-state-v1"
    ) {
        self.persistence = persistence
        self.key = key
    }

    var hasInterruptedSample: Bool { load().sampleInProgress }

    func markSampleStarted(at date: Date = Date()) {
        var state = load()
        state.sampleInProgress = true
        state.lastStartedAt = date
        save(state)
    }

    func markSampleFinished(at date: Date = Date()) {
        var state = load()
        state.sampleInProgress = false
        state.lastFinishedAt = date
        save(state)
    }

    func acknowledgeInterruptedSample() {
        var state = load()
        state.sampleInProgress = false
        save(state)
    }

    private func load() -> MonitoringSafetyState {
        guard let data = persistence.data(forKey: key),
              let state = try? JSONDecoder().decode(MonitoringSafetyState.self, from: data)
        else { return MonitoringSafetyState() }
        return state
    }

    private func save(_ state: MonitoringSafetyState) {
        persistence.set(try? JSONEncoder().encode(state), forKey: key)
    }
}
