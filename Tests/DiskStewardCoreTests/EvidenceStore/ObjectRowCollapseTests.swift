@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-613: the durable object row, and collapsing the per-file rows that fall
/// inside an object into it. Contract: docs/reliability/evidence/CONTRACT-601/object-contract.md.
final class ObjectRowCollapseTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp/ds613-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        databaseURL = directory.appendingPathComponent("evidence.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSchemaUpgradeAddsObjectRowsAndKeepsExistingEvidence() async throws {
        let store = try EvidenceStore(url: databaseURL)
        let before = try await store.diagnostics()
        let objects = try await store.currentObjects()
        await store.close()

        XCTAssertEqual(before.schemaVersion, Int(EvidenceStore.currentSchemaVersion))
        XCTAssertEqual(EvidenceStore.currentSchemaVersion, 15)
        XCTAssertTrue(objects.isEmpty, "a fresh store has no objects")
    }

    func testAnObjectRowKeepsItsDetectionEvidenceAndIsReadBackWhole() async throws {
        let store = try EvidenceStore(url: databaseURL)
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        let object = StoredObject(
            classification: ClassifiedObject(
                path: "/tmp/project/node_modules", kind: .artifact, rule: .ignored, confidence: .high,
                reason: "the owning repository ignores it",
                owningProjectPath: "/tmp/project", owningProjectMarker: ".git"),
            logicalBytes: 4_096, fileCount: 12, measuredAt: observed, dirty: false,
            rebuildCommand: "npm install", observedAt: observed)

        try await store.recordObjects([object])
        let stored = try await store.currentObjects()
        await store.close()

        XCTAssertEqual(stored, [object])
        XCTAssertEqual(stored.first?.classification.reason, "the owning repository ignores it")
        XCTAssertEqual(stored.first?.rebuildCommand, "npm install")
    }

    func testARepositoryIsStoredButNeverACleanupCandidate() async throws {
        let store = try EvidenceStore(url: databaseURL)
        let now = Date()
        try await store.recordObjects([
            StoredObject(classification: ClassifiedObject(
                path: "/tmp/project/.git", kind: .repository, rule: .repository, confidence: .high,
                reason: "a repository is measured as one object and is never offered for cleanup"),
                logicalBytes: 2_048, fileCount: 40, measuredAt: now, observedAt: now),
            StoredObject(classification: ClassifiedObject(
                path: "/tmp/project/target", kind: .artifact, rule: .selfMarker, confidence: .high,
                reason: "it is tagged as a cache directory (CACHEDIR.TAG)"),
                logicalBytes: 8_192, fileCount: 90, measuredAt: now, observedAt: now),
        ])
        let all = try await store.currentObjects()
        let candidates = try await store.cleanupCandidateObjects()
        await store.close()

        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(candidates.map(\.path), ["/tmp/project/target"])
    }

    func testAnAggregateWithoutTheTimeItWasMeasuredIsRefused() async throws {
        let store = try EvidenceStore(url: databaseURL)
        let object = StoredObject(
            classification: ClassifiedObject(path: "/tmp/p/dist", kind: .artifact, rule: .content,
                                             confidence: .high, reason: "it holds installed packages with their own manifests"),
            logicalBytes: 999, fileCount: 3, measuredAt: nil, observedAt: Date())

        do {
            try await store.recordObjects([object])
            await store.close()
            XCTFail("a size without its measurement time must not be publishable")
        } catch {
            await store.close()
        }
    }

    func testCollapseRemovesOnlyRowsInsideObjectsAndLeavesOtherEvidenceIdentical() async throws {
        let store = try EvidenceStore(url: databaseURL)
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        try await seedCurrentState(store, paths: [
            "/w/project/src/main.swift", "/w/project/README.md",
            "/w/project/node_modules/left-pad/index.js", "/w/project/node_modules/left-pad/package.json",
            "/w/other/keep.txt",
        ], at: now)
        let unrelatedBefore = try await unrelatedEvidenceFingerprint(store)
        let object = StoredObject(
            classification: ClassifiedObject(path: "/w/project/node_modules", kind: .artifact, rule: .ignored,
                                             confidence: .high, reason: "the owning repository ignores it"),
            logicalBytes: 64, fileCount: 2, measuredAt: now, observedAt: now)

        let report = try await store.collapsePerFileRows(into: [object])

        let remaining = try await currentStatePaths(store)
        let unrelatedAfter = try await unrelatedEvidenceFingerprint(store)
        let objects = try await store.currentObjects()
        await store.close()

        XCTAssertEqual(report.perFileRowsRemoved, 2)
        XCTAssertEqual(report.objectsWritten, 1)
        XCTAssertFalse(report.interrupted)
        XCTAssertEqual(remaining, ["/w/other/keep.txt", "/w/project/README.md", "/w/project/src/main.swift"])
        XCTAssertEqual(objects.map(\.path), ["/w/project/node_modules"])
        XCTAssertEqual(unrelatedAfter, unrelatedBefore, "evidence outside the object must be untouched")
    }

    func testAnInterruptedCollapseCommitsWhatItFinishedAndResumes() async throws {
        let store = try EvidenceStore(url: databaseURL)
        let now = Date(timeIntervalSince1970: 1_700_000_200)
        try await seedCurrentState(store, paths: [
            "/w/a/node_modules/one/index.js", "/w/b/node_modules/two/index.js", "/w/c/keep.txt",
        ], at: now)
        let objects = ["/w/a/node_modules", "/w/b/node_modules"].map { path in
            StoredObject(classification: ClassifiedObject(path: path, kind: .artifact, rule: .content,
                                                          confidence: .high, reason: "it holds installed packages with their own manifests"),
                         logicalBytes: 32, fileCount: 1, measuredAt: now, observedAt: now)
        }

        // Stop before the second object: the first is already committed.
        let first = try await store.collapsePerFileRows(into: objects) { label in
            if label.contains("/w/b/node_modules") { throw EvidenceStore.CollapseInterruption() }
        }
        let afterInterruption = try await currentStatePaths(store)

        let second = try await store.collapsePerFileRows(into: objects)
        let afterResume = try await currentStatePaths(store)
        let stored = try await store.currentObjects()
        await store.close()

        XCTAssertTrue(first.interrupted)
        XCTAssertEqual(first.objectsWritten, 1)
        XCTAssertEqual(afterInterruption, ["/w/b/node_modules/two/index.js", "/w/c/keep.txt"])
        XCTAssertFalse(second.interrupted)
        XCTAssertEqual(afterResume, ["/w/c/keep.txt"], "resuming finishes the rest")
        XCTAssertEqual(stored.count, 2)
    }

    func testCollapseIsIdempotent() async throws {
        let store = try EvidenceStore(url: databaseURL)
        let now = Date(timeIntervalSince1970: 1_700_000_300)
        try await seedCurrentState(store, paths: ["/w/p/node_modules/x/index.js", "/w/p/src/app.swift"], at: now)
        let object = StoredObject(
            classification: ClassifiedObject(path: "/w/p/node_modules", kind: .artifact, rule: .content,
                                             confidence: .high, reason: "it holds installed packages with their own manifests"),
            logicalBytes: 16, fileCount: 1, measuredAt: now, observedAt: now)

        let first = try await store.collapsePerFileRows(into: [object])
        let second = try await store.collapsePerFileRows(into: [object])
        let objects = try await store.currentObjects()
        await store.close()

        XCTAssertEqual(first.perFileRowsRemoved, 1)
        XCTAssertEqual(second.perFileRowsRemoved, 0, "a second pass has nothing left to remove")
        XCTAssertEqual(objects.count, 1, "and does not duplicate the object")
    }

    func testDirectoriesOfCurrentRowsAreReportedForClassification() async throws {
        let store = try EvidenceStore(url: databaseURL)
        try await seedCurrentState(store, paths: [
            "/w/p/node_modules/x/index.js", "/w/p/src/app.swift", "/w/p/src/deep/util.swift",
        ], at: Date())

        let directories = try await store.currentFileStateDirectories()
        await store.close()

        XCTAssertEqual(directories, ["/w/p/node_modules/x", "/w/p/src", "/w/p/src/deep"])
    }

    // MARK: - helpers

    private func seedCurrentState(_ store: EvidenceStore, paths: [String], at date: Date) async throws {
        let scope = EvidenceScopeVersion(scopeVersionID: "scope-613", effectiveAt: date, rootPaths: ["/w"],
                                         excludedPaths: [], maximumEntries: 10_000, maximumDepth: 10)
        let files = paths.map { path in
            FileMetadata(objectID: "object-" + path, identityMethod: .volumeFileGeneration, rootPath: "/w",
                         path: path, logicalBytes: 32, allocatedBytes: 32, modifiedAt: date, linkCount: 1)
        }
        let metadata = MetadataSnapshot(
            observationID: "observation-" + UUID().uuidString.prefix(8),
            scopeVersionID: scope.scopeVersionID, observedAt: date,
            entries: Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) }),
            rootCoverage: [.init(rootPath: "/w", coverage: .complete, limitations: [])], limitations: [])
        let snapshot = StorageSnapshot(
            snapshotID: "snapshot-" + UUID().uuidString.prefix(8),
            observedAt: ISO8601DateFormatter().string(from: date),
            volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)])
        _ = try await store.recordObservation(snapshot: snapshot, metadata: metadata, scope: scope, trigger: .scheduled)
    }

    private func currentStatePaths(_ store: EvidenceStore) async throws -> [String] {
        try await store.currentFiles(includeNonActionable: true).map(\.path).sorted()
    }

    /// A fingerprint of evidence that a collapse must not touch.
    private func unrelatedEvidenceFingerprint(_ store: EvidenceStore) async throws -> String {
        let diagnostics = try await store.diagnostics()
        return "\(diagnostics.observationCount):\(diagnostics.eventCount)"
    }
}
