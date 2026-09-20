import Combine
import DiskStewardCore
import Foundation

enum StatusBoardPresentationState: String, CaseIterable, Equatable, Sendable {
    case active
    case paused
    case degraded
    case noBaseline = "no-baseline"
    case error
}

enum StatusBoardPrimaryAction: String, Equatable, Sendable {
    case pause
    case resume
    case refresh
    case retry
    case settings
}

struct StatusBoardPresentation: Equatable, Sendable {
    let state: StatusBoardPresentationState
    let title: String
    let detail: String
    let symbol: String
    let action: StatusBoardPrimaryAction
    let actionTitle: String

    var accessibilitySummary: String { "\(title). \(detail). Available action: \(actionTitle)." }

    static func derive(
        hasSnapshot: Bool,
        snapshotError: String?,
        monitoring: MonitoringStatus,
        hasGrowthBaseline: Bool
    ) -> StatusBoardPresentation {
        if !hasSnapshot, let snapshotError {
            return .init(
                state: .error,
                title: "Storage unavailable",
                detail: snapshotError,
                symbol: "xmark.octagon.fill",
                action: .retry,
                actionTitle: "Retry"
            )
        }
        if hasSnapshot, !hasGrowthBaseline, monitoring.kind == .active || monitoring.kind == .recovered {
            return .init(
                state: .noBaseline,
                title: "Building a baseline",
                detail: "Capacity is available. Growth needs a second comparable capacity sample, not a completed file scan.",
                symbol: "clock.badge.questionmark",
                action: .refresh,
                actionTitle: "Refresh"
            )
        }
        switch monitoring.kind {
        case .paused:
            return .init(
                state: .paused,
                title: "Monitoring paused",
                detail: "Stored evidence remains available. No new samples are expected.",
                symbol: "pause.circle.fill",
                action: .resume,
                actionTitle: "Resume"
            )
        case .degraded:
            return .init(
                state: .degraded,
                title: "Monitoring needs attention",
                detail: monitoring.detail,
                symbol: "exclamationmark.triangle.fill",
                action: .settings,
                actionTitle: "Settings…"
            )
        case .active, .recovered:
            return .init(
                state: .active,
                title: monitoring.kind == .recovered ? "Monitoring recovered" : "Monitoring active",
                detail: monitoring.detail,
                symbol: monitoring.kind == .recovered ? "arrow.clockwise.circle.fill" : "checkmark.circle.fill",
                action: .pause,
                actionTitle: "Pause"
            )
        }
    }
}

enum StatusBoardCapacityHealth: String, Equatable, Sendable {
    case healthy = "Healthy"
    case attention = "Getting Full"
    case critical = "Low Space"
    case unavailable = "Unavailable"
}

@MainActor
final class StatusBoardViewModel: ObservableObject {
    typealias SnapshotLoader = () throws -> StorageSnapshot
    typealias Exporter = (StorageSnapshot, URL) throws -> SnapshotExportResult
    typealias EvidenceExporter = @Sendable (URL) async throws -> EvidenceBundleExportResult

    @Published private(set) var observation: MonitoringObservation?
    @Published private var standaloneSnapshot: StorageSnapshot?
    @Published private var standaloneError: String?
    @Published private(set) var exportMessage: String?
    @Published private(set) var isExporting = false

    private let snapshotLoader: SnapshotLoader
    private let exporter: Exporter
    private let evidenceExporter: EvidenceExporter?
    private let exportParent: () -> URL
    private let exportCompletion: (URL) -> Void
    private let usesMonitoring: Bool
    private var observationSubscription: AnyCancellable?
    let lifecycle: MonitoringLifecycleController

    init(
        snapshotLoader: @escaping SnapshotLoader = { try VolumeSnapshotService().capture() },
        exporter: @escaping Exporter = { try SnapshotExporter().export($0, to: $1) },
        evidenceExporter: EvidenceExporter? = nil,
        exportParent: @escaping () -> URL = StatusBoardViewModel.defaultExportParent,
        exportCompletion: @escaping (URL) -> Void = { _ in },
        lifecycle: MonitoringLifecycleController? = nil
    ) {
        self.snapshotLoader = snapshotLoader
        self.exporter = exporter
        self.evidenceExporter = evidenceExporter
        self.exportParent = exportParent
        self.exportCompletion = exportCompletion
        self.usesMonitoring = lifecycle != nil
        self.lifecycle = lifecycle ?? MonitoringLifecycleController(
            settingsStore: MonitoringSettingsStore(persistence: EphemeralSettingsPersistence()),
            probe: UnavailableMonitoringProbe(reason: "Background monitoring is not attached to this view model."),
            notificationDelivery: DisabledNotificationDelivery(),
            changeCollector: nil
        )
        observationSubscription = self.lifecycle.$latestObservation.sink { [weak self] observation in
            // Receive the new value, not the publisher's willSet-era old value.
            // Capacity, comparison and timestamp now move together.
            self?.observation = observation
        }
    }

