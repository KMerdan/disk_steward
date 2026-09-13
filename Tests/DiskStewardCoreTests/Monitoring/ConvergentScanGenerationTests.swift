import Foundation
import XCTest
@testable import DiskStewardCore

final class ConvergentScanGenerationTests: XCTestCase, @unchecked Sendable {
    func testSmallSlicesResumeReconcileOnlyWhenCompleteAndDeleteBAfterFullSecondGeneration() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 10)
        try fixture.write("B", bytes: 20)
        try fixture.write("C", bytes: 30)
        let policy = fixture.policy(maximumEntries: 2)
        let scanner = DirectoryMetadataScanner()
        let start = Date(timeIntervalSince1970: 2_100_000_000)

        var store: EvidenceStore? = try EvidenceStore(url: fixture.databaseURL)
        var generation = try await store!.beginOrResumeScanGeneration(scope: policy.scopeVersion(at: start), at: start)
        let firstSlice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(1))
        let firstCommit = try await store!.recordScanSlice(
            snapshot: Self.snapshot(1),
            slice: firstSlice,
            scope: policy.scopeVersion(at: start),
            trigger: .startup
        )
        XCTAssertNil(firstCommit.observation)
        XCTAssertEqual(firstCommit.generation.status, .active)
        XCTAssertLessThanOrEqual(firstCommit.generation.processedEntryCount, 2)
        let currentBeforeRestart = try await store!.currentFiles(includeNonActionable: true)
        XCTAssertTrue(currentBeforeRestart.isEmpty, "An incomplete generation must not become authoritative current state")
        let generationID = firstCommit.generation.generationID
        await store!.close()
        store = nil

        store = try EvidenceStore(url: fixture.databaseURL)
        generation = try await store!.beginOrResumeScanGeneration(scope: policy.scopeVersion(at: start), at: start.addingTimeInterval(2))
        XCTAssertEqual(generation.generationID, generationID)
        XCTAssertEqual(generation.processedEntryCount, firstCommit.generation.processedEntryCount)

        var baseline: ObservationCommitResult?
        var baselineSlices = 1
        while baseline == nil, baselineSlices < 20 {
            let now = start.addingTimeInterval(Double(baselineSlices + 2))
            let slice = scanner.scanSlice(policy: policy, generation: generation, at: now)
            let commit = try await store!.recordScanSlice(
                snapshot: Self.snapshot(baselineSlices + 1),
                slice: slice,
                scope: policy.scopeVersion(at: start),
                trigger: .startup
            )
            generation = commit.generation
            baseline = commit.observation
            baselineSlices += 1
        }
        let completedBaseline = try XCTUnwrap(baseline)
        XCTAssertGreaterThan(baselineSlices, 1)
        XCTAssertEqual(completedBaseline.currentFiles.map(\.path).sorted(), fixture.paths(["A", "B", "C"]))
        XCTAssertEqual(generation.stagedFileCount, 3)
        let baselineCoverage = try await store!.scanCoverageStatus()
        XCTAssertEqual(baselineCoverage?.detailCoverage, "complete")

        try FileManager.default.removeItem(at: fixture.root.appending(path: "B"))
        generation = try await store!.beginOrResumeScanGeneration(
            scope: policy.scopeVersion(at: start),
            at: start.addingTimeInterval(100)
        )
        var deletion: ObservationCommitResult?
        var deletionSlices = 0
        while deletion == nil, deletionSlices < 20 {
            let now = start.addingTimeInterval(Double(101 + deletionSlices))
            let slice = scanner.scanSlice(policy: policy, generation: generation, at: now)
            let commit = try await store!.recordScanSlice(
                snapshot: Self.snapshot(100 + deletionSlices),
                slice: slice,
                scope: policy.scopeVersion(at: start),
                trigger: .scheduled
            )
            generation = commit.generation
            deletion = commit.observation
            deletionSlices += 1
            if deletion == nil {
                let current = try await store!.currentFiles(includeNonActionable: true)
                XCTAssertNotNil(current.first { $0.path == fixture.root.appending(path: "B").path })
                let retainedEvents = try await store!.events(from: start, through: now, limit: 100)
                XCTAssertFalse(retainedEvents.contains { $0.operation == .delete })
            }
        }
        let completedDeletion = try XCTUnwrap(deletion)
        XCTAssertEqual(completedDeletion.events.filter { $0.operation == .delete }.map(\.path), [fixture.root.appending(path: "B").path])
        XCTAssertEqual(completedDeletion.currentFiles.map(\.path).sorted(), fixture.paths(["A", "C"]))
        XCTAssertEqual(Set(completedDeletion.currentFiles.map(\.path)).count, 2)
        await store!.close()
    }

    func testInvalidCursorAndScopeChangeAbandonStagingWithoutInventingDeletion() async throws {
        let fixture = try ConvergentScanFixture()
        let nested = fixture.root.appending(path: "0-folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8).write(to: nested.appending(path: "nested"))
        try fixture.write("A", bytes: 10)
        let scanner = DirectoryMetadataScanner()
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_001_000)
        let store = try EvidenceStore(url: fixture.databaseURL)

        var generation = try await store.beginOrResumeScanGeneration(scope: policy.scopeVersion(at: start), at: start)
        var slice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(1))
        var commit = try await store.recordScanSlice(
            snapshot: Self.snapshot(200),
            slice: slice,
            scope: policy.scopeVersion(at: start),
            trigger: .startup
        )
        XCTAssertNil(commit.observation)
        try FileManager.default.removeItem(at: nested)

        var attempts = 0
        while commit.generation.status == .active, attempts < 10 {
            generation = commit.generation
            slice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(Double(2 + attempts)))
            commit = try await store.recordScanSlice(
                snapshot: Self.snapshot(201 + attempts),
                slice: slice,
                scope: policy.scopeVersion(at: start),
                trigger: .startup
            )
            attempts += 1
        }
        XCTAssertEqual(commit.generation.status, .abandoned)
        XCTAssertTrue(commit.generation.limitations.contains { $0.contains("cursor became invalid") })
        XCTAssertNil(commit.observation)
        let currentAfterInvalidCursor = try await store.currentFiles(includeNonActionable: true)
        XCTAssertTrue(currentAfterInvalidCursor.isEmpty)

        generation = try await store.beginOrResumeScanGeneration(scope: policy.scopeVersion(at: start), at: start.addingTimeInterval(20))
        slice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(21))
        commit = try await store.recordScanSlice(
            snapshot: Self.snapshot(220),
            slice: slice,
            scope: policy.scopeVersion(at: start),
            trigger: .recovery
        )
        let oldGenerationID = commit.generation.generationID
        let changedPolicy = fixture.policy(maximumEntries: 1, exclusions: [fixture.root.appending(path: "A")])
        let replacement = try await store.beginOrResumeScanGeneration(
            scope: changedPolicy.scopeVersion(at: start.addingTimeInterval(22)),
            at: start.addingTimeInterval(22)
        )
        XCTAssertNotEqual(replacement.generationID, oldGenerationID)
        let history = try await store.scanGenerations()
        let abandoned = try XCTUnwrap(history.first { $0.generationID == oldGenerationID })
        XCTAssertEqual(abandoned.status, .abandoned)
        XCTAssertTrue(abandoned.limitations.contains { $0.contains("Scope version changed") })
        let currentAfterScopeChange = try await store.currentFiles(includeNonActionable: true)
        XCTAssertTrue(currentAfterScopeChange.isEmpty)
        let coverageValue = try await store.scanCoverageStatus()
        let coverage = try XCTUnwrap(coverageValue)
        XCTAssertEqual(coverage.configuredRoots, [fixture.root.path])
        XCTAssertEqual(coverage.excludedPaths, [fixture.root.appending(path: "A").path])
        XCTAssertEqual(coverage.detailCoverage, "partial")
        XCTAssertEqual(coverage.activeGeneration?.generationID, replacement.generationID)
        let lifecycle = try await store.lifecycleStatus(try .init(), at: start.addingTimeInterval(23))
        XCTAssertEqual(lifecycle.scanCoverage?.activeGeneration?.generationID, replacement.generationID)
        XCTAssertTrue(lifecycle.observationGaps.contains {
            $0.observationID == replacement.generationID && $0.reason == "scan-generation-incomplete"
        })
        await store.close()
    }

    private static func snapshot(_ index: Int) -> StorageSnapshot {
        StorageSnapshot(
            snapshotID: "convergent-volume-\(index)",
            observedAt: "2036-07-18T13:20:00.000Z",
            volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)]
        )
    }
}

private final class ConvergentScanFixture {
    let directory: URL
    let root: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        root = directory.appending(path: "watch", directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "evidence.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ name: String, bytes: Int) throws {
        try Data(repeating: UInt8(bytes), count: bytes).write(to: root.appending(path: name))
    }

    func paths(_ names: [String]) -> [String] {
        names.map { root.appending(path: $0).path }.sorted()
    }

    func policy(maximumEntries: Int, exclusions: [URL] = []) -> MonitoringPolicy {
        MonitoringPolicy(
            watchedRoots: [root],
            excludedRoots: exclusions,
            maximumEntries: maximumEntries,
            maximumDepth: 8
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
