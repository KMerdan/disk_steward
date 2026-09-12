import Combine
import DiskStewardCore
import Foundation

@MainActor
final class StatusBoardViewModel: ObservableObject {
    typealias SnapshotLoader = () throws -> StorageSnapshot
    typealias Exporter = (StorageSnapshot, URL) throws -> SnapshotExportResult

    @Published private(set) var snapshot: StorageSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var exportMessage: String?

    private let snapshotLoader: SnapshotLoader
    private let exporter: Exporter
    private let exportParent: () -> URL
    let lifecycle: MonitoringLifecycleController

    init(
        snapshotLoader: @escaping SnapshotLoader = { try VolumeSnapshotService().capture() },
        exporter: @escaping Exporter = { try SnapshotExporter().export($0, to: $1) },
        exportParent: @escaping () -> URL = StatusBoardViewModel.defaultExportParent,
        lifecycle: MonitoringLifecycleController? = nil
    ) {
        self.snapshotLoader = snapshotLoader
        self.exporter = exporter
        self.exportParent = exportParent
        self.lifecycle = lifecycle ?? MonitoringLifecycleController(
            settingsStore: MonitoringSettingsStore(persistence: EphemeralSettingsPersistence()),
            probe: UnavailableMonitoringProbe(reason: "Background monitoring is not attached to this view model.")
        )
    }

    var primaryVolume: VolumeCapacity? { snapshot?.volumes.first }

    var usedFraction: Double {
        guard let volume = primaryVolume, volume.totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(volume.usedBytes) / Double(volume.totalBytes)))
    }

    var capacitySummary: String {
        guard let volume = primaryVolume else { return "Capacity unavailable" }
        return "\(Self.byteCount(volume.usedBytes)) used of \(Self.byteCount(volume.totalBytes))"
    }

    func refresh() {
        if let monitored = lifecycle.latestObservation?.snapshot {
            snapshot = monitored
            errorMessage = nil
            return
        }
        do {
            snapshot = try snapshotLoader()
            errorMessage = nil
        } catch {
            snapshot = nil
            errorMessage = error.localizedDescription
        }
    }

    var growthSummary: String {
        guard let delta = lifecycle.latestObservation?.growthReport.volumeUsedDelta else { return "Awaiting growth baseline" }
        return delta > 0 ? "+\(Self.byteCount(delta)) since prior sample" : "No measured growth since prior sample"
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

    nonisolated private static func defaultExportParent() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents", directoryHint: .isDirectory)
        return documents.appending(path: AppConfiguration.defaultExportFolderName, directoryHint: .isDirectory)
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
