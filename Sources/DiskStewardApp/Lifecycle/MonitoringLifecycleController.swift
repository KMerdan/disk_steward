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

@MainActor
final class MonitoringLifecycleController: ObservableObject {
    @Published private(set) var status: MonitoringStatus
    @Published private(set) var latestObservation: MonitoringObservation?
    @Published private(set) var history: [MonitoringStatus] = []

    private let settingsStore: MonitoringSettingsStore
    private let probe: MonitoringProbing
    private let notificationDelivery: MonitoringNotificationDelivering
    private let changeCollector: TargetedFSEventsCollector?
    private let safetyState: MonitoringSafetyStateStore
    private var notificationPolicy = ThresholdNotificationPolicy()
    private var loopTask: Task<Void, Never>?
    private var eventSampleTask: Task<Void, Never>?
    private var settingsSubscription: AnyCancellable?
    private var collectorLimitation: String?
    private var sampleInProgress = false
    private var sampleRequestedWhileBusy = false
    private var requiresRecoveryConfirmation: Bool
    private var suspendedForSystemSleep = false

    init(
        settingsStore: MonitoringSettingsStore,
        probe: MonitoringProbing,
        notificationDelivery: MonitoringNotificationDelivering = UserNotificationDelivery(),
        changeCollector: TargetedFSEventsCollector? = TargetedFSEventsCollector(),
        safetyState: MonitoringSafetyStateStore = MonitoringSafetyStateStore(),
        now: Date = Date()
    ) {
        self.settingsStore = settingsStore
        self.probe = probe
        self.notificationDelivery = notificationDelivery
        self.changeCollector = changeCollector
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
            changedAt: now
        )
        settingsSubscription = settingsStore.$settings.dropFirst().sink { [weak self] _ in
            self?.restartChangeCollector()
        }
    }

    deinit {
        loopTask?.cancel()
        eventSampleTask?.cancel()
        changeCollector?.stop()
    }

    func start() {
        guard !settingsStore.settings.monitoringPaused,
              !suspendedForSystemSleep,
              loopTask == nil
        else { return }
        restartChangeCollector()
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.sampleNow()
                let minutes = self.settingsStore.settings.sampleIntervalMinutes
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            }
        }
    }

    func pause() {
        loopTask?.cancel()
        loopTask = nil
        eventSampleTask?.cancel()
        eventSampleTask = nil
        changeCollector?.stop()
        settingsStore.update { $0.monitoringPaused = true }
        transition(.paused, title: "Paused", detail: "Disk sampling is paused by the user.")
    }

    func resume() {
        safetyState.acknowledgeInterruptedSample()
        requiresRecoveryConfirmation = false
        settingsStore.update { $0.monitoringPaused = false }
        transition(.active, title: "Starting", detail: "Preparing a fresh disk sample.")
        start()
    }

    func prepareForSystemSleep() {
        suspendedForSystemSleep = true
        loopTask?.cancel()
        loopTask = nil
        eventSampleTask?.cancel()
        eventSampleTask = nil
        changeCollector?.stop()
        guard !settingsStore.settings.monitoringPaused else { return }
        transition(
            .paused,
            title: "Sleeping",
            detail: "Disk sampling is suspended while this Mac sleeps. It will refresh after wake."
        )
    }

    func resumeAfterSystemWake() {
        suspendedForSystemSleep = false
        guard !settingsStore.settings.monitoringPaused else { return }
        transition(.active, title: "Waking", detail: "Refreshing disk evidence after system wake.")
        start()
    }

    func sampleNow() async {
        guard !settingsStore.settings.monitoringPaused else { return }
        guard !requiresRecoveryConfirmation else { return }
        guard !sampleInProgress else {
            sampleRequestedWhileBusy = true
            return
        }
        sampleInProgress = true
        safetyState.markSampleStarted()
        defer {
            safetyState.markSampleFinished()
            sampleInProgress = false
            if sampleRequestedWhileBusy, !settingsStore.settings.monitoringPaused {
                sampleRequestedWhileBusy = false
                Task { @MainActor [weak self] in await self?.sampleNow() }
            }
        }
        do {
            let observation = try await probe.sample(settings: settingsStore.settings)
            latestObservation = observation
            let recovering = status.kind == .degraded
            if let collectorLimitation {
                transition(.degraded, title: "Degraded", detail: "Scheduled sampling is active, but targeted change hints are unavailable: \(collectorLimitation)")
            } else {
                transition(
                    recovering ? .recovered : .active,
                    title: recovering ? "Recovered" : "Active",
                    detail: recovering ? "Disk sampling is healthy again after a degraded sample." : "Whole-volume and configured-root evidence is current."
                )
            }
            for notification in notificationPolicy.evaluate(observation: observation, settings: settingsStore.settings) {
                await notificationDelivery.deliver(notification)
            }
        } catch {
            transition(.degraded, title: "Degraded", detail: "Sampling failed: \(error.localizedDescription)")
        }
    }

    private func restartChangeCollector() {
        guard let changeCollector, !settingsStore.settings.monitoringPaused else { return }
        do {
            try changeCollector.restart(policy: settingsStore.settings.monitoringPolicy(at: Date())) { [weak self] batch in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if batch.eventGap { await self.probe.noteEventGap() }
                    self.eventSampleTask?.cancel()
                    self.eventSampleTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        await self?.sampleNow()
                    }
                }
            }
            collectorLimitation = nil
        } catch {
            collectorLimitation = error.localizedDescription
            transition(.degraded, title: "Degraded", detail: "Scheduled sampling remains available; targeted change hints failed: \(error.localizedDescription)")
        }
    }

    private func transition(_ kind: MonitoringStateKind, title: String, detail: String) {
        let next = MonitoringStatus(kind: kind, title: title, detail: detail, changedAt: Date())
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