    var snapshot: StorageSnapshot? { observation?.snapshot ?? standaloneSnapshot }
    var errorMessage: String? {
        if usesMonitoring, observation == nil, lifecycle.status.kind == .degraded, lifecycle.canRequestSample { return lifecycle.status.detail }
        return standaloneError
    }
    var primaryVolume: VolumeCapacity? { snapshot.flatMap(selectedCapacityVolume) }
    var growthDelta: Int64? { observation?.capacity?.comparison?.usedByteDelta }

    var usedFraction: Double {
        guard let volume = primaryVolume, volume.totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(volume.usedBytes) / Double(volume.totalBytes)))
    }

    var capacitySummary: String {
        guard let volume = primaryVolume else { return "Capacity unavailable" }
        return "\(Self.byteCount(volume.usedBytes)) used of \(Self.byteCount(volume.totalBytes))"
    }

    var availableSummary: String {
        guard let volume = primaryVolume else { return "Capacity unavailable" }
        return "\(Self.byteCount(volume.availableBytes)) free"
    }

    var volumeName: String {
        guard let path = primaryVolume?.mountPath else { return "Startup disk" }
        return path == "/" ? "Macintosh HD" : URL(fileURLWithPath: path).lastPathComponent
    }

    var capacityHealth: StatusBoardCapacityHealth {
        guard let volume = primaryVolume, volume.totalBytes > 0 else { return .unavailable }
        let free = Double(volume.availableBytes) / Double(volume.totalBytes)
        if free < 0.10 { return .critical }
        if free < 0.20 { return .attention }
        return .healthy
    }

    func refresh() {
        if usesMonitoring {
            lifecycle.requestSample()
            return
        }
        do {
            standaloneSnapshot = try snapshotLoader()
            standaloneError = nil
        } catch {
            standaloneSnapshot = nil
            standaloneError = error.localizedDescription
        }
    }

    func prepareIfNeeded() {
        if snapshot == nil && !lifecycle.isSampling && errorMessage == nil { refresh() }
    }

    var growthSummary: String {
        observation?.capacity?.comparison?.amountText ?? "Awaiting growth baseline"
    }

    var growthDetail: String {
        if let comparison = observation?.capacity?.comparison { return comparison.intervalText }
        if let capacity = observation?.capacity, capacity.identity == nil { return "Volume identity unavailable; growth is unknown" }
        return "Needs another comparable capacity sample"
    }

    var capacityFreshnessSummary: String {
        guard let date = observation?.capacity?.observedAt ?? snapshot.flatMap({ Self.parseTimestamp($0.observedAt) })
        else { return "Capacity not yet sampled" }
        return "Capacity sampled \(date.formatted(date: .abbreviated, time: .standard))"
    }

    var sampleStateSummary: String {
        if lifecycle.status.kind == .paused { return "Paused · showing the last sample" }
        if !lifecycle.canRequestSample { return "Sampling stopped · showing the last sample" }
        if lifecycle.isSampling { return "Sampling… · showing the last completed capacity sample" }
        if lifecycle.status.kind == .degraded { return "Needs attention · values may be stale" }
        return "Last successful capacity sample"
    }

    var presentation: StatusBoardPresentation {
        StatusBoardPresentation.derive(
            hasSnapshot: primaryVolume != nil,
            snapshotError: errorMessage,
            monitoring: lifecycle.status,
            hasGrowthBaseline: observation?.capacity?.comparison != nil
        )
    }

    var evidenceFreshnessSummary: String {
        guard let date = observation?.evidenceLifecycle?.scanCoverage?.lastCompleteGenerationAt
        else { return "File detail: no complete scan recorded" }
        return "Last complete file scan \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    var evidenceStorageSummary: String {
        guard let lifecycle = lifecycle.latestObservation?.evidenceLifecycle else {
            return "Evidence storage pending"
        }
        return "Database \(Self.byteCount(lifecycle.databaseBytes)) of \(Self.byteCount(lifecycle.databaseCapBytes))"
    }

    @discardableResult
    func exportCurrentSnapshot() -> URL? {
        if snapshot == nil { refresh() }
        guard let snapshot else {
            exportMessage = "Export unavailable until a snapshot succeeds."
            return nil
        }
        do {
            let result = try exporter(snapshot, exportParent())
            exportMessage = "Exported to \(result.bundleURL.path)"
            return result.bundleURL
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func exportCurrentEvidence() async -> URL? {
        guard !isExporting else { return nil }
        guard let evidenceExporter else {
            exportMessage = "Evidence export is unavailable because the durable evidence store is not attached."
            return nil
        }
        isExporting = true
        exportMessage = "Preparing a consistent evidence bundle…"
        defer { isExporting = false }
        do {
            let result = try await evidenceExporter(exportParent())
            exportMessage = "Exported evidence to \(result.bundleURL.path)"
            exportCompletion(result.bundleURL)
            return result.bundleURL
        } catch {
            exportMessage = "Evidence export failed: \(error.localizedDescription)"
            return nil
        }
    }

    nonisolated static func defaultExportParent() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents", directoryHint: .isDirectory)
        return documents.appending(path: AppConfiguration.defaultExportFolderName, directoryHint: .isDirectory)
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
