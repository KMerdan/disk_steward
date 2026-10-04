@testable import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

/// TASK-651: samples land in the capacity ring, the board shows the distance
/// to the comfort reserve and says "Capacity unavailable" instead of showing a
/// stale value, and the storage summary reports history and reserve without
/// the evidence store.
@MainActor
final class CapacityHistoryLifecycleTests: XCTestCase {
    private actor ScriptedProbe: MonitoringProbing {
        private var step = 0
        private let failAfter: Int?
        let availableGiB: Int64
        init(availableGiB: Int64, failAfter: Int? = nil) { self.availableGiB = availableGiB; self.failAfter = failAfter }
        func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
            defer { step += 1 }
            if let failAfter, step >= failAfter { throw CocoaError(.fileReadUnknown) }
            let gib = MonitoringSettings.gibibyte
            let at = Date(timeIntervalSince1970: 1_790_000_000 + Double(step) * 300)
            let snapshot = StorageSnapshot(snapshotID: "s\(step)", observedAt: EvidenceTimestamp.format(at),
                volumes: [.init(mountPath: "/", totalBytes: 1_000 * gib, availableBytes: (availableGiB - Int64(step)) * gib, isInternal: true, isReadOnly: false)])
            return MonitoringObservation(observedAt: at, snapshot: snapshot, detailedEvents: [],
                growthReport: GrowthExplanationEngine().explain(volumeUsedDelta: 0, detailedEvents: []), volumeIdentity: "UUID-T")
        }
    }

    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "capacity-history-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func settings(reserveGiB: Int) -> MonitoringSettingsStore {
        let store = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        store.update { $0.comfortReserveGiB = reserveGiB; $0.monitoringPaused = false }
        return store
    }

    func testEachObservationIsRecordedInTheRing() async throws {
        let ring = try CapacityRing(url: directory.appending(path: "capacity.sqlite"))
        let lifecycle = MonitoringLifecycleController(settingsStore: settings(reserveGiB: 100), probe: ScriptedProbe(availableGiB: 500),
            notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil, capacityRing: ring)
        await lifecycle.sampleNow()
        await lifecycle.sampleNow()
        await lifecycle.sampleNow()
        let recent = try await ring.recent(volumeUUID: "UUID-T", limit: 10)
        XCTAssertEqual(recent.total, 3)
        XCTAssertEqual(recent.items.first?.availableBytes, 498 * MonitoringSettings.gibibyte)
        lifecycle.shutdown()
        await ring.close()
    }

    func testBoardShowsReserveDistanceAndCapacityUnavailableAfterAFailedSample() async throws {
        let lifecycle = MonitoringLifecycleController(settingsStore: settings(reserveGiB: 400), probe: ScriptedProbe(availableGiB: 300, failAfter: 1),
            notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil)
        let board = StatusBoardViewModel(lifecycle: lifecycle)
        await lifecycle.sampleNow()
        for _ in 0..<20 { await Task.yield() }
        let reserve = try XCTUnwrap(board.reserveSummary)
        XCTAssertTrue(reserve.contains("below your"), reserve)
        XCTAssertTrue(board.belowReserve)
        XCTAssertEqual(board.capacityHealth, .attention)
        XCTAssertNotEqual(board.availableSummary, "Capacity unavailable")

        await lifecycle.sampleNow()  // the volume can no longer be measured
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(lifecycle.latestSampleFailedAt)
        XCTAssertEqual(board.availableSummary, "Capacity unavailable", "an old value is not shown as current")
        XCTAssertTrue(board.capacitySummary.hasPrefix("Capacity unavailable · last measured"), board.capacitySummary)
        XCTAssertNil(board.reserveSummary)
        XCTAssertEqual(board.capacityHealth, .unavailable)
        lifecycle.shutdown()
    }

    func testStorageSummaryReportsHistoryAndReserveWithoutTheEvidenceStore() async throws {
        let ringURL = directory.appending(path: "capacity.sqlite")
        let selected = try XCTUnwrap(selectedCapacityVolume(in: try VolumeSnapshotService().capture()))
        let ring = try CapacityRing(url: ringURL)
        for step in 0..<3 {
            try await ring.record(volumeUUID: "UUID-root", mountPath: selected.mountPath, totalBytes: selected.totalBytes,
                                  availableBytes: selected.availableBytes, at: Date().addingTimeInterval(Double(step - 3) * 300))
        }
        await ring.close()
        let database = directory.appending(path: "evidence.sqlite")
        try Data(repeating: 0x5A, count: 8_192).write(to: database)  // the evidence store is corrupt
        let backend = try AppEvidenceQueryBackend(databaseURL: database, capacityRingURL: ringURL, reserveProvider: { _ in 42 })
        let socket = URL(fileURLWithPath: "/tmp/ds-ring-\(UUID().uuidString.prefix(6))").appending(path: "s.sock")
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: backend)
        try server.start()
        defer { server.stop() }
        let summary = try UnixSocketDiskStewardIPCClient(socketPath: socket.path).call(tool: "get_storage_summary", arguments: [:], isCancelled: { false })
        let object = try XCTUnwrap(summary.objectValue)
        XCTAssertEqual(object["detail_status"], .string("unavailable"))
        XCTAssertEqual(object["reserve_bytes"], .integer(42))
        XCTAssertNotEqual(object["free_above_reserve_bytes"], .null)
        let history = try XCTUnwrap(object["capacity_history"]?.objectValue)
        XCTAssertEqual(history["status"], .string("available"))
        XCTAssertGreaterThanOrEqual(history["sample_count"]?.integerValue ?? 0, 4, "three fine samples and at least one hourly")
    }
}
