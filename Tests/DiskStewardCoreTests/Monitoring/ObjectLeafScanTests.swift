@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-612: a classified object is recorded whole and never entered, so the
/// work a scan does stops depending on what is inside one.
final class ObjectLeafScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/ds612-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAnObjectIsRecordedWholeAndNothingInsideItIsScanned() throws {
        try makeProject("app", files: ["src/main.swift", "README.md"])
        try makeObject("app/node_modules", files: (0 ..< 40).map { "dep\($0)/index.js" })
        let scanner = DirectoryMetadataScanner(streams: DirectoryStreamRegistry(), classifier: ObjectClassifier())

        let slice = try scanAll(scanner)

        XCTAssertEqual(slice.objects.map(\.path),
                       [root.appendingPathComponent("app/node_modules").standardizedFileURL.path])
        XCTAssertEqual(slice.objects.first?.rule, .content)
        XCTAssertTrue(slice.entries.allSatisfy { !$0.path.contains("node_modules") },
                      "no file inside an object may be staged")
        XCTAssertEqual(Set(slice.entries.map { URL(fileURLWithPath: $0.path).lastPathComponent }),
                       ["main.swift", "README.md", "package.json"])
    }

    func testScanWorkDoesNotGrowWithWhatIsInsideAnObject() throws {
        // The same tree twice: one object holds 10 files, the other 400. If the
        // scanner entered objects, the processed count would differ by 390.
        func processedEntries(insideObject count: Int) throws -> Int {
            let directory = root.appendingPathComponent("case-\(count)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try makeProject("case-\(count)/app", files: ["src/main.swift"])
            try makeObject("case-\(count)/app/node_modules", files: (0 ..< count).map { "dep\($0)/index.js" })
            let scanner = DirectoryMetadataScanner(streams: DirectoryStreamRegistry(), classifier: ObjectClassifier())
            return try scanAll(scanner, at: directory).generation.processedEntryCount
        }

        let small = try processedEntries(insideObject: 10)
        let large = try processedEntries(insideObject: 400)

        XCTAssertEqual(small, large, "an object costs the same whatever it contains")
    }

    func testTrackedSourceThatLooksLikeOutputIsStillScanned() throws {
        try makeProject("app", files: ["build/deploy.sh", "src/main.swift"])
        // The repository tracks app/build, so it is source and must be entered.
        let oracle = TrackedOracle(trackedPaths: [root.appendingPathComponent("app/build").path])
        let scanner = DirectoryMetadataScanner(streams: DirectoryStreamRegistry(),
                                               classifier: ObjectClassifier(oracle: oracle))

        let slice = try scanAll(scanner)

        XCTAssertTrue(slice.objects.isEmpty, "tracked source is never an object")
        XCTAssertTrue(slice.entries.contains { $0.path.hasSuffix("build/deploy.sh") },
                      "and its files are still staged")
    }

    func testAnUnresolvedCandidateIsScannedAndReported() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("orphan/build"),
                                                withIntermediateDirectories: true)
        try Data("0".utf8).write(to: root.appendingPathComponent("orphan/build/output.o"))
        let scanner = DirectoryMetadataScanner(streams: DirectoryStreamRegistry(), classifier: ObjectClassifier())

        let slice = try scanAll(scanner)

        XCTAssertTrue(slice.objects.isEmpty)
        XCTAssertEqual(slice.unresolvedCandidates.map(\.name), ["build"])
        XCTAssertTrue(slice.entries.contains { $0.path.hasSuffix("output.o") },
                      "doubt means scanning it, not skipping it")
    }

    func testAGenerationCompletesAndPublishesItsObjects() async throws {
        try makeProject("app", files: ["src/main.swift"])
        try makeObject("app/node_modules", files: (0 ..< 30).map { "dep\($0)/index.js" })
        try makeObject("app/.venv", files: ["lib/site.py"], marker: "pyvenv.cfg")
        let databaseURL = root.appendingPathComponent("store/evidence.sqlite")
        let store = try EvidenceStore(url: databaseURL)
        let scanner = DirectoryMetadataScanner(streams: DirectoryStreamRegistry(), classifier: ObjectClassifier())
        let scope = scopeVersion()
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: Date())

        var slices = 0
        var observation: ObservationCommitResult?
        while generation.status == .active, slices < 50 {
            let slice = scanner.scanSlice(policy: policy(), generation: generation, at: Date())
            let commit = try await store.recordScanSlice(snapshot: snapshot(), slice: slice, scope: scope, trigger: .scheduled)
            generation = commit.generation
            observation = commit.observation ?? observation
            slices += 1
        }
        let objects = try await store.currentObjects()
        let files = try await store.currentFiles(includeNonActionable: true)
        await store.close()

        XCTAssertEqual(generation.status, .completed, "the generation finishes")
        XCTAssertNotNil(observation, "and publishes")
        XCTAssertEqual(Set(objects.map { URL(fileURLWithPath: $0.path).lastPathComponent }), ["node_modules", ".venv"])
        XCTAssertTrue(objects.allSatisfy { $0.measuredAt == nil && $0.logicalBytes == 0 },
                      "sizing is TASK-621's work; an unmeasured object claims no size")
        XCTAssertTrue(files.allSatisfy { !$0.path.contains("node_modules") && !$0.path.contains(".venv") },
                      "no per-file row exists inside an object")
        XCTAssertTrue(files.contains { $0.path.hasSuffix("src/main.swift") })
    }

    // MARK: - helpers

    private func makeProject(_ relative: String, files: [String]) throws {
        let directory = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("package.json"))
        for file in files {
            let url = directory.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("0".utf8).write(to: url)
        }
    }

    private func makeObject(_ relative: String, files: [String], marker: String? = nil) throws {
        let directory = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let marker {
            try Data("home = /usr/bin\n".utf8).write(to: directory.appendingPathComponent(marker))
        }
        for file in files {
            let url = directory.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("0".utf8).write(to: url)
            if file.hasSuffix("index.js") {
                try Data("{}".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("package.json"))
            }
        }
    }

    private func policy(at directory: URL? = nil) -> MonitoringPolicy {
        MonitoringPolicy(watchedRoots: [directory ?? root], maximumEntries: 512, maximumDepth: 32)
    }

    private func scopeVersion(at directory: URL? = nil) -> EvidenceScopeVersion {
        policy(at: directory).scopeVersion(at: Date())
    }

    private func snapshot() -> StorageSnapshot {
        StorageSnapshot(snapshotID: "snapshot-" + UUID().uuidString.prefix(8),
                        observedAt: ISO8601DateFormatter().string(from: Date()),
                        volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500,
                                        isInternal: true, isReadOnly: false)])
    }

    /// Runs slices until the generation stops being active, without a store.
    private func scanAll(_ scanner: DirectoryMetadataScanner, at directory: URL? = nil) throws -> MetadataScanSlice {
        let policy = policy(at: directory)
        let scope = policy.scopeVersion(at: Date())
        var generation = MetadataScanGeneration(
            generationID: "generation-" + UUID().uuidString.prefix(8),
            scopeVersionID: scope.scopeVersionID, rootPaths: scope.rootPaths,
            excludedPaths: scope.excludedPaths, status: MetadataScanGenerationStatus.active,
            roots: scope.rootPaths.map { MetadataScanRootProgress(rootPath: $0) },
            processedEntryCount: 0, stagedFileCount: 0, startedAt: Date(), updatedAt: Date())
        var entries: [FileMetadata] = []
        var objects: [ClassifiedObject] = []
        var unresolved: [UnresolvedCandidate] = []
        var slice = MetadataScanSlice(generation: generation, entries: [])
        var rounds = 0
        while generation.status == MetadataScanGenerationStatus.active, rounds < 100 {
            slice = scanner.scanSlice(policy: policy, generation: generation, at: Date())
            entries += slice.entries
            objects += slice.objects
            unresolved += slice.unresolvedCandidates
            generation = slice.generation
            rounds += 1
        }
        return MetadataScanSlice(generation: generation, entries: entries, diagnostics: slice.diagnostics,
                                 objects: objects, unresolvedCandidates: unresolved)
    }
}

/// A repository that tracks exactly the paths the test names.
private struct TrackedOracle: RepositoryOracle {
    let trackedPaths: Set<String>
    func ignores(path _: String, repositoryPath _: String) -> Bool? { false }
    func tracksContents(ofPath path: String, repositoryPath _: String) -> Bool? { trackedPaths.contains(path) }
}
