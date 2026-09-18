import CryptoKit
import DiskStewardCore
import XCTest
@testable import DiskStewardApp
@testable import DiskStewardCore

@MainActor
final class PersistentRecorderIncrementTests: XCTestCase {
    func testMonitoredGrowthPersistsNotifiesExportsAndRecoversAfterRestart() async throws {
        let fixture = try Fixture()
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [fixture.watched.path]
        settings.excludedRoots = []
        settings.capacityThresholdPercent = 50
        settings.growthThresholdMiB = 1
        settings.maxDatabaseMiB = 10
        let settingsStore = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        settingsStore.update { $0 = settings }
        let notifications = GateNotificationDelivery()
        let probe = try PersistentMonitoringProbe(
            databaseURL: fixture.database,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024)
        )
        let lifecycle = MonitoringLifecycleController(
            settingsStore: settingsStore,
            probe: probe,
            notificationDelivery: notifications,
            changeCollector: nil
        )

        await lifecycle.sampleNow()
        XCTAssertEqual(lifecycle.status.kind, .active)
        try Data(repeating: 7, count: 2 * 1_024 * 1_024).write(to: fixture.watched.appending(path: "agent-growth.bin"))
        let outside = fixture.directory.appending(path: "outside-growth.bin")
        try Data(repeating: 8, count: 8_192).write(to: outside)
        await lifecycle.sampleNow()

        let observation = try XCTUnwrap(lifecycle.latestObservation)
        XCTAssertEqual(observation.detailedEvents.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["agent-growth.bin"])
        XCTAssertEqual(observation.detailedEvents.first?.confidence, .inferred)
        XCTAssertFalse(lifecycle.status.accessibilitySummary.contains("configured-root evidence is current"))
        XCTAssertEqual(observation.evidenceLifecycle?.scanCoverage?.detailCoverage, "complete")
        let outsideBytes = Int64(try outside.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
        let detailBytes = observation.detailedEvents.reduce(0) { $0 + max(0, $1.allocatedDelta) }
        let boundedExplanation = GrowthExplanationEngine().explain(
            volumeUsedDelta: detailBytes + outsideBytes,
            detailedEvents: observation.detailedEvents,
            scopeLimitations: ["Fixture includes one outside-root allocation."]
        )
        XCTAssertEqual(boundedExplanation.unexplainedDelta, outsideBytes)
        XCTAssertTrue(boundedExplanation.causes.contains { $0.category == "unexplained" && $0.confidence == .unknown })
        let notificationCount = await notifications.count
        XCTAssertEqual(notificationCount, 1)

        let reader = try EvidenceStore(url: fixture.database)
        let exported = try await EvidenceBundleExporter(
            productVersion: "gate-290",
            identifierSource: { "increment-two" },
            dateSource: Date.init
        ).export(
            store: reader,
            options: .init(from: Date().addingTimeInterval(-3_600), through: Date().addingTimeInterval(60), pathDetail: .basename),
            to: fixture.exports
        )
        try verifyBundle(exported)
        let brief = try String(contentsOf: exported.bundleURL.appending(path: "codex-brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("agent-growth.bin"))
        XCTAssertTrue(brief.contains("inferred via snapshot-delta"))
        XCTAssertTrue(brief.contains("No file contents or environment variables"))
        await reader.close()

        let restartedProbe = try PersistentMonitoringProbe(
            databaseURL: fixture.database,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024)
        )
        _ = try await restartedProbe.sample(settings: settings)
        let recovered = try EvidenceStore(url: fixture.database)
        let diagnostics = try await recovered.diagnostics()
        XCTAssertEqual(diagnostics.integrity, "ok")
        XCTAssertGreaterThanOrEqual(diagnostics.snapshotCount, 3)
        XCTAssertGreaterThanOrEqual(diagnostics.eventCount, 1)
        XCTAssertLessThanOrEqual(diagnostics.storageBytes, Int64(settings.maxDatabaseMiB) * 1_024 * 1_024)
        await recovered.close()
    }

    private func verifyBundle(_ result: EvidenceBundleExportResult) throws {
        let manifestData = try Data(contentsOf: result.bundleURL.appending(path: "manifest.json"))
        let decoded = try JSONDecoder().decode(EvidenceBundleManifest.self, from: manifestData)
        XCTAssertEqual(decoded.schema, "export-manifest-v2")
        XCTAssertEqual(decoded.producer.evidenceSchemaVersion, 2)
        XCTAssertEqual(decoded.files, result.manifest.files)
        for file in result.manifest.files {
            let data = try Data(contentsOf: result.bundleURL.appending(path: file.path))
            XCTAssertEqual(data.count, file.bytes)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), file.sha256)
        }
    }
}

private actor GateNotificationDelivery: MonitoringNotificationDelivering {
    private(set) var notifications: [MonitoringNotification] = []
    var count: Int { notifications.count }
    func deliver(_ notification: MonitoringNotification) async { notifications.append(notification) }
}

private final class Fixture {
    let directory: URL
    let watched: URL
    let database: URL
    let exports: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        watched = directory.appending(path: "watched", directoryHint: .isDirectory)
        database = directory.appending(path: "database/evidence.sqlite")
        exports = directory.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
