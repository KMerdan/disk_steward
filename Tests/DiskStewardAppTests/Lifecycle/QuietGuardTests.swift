@testable import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

/// TASK-653 AC-01: at idle only capacity sampling (and the change journal)
/// run. No sample opens an evidence store, scans a folder or runs retention,
/// and the state is healthy, not "File detail unavailable".
@MainActor
final class QuietGuardTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp/ds-quiet-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testIdleSamplesAreHealthyAndWriteOnlyTheCapacityRing() async throws {
        let watched = directory.appending(path: "watched/project/node_modules", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        for index in 0..<20 { try Data(repeating: 1, count: 4_096).write(to: watched.appending(path: "f\(index).bin")) }
        let settings = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        settings.update { $0.watchedRoots = [self.directory.appending(path: "watched").path]; $0.monitoringPaused = false }
        let ring = try CapacityRing(url: directory.appending(path: "capacity.sqlite"))

        let composition = MonitoringComposition.quietGuard()
        XCTAssertTrue(composition.probe is QuietGuardProbe)
        XCTAssertNil(composition.changeCollector, "no per-file change collector")
        let lifecycle = MonitoringLifecycleController(
            settingsStore: settings, probe: composition.probe, notificationDelivery: DisabledNotificationDelivery(),
            changeCollector: composition.changeCollector, capacityRing: ring)
        for _ in 0..<3 { await lifecycle.sampleNow() }

        let observation = try XCTUnwrap(lifecycle.latestObservation)
        XCTAssertTrue(observation.detailRetired)
        XCTAssertNil(observation.evidenceLifecycle, "no evidence store behind the sample")
        XCTAssertNil(observation.detailUnavailableReason)
        XCTAssertNil(observation.scanStop)
        XCTAssertFalse(observation.needsScanContinuation, "no scan to continue")
        XCTAssertTrue(observation.detailedEvents.isEmpty)
        XCTAssertEqual(lifecycle.status.kind, .active)
        XCTAssertTrue(lifecycle.status.detail.contains("No files are scanned while idle"), lifecycle.status.detail)
        let board = StatusBoardViewModel(lifecycle: lifecycle)
        XCTAssertEqual(board.evidenceFreshnessSummary, "Files are not scanned while idle")

        let identity = try XCTUnwrap(observation.capacity?.identity)
        let recent = try await ring.recent(volumeUUID: identity, limit: 10)
        XCTAssertGreaterThanOrEqual(recent.total, 1, "capacity is still recorded")
        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(written, ["capacity.sqlite", "watched"], "nothing but the ring is written: no evidence store, no retention, no convergence record")
        lifecycle.shutdown()
        await ring.close()
    }

    /// "Removed or unreachable": the app constructs neither the scanner probe
    /// nor the per-file collector anywhere outside the retired probe's own file,
    /// and the status item composes the quiet guard.
    func testNoAppSourceConstructsTheScannerOrThePerFileCollector() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/DiskStewardApp", directoryHint: .isDirectory)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20)
        for file in files where file.lastPathComponent != "PersistentMonitoringProbe.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for constructor in ["PersistentMonitoringProbe(", "TargetedFSEventsCollector(", "CapacityOnlyMonitoringProbe(", "DirectoryMetadataScanner(", "RetentionSchedule("] {
                XCTAssertFalse(source.contains(constructor), "\(file.lastPathComponent) constructs \(constructor)")
            }
        }
        let controller = try String(contentsOf: app.appending(path: "StatusItemController.swift"), encoding: .utf8)
        XCTAssertTrue(controller.contains("MonitoringComposition.quietGuard()"))
        XCTAssertTrue(controller.contains("fileDetail: .retired("), "the MCP backend never opens the old store")
        let migration = try XCTUnwrap(controller.range(of: "LegacyEvidence.migrate("))
        let firstUse = try XCTUnwrap(controller.range(of: "MonitoringLifecycleController("))
        XCTAssertLessThan(migration.lowerBound, firstUse.lowerBound, "the legacy move happens before anything is composed")
    }
}
