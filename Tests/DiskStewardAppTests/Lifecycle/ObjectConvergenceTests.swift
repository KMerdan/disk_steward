@testable import DiskStewardApp
@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-615: the app actually uses the object model. The probe scans with a
/// classifier, and a store that still holds per-file rows inside objects
/// converges over a few samples.
final class ObjectConvergenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp/ds615-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAWiredProbePublishesObjectsAndStagesNothingInsideThem() async throws {
        let watched = try makeTree()
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        let databaseURL = directory.appendingPathComponent("store/evidence.sqlite")
        let probe = try PersistentMonitoringProbe(
            databaseURL: databaseURL,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024))

        var observation: MonitoringObservation?
        for _ in 0 ..< 8 where observation?.evidenceLifecycle == nil || observation?.needsScanContinuation == true {
            observation = try await probe.sample(settings: settings)
        }

        let reader = try EvidenceStore(url: databaseURL)
        let objects = try await reader.currentObjects()
        let files = try await reader.currentFiles(includeNonActionable: true)
        await reader.close()

        XCTAssertTrue(objects.contains { $0.path.hasSuffix("node_modules") },
                      "the probe must scan with a classifier: \(objects.map(\.path))")
        XCTAssertFalse(files.contains { $0.path.contains("/node_modules/") },
                       "no per-file row may be staged inside an object")
        XCTAssertTrue(files.contains { $0.path.hasSuffix("src/main.swift") }, "ordinary files are still evidence")
    }

    func testAStoreWithRowsInsideObjectsConvergesAndSaysSo() async throws {
        let watched = try makeTree()
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        let databaseURL = directory.appendingPathComponent("store/evidence.sqlite")

        // A store as an earlier version left it: per-file rows inside what is
        // now an object, written without any classifier.
        let legacy = try EvidenceStore(url: databaseURL)
        try await seedLegacyRows(legacy, watched: watched)
        let before = try await legacy.currentFiles(includeNonActionable: true)
        await legacy.close()
        XCTAssertTrue(before.contains { $0.path.contains("/node_modules/") }, "the fixture starts unconverged")

        let probe = try PersistentMonitoringProbe(
            databaseURL: databaseURL,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024))
        let observation = try await probe.sample(settings: settings)

        let reader = try EvidenceStore(url: databaseURL)
        let after = try await reader.currentFiles(includeNonActionable: true)
        let objects = try await reader.currentObjects()
        await reader.close()

        XCTAssertFalse(after.contains { $0.path.contains("/node_modules/") }, "the legacy rows are collapsed")
        XCTAssertTrue(objects.contains { $0.path.hasSuffix("node_modules") })
        XCTAssertTrue(observation.growthReport.limitations.contains { $0.contains("Collapsed") },
                      "the app says what it changed: \(observation.growthReport.limitations)")
    }

    func testAProbeWithoutAClassifierKeepsScanningEverything() async throws {
        let watched = try makeTree()
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        let databaseURL = directory.appendingPathComponent("store/evidence.sqlite")
        // A machine where classification is unavailable must still monitor.
        let probe = try PersistentMonitoringProbe(
            databaseURL: databaseURL,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024),
            objectClassifier: nil)

        var observation: MonitoringObservation?
        for _ in 0 ..< 8 where observation?.needsScanContinuation != false {
            observation = try await probe.sample(settings: settings)
        }

        let reader = try EvidenceStore(url: databaseURL)
        let objects = try await reader.currentObjects()
        let files = try await reader.currentFiles(includeNonActionable: true)
        await reader.close()

        XCTAssertTrue(objects.isEmpty, "no classifier, no objects")
        XCTAssertTrue(files.contains { $0.path.contains("/node_modules/") },
                      "and the previous behaviour of scanning everything is unchanged")
    }

    // MARK: - helpers

    /// A project with ordinary files and a node_modules that classifies by its
    /// contents, so no repository is needed.
    @discardableResult
    private func makeTree() throws -> URL {
        let watched = directory.appendingPathComponent("watched")
        let project = watched.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data("0".utf8).write(to: project.appendingPathComponent("src/main.swift"))
        for index in 0 ..< 6 {
            let package = project.appendingPathComponent("node_modules/dep-\(index)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: package.appendingPathComponent("package.json"))
            try Data("0".utf8).write(to: package.appendingPathComponent("index.js"))
        }
        return watched
    }

    private func seedLegacyRows(_ store: EvidenceStore, watched: URL) async throws {
        let now = Date()
        let paths = [watched.appendingPathComponent("app/src/main.swift").standardizedFileURL.path,
                     watched.appendingPathComponent("app/node_modules/dep-0/index.js").standardizedFileURL.path,
                     watched.appendingPathComponent("app/node_modules/dep-1/index.js").standardizedFileURL.path]
        let scope = EvidenceScopeVersion(scopeVersionID: "legacy-scope", effectiveAt: now,
                                         rootPaths: [watched.standardizedFileURL.path], excludedPaths: [],
                                         maximumEntries: 10_000, maximumDepth: 32)
        let files = paths.map {
            FileMetadata(objectID: "legacy-" + $0, identityMethod: .volumeFileGeneration,
                         rootPath: watched.standardizedFileURL.path, path: $0,
                         logicalBytes: 1, allocatedBytes: 1, modifiedAt: now, linkCount: 1)
        }
        let metadata = MetadataSnapshot(observationID: "legacy-observation", scopeVersionID: scope.scopeVersionID,
                                        observedAt: now,
                                        entries: Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) }),
                                        rootCoverage: [.init(rootPath: watched.standardizedFileURL.path,
                                                             coverage: .complete, limitations: [])],
                                        limitations: [])
        let snapshot = StorageSnapshot(snapshotID: "legacy-snapshot",
                                       observedAt: ISO8601DateFormatter().string(from: now),
                                       volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500,
                                                       isInternal: true, isReadOnly: false)])
        _ = try await store.recordObservation(snapshot: snapshot, metadata: metadata, scope: scope, trigger: .scheduled)
    }
}
