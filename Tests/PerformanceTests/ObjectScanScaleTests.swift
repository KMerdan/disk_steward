@testable import DiskStewardCore
import Foundation
import XCTest

/// Opt-in scale case for TASK-612: a scope whose files sit behind classified
/// objects must complete one generation, publish those objects, and stage no
/// per-file row inside any of them.
///
/// It runs only when a supervisor hands it a fixture it owns, so an ordinary
/// test run never builds a million files:
///
///   DISK_STEWARD_OBJECT_SCALE=v1
///   DISK_STEWARD_OBJECT_SCALE_ROOT=/private/tmp/<leaf>
///   DISK_STEWARD_OBJECT_SCALE_TOKEN=<uuid matching <root>/owner-token>
final class ObjectScanScaleTests: XCTestCase {
    func testOptInObjectScanCompletesRegardlessOfWhatIsInsideObjects() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DISK_STEWARD_OBJECT_SCALE"] == "v1" else {
            throw XCTSkip("Opt-in scale case; a supervisor sets DISK_STEWARD_OBJECT_SCALE.")
        }
        try requireScaleSupervisor()
        let path = try XCTUnwrap(environment["DISK_STEWARD_OBJECT_SCALE_ROOT"])
        let root = URL(fileURLWithPath: path)
        // A supervisor-owned leaf, named without traversal. /private/tmp is the
        // real directory; Foundation standardizes it to /tmp, so the two forms
        // are compared through resolution rather than string equality.
        guard path.hasPrefix("/private/tmp/"), !root.pathComponents.contains(".."),
              root.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path else {
            return XCTFail("The scale fixture must be a supervisor-owned /private/tmp leaf")
        }
        let token = try String(contentsOf: root.appendingPathComponent("owner-token"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard token == environment["DISK_STEWARD_OBJECT_SCALE_TOKEN"], token.count == 36 else {
            return XCTFail("Owner token mismatch: this process does not own the fixture")
        }

        let tree = root.appendingPathComponent("tree")
        let store = try EvidenceStore(url: root.appendingPathComponent("store/evidence.sqlite"))
        let scanner = DirectoryMetadataScanner(streams: DirectoryStreamRegistry(), classifier: ObjectClassifier())
        let policy = MonitoringPolicy(watchedRoots: [tree], maximumEntries: 512, maximumDepth: 64)
        let scope = policy.scopeVersion(at: Date())
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: Date())

        let started = ProcessInfo.processInfo.systemUptime
        var slices = 0
        var published = false
        while generation.status == .active, slices < 20_000 {
            let slice = scanner.scanSlice(policy: policy, generation: generation, at: Date())
            let commit = try await store.recordScanSlice(snapshot: Self.snapshot(), slice: slice,
                                                         scope: scope, trigger: .scheduled)
            generation = commit.generation
            published = published || commit.observation != nil
            slices += 1
        }
        let seconds = ProcessInfo.processInfo.systemUptime - started
        let objects = try await store.currentObjects()
        let files = try await store.currentFiles(includeNonActionable: true)
        let diagnostics = try await store.diagnostics()
        await store.close()

        let insideObject = files.filter { file in objects.contains { file.path.hasPrefix($0.path + "/") } }
        let result: [String: Any] = [
            "schema": "disk-steward-object-scan-scale-v1",
            "status": generation.status.rawValue,
            "published": published,
            "slices": slices,
            "seconds": (seconds * 10).rounded() / 10,
            "processedEntries": generation.processedEntryCount,
            "objectsPublished": objects.count,
            "perFileRows": files.count,
            "perFileRowsInsideObjects": insideObject.count,
            "databaseFileBytes": diagnostics.databaseFileBytes,
            "entriesBehindObjects": (environment["DISK_STEWARD_OBJECT_SCALE_BEHIND"].flatMap(Int.init)) ?? -1,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try encoded.write(to: root.appendingPathComponent("result.json"))
        print(String(decoding: encoded, as: UTF8.self))

        XCTAssertEqual(generation.status, .completed, "one generation must finish")
        XCTAssertTrue(published, "and publish current state")
        XCTAssertEqual(insideObject.count, 0, "no per-file row may exist inside an object")
        XCTAssertGreaterThan(objects.count, 0)
    }

    private static func snapshot() -> StorageSnapshot {
        StorageSnapshot(snapshotID: "snapshot-" + UUID().uuidString.lowercased().prefix(8),
                        observedAt: ISO8601DateFormatter().string(from: Date()),
                        volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500,
                                        isInternal: true, isReadOnly: false)])
    }
}
