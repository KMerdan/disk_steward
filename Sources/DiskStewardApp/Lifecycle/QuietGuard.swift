import DiskStewardCore
import Foundation

extension MonitoringObservation {
    /// TASK-653: live capacity with file scanning retired by design. Unlike
    /// `capacityOnly`, nothing failed: the status is healthy, and the only
    /// claim beyond the volume figures is that file detail is not collected.
    static func quietGuard(
        snapshot: StorageSnapshot, volumeGrowth: VolumeGrowthSample, volumeDelta: Int64, at date: Date
    ) -> MonitoringObservation {
        let report = GrowthExplanationEngine().explain(
            volumeUsedDelta: volumeDelta, detailedEvents: [], eventGap: true,
            scopeLimitations: volumeGrowth.limitations + [QuietGuardProbe.limitation]
        )
        return MonitoringObservation(
            observedAt: date, snapshot: snapshot, detailedEvents: [], growthReport: report,
            volumeIdentity: volumeGrowth.selectedVolumeIdentity, detailRetired: true
        )
    }
}

/// TASK-653: the idle monitor after the per-file scanner's retirement. It
/// measures capacity and nothing else; which directories changed comes from
/// the change journal. It opens no evidence store, walks no directory and
/// runs no retention.
actor QuietGuardProbe: MonitoringProbing {
    static let limitation = "Files are not scanned at idle. Changed directories come from the file-system change journal (explain_growth), unmeasured."
    private let volumeSampleSource: @Sendable (StorageSnapshot?) throws -> (StorageSnapshot, VolumeGrowthSample)
    private var previousStorage: StorageSnapshot?

    init(volumeSampleSource: @escaping @Sendable (StorageSnapshot?) throws -> (StorageSnapshot, VolumeGrowthSample) = { try WholeVolumeSampler().sample(after: $0) }) {
        self.volumeSampleSource = volumeSampleSource
    }

    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        try Task.checkCancellation()
        let (snapshot, growth) = try volumeSampleSource(previousStorage)
        previousStorage = snapshot
        let delta = PersistentMonitoringProbe.selectedVolumeDelta(snapshot: snapshot, growth: growth)
        return .quietGuard(snapshot: snapshot, volumeGrowth: growth, volumeDelta: delta, at: Date())
    }
}

/// The idle composition: which probe runs and whether the per-file change
/// collector exists. After TASK-653 there is one answer.
struct MonitoringComposition {
    let probe: MonitoringProbing
    let changeCollector: (any MonitoringChangeCollecting)?

    static func quietGuard() -> MonitoringComposition {
        MonitoringComposition(probe: QuietGuardProbe(), changeCollector: nil)
    }
}

/// The renamed legacy evidence for the board and settings: export from a
/// clone, delete only when confirmed.
@MainActor
final class LegacyEvidenceController: ObservableObject {
    @Published private(set) var sets: [LegacyEvidenceManifest] = []
    @Published private(set) var migrationError: String?
    let supportDirectory: URL?
    private let remove: (URL) throws -> Void

    init(supportDirectory: URL?, migrationError: String? = nil,
         remove: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.supportDirectory = supportDirectory
        self.migrationError = migrationError
        self.remove = remove
        refresh()
    }

    var newest: LegacyEvidenceManifest? { sets.first }

    func refresh() {
        sets = supportDirectory.flatMap { try? LegacyEvidence.sets(in: $0) } ?? []
    }

    /// Exports the newest set's whole history from a clone into `parent`.
    nonisolated static func export(
        _ manifest: LegacyEvidenceManifest, supportDirectory: URL, to parent: URL
    ) async throws -> EvidenceBundleExportResult {
        let clone = try LegacyEvidence.clone(manifest, supportDirectory: supportDirectory)
        defer { try? FileManager.default.removeItem(at: clone.deletingLastPathComponent()) }
        let store = try EvidenceStore(url: clone)
        do {
            let result = try await EvidenceBundleExporter().export(
                store: store,
                options: .init(from: manifest.migratedAt.addingTimeInterval(-400 * 86_400), through: manifest.migratedAt),
                to: parent
            )
            await store.close()
            return result
        } catch {
            await store.close()
            throw error
        }
    }

    func delete(_ manifest: LegacyEvidenceManifest, confirmed: Bool) throws {
        guard let supportDirectory else { throw LegacyEvidenceError.notFound(manifest.name) }
        try LegacyEvidence.delete(manifest, supportDirectory: supportDirectory, confirmed: confirmed, remove: remove)
        refresh()
    }
}
