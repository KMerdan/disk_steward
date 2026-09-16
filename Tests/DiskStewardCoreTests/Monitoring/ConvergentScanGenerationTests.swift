import Foundation
import XCTest
@testable import DiskStewardCore

final class DirectoryMetadataScannerConvergentScanGenerationTests: XCTestCase, @unchecked Sendable {
    func testUnchangedCompletedGenerationsDoNotMultiplyFileHistory() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 10)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_004_000)
        let store = try EvidenceStore(url: fixture.databaseURL)

        _ = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 400)
        let replay = try await Self.completeGeneration(
            store: store,
            policy: policy,
            start: start.addingTimeInterval(60),
            snapshotBase: 450
        )
        let diagnostics = try await store.diagnostics()

        XCTAssertEqual(replay.persistedEventCount, 0)
        XCTAssertEqual(diagnostics.observationCount, 2)
        XCTAssertEqual(diagnostics.currentFileCount, 1)
        XCTAssertEqual(diagnostics.fileStateObservationCount, 1)
        await store.close()
    }

    func testCompletedGenerationReconcilesLargeStateWithBoundedInlineResult() async throws {
        let fixture = try ConvergentScanFixture()
        let policy = fixture.policy(maximumEntries: 512)
        let start = Date(timeIntervalSince1970: 2_100_005_000)
        let scope = policy.scopeVersion(at: start)
        let store = try EvidenceStore(url: fixture.databaseURL)
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        var finalResult: ObservationCommitResult?

        for lowerBound in stride(from: 0, to: 2_500, by: 512) {
            let upperBound = min(lowerBound + 512, 2_500)
            let isFinal = upperBound == 2_500
            let entries = (lowerBound ..< upperBound).map { index in
                FileMetadata(
                    objectID: "object-\(index)",
                    identityMethod: .pathTemporal,
                    rootPath: fixture.root.path,
                    path: fixture.root.appending(path: String(format: "item-%05d", index)).path,
                    logicalBytes: Int64(index + 1),
                    allocatedBytes: Int64(index + 1),
                    modifiedAt: start
                )
            }
            generation = MetadataScanGeneration(
                generationID: generation.generationID,
                scopeVersionID: generation.scopeVersionID,
                rootPaths: generation.rootPaths,
                excludedPaths: generation.excludedPaths,
                status: isFinal ? .completed : .active,
                roots: [.init(
                    rootPath: fixture.root.path,
                    status: isFinal ? .completed : .active,
                    frontier: isFinal ? [] : [.init(directoryPath: fixture.root.path, depth: 0, afterName: "item-\(upperBound)")],
                    processedEntryCount: upperBound,
                    observedFileCount: upperBound
                )],
                processedEntryCount: upperBound,
                stagedFileCount: upperBound,
                startedAt: start,
                updatedAt: start.addingTimeInterval(Double(upperBound)),
                completedAt: isFinal ? start.addingTimeInterval(Double(upperBound)) : nil
            )
            let commit = try await store.recordScanSlice(
                snapshot: Self.snapshot(500 + lowerBound),
                slice: .init(generation: generation, entries: entries),
                scope: scope,
                trigger: .scheduled
            )
            generation = commit.generation
            finalResult = commit.observation ?? finalResult
        }

        let result = try XCTUnwrap(finalResult)
        XCTAssertEqual(result.persistedEventCount, 2_500)
        XCTAssertEqual(result.events.count, 2_048)
        XCTAssertEqual(result.currentFileCount, 2_500)
        XCTAssertEqual(result.currentFiles.count, 2_048)
        XCTAssertTrue(result.resultWindowTruncated)
        let allCurrentFiles = try await store.currentFiles(includeNonActionable: true)
        XCTAssertEqual(allCurrentFiles.count, 2_500)
        await store.close()
    }

    func testReconciliationIsAtomicAcrossEveryInjectedInterruptionBoundary() async throws {
        for checkpoint in ["after-observation", "after-present-objects", "after-missing-objects", "before-finalize"] {
            let fixture = try ConvergentScanFixture()
            try fixture.write("A", bytes: 10)
            try fixture.write("B", bytes: 20)
            let policy = fixture.policy(maximumEntries: 1)
            let start = Date(timeIntervalSince1970: 2_100_006_000)
            let arm = ReconciliationCheckpointArm()
            var store: EvidenceStore? = try EvidenceStore(
                url: fixture.databaseURL,
                reconciliationCheckpoint: { try arm.check($0) }
            )
            _ = try await Self.completeGeneration(store: store!, policy: policy, start: start, snapshotBase: 600)
            try FileManager.default.removeItem(at: fixture.root.appending(path: "B"))
            arm.value = checkpoint

            do {
                _ = try await Self.completeGeneration(
                    store: store!,
                    policy: policy,
                    start: start.addingTimeInterval(100),
                    snapshotBase: 700
                )
                XCTFail("Expected injected interruption at \(checkpoint)")
            } catch ReconciliationCheckpointFailure.injected {
                // Expected. SQLite must have rolled the entire reconciliation back.
            }
            let retainedPaths = try await store!.currentFiles(includeNonActionable: true).map(\.path).sorted()
            XCTAssertEqual(
                retainedPaths,
                fixture.paths(["A", "B"]),
                "Last-known-good state changed at \(checkpoint)"
            )
            await store!.close()
            store = nil

            store = try EvidenceStore(url: fixture.databaseURL)
            let recovered = try await Self.completeGeneration(
                store: store!,
                policy: policy,
                start: start.addingTimeInterval(200),
                snapshotBase: 800
            )
            XCTAssertEqual(recovered.currentFiles.map(\.path), fixture.paths(["A"]))
            XCTAssertEqual(recovered.events.filter { $0.operation == .delete }.map(\.path), fixture.paths(["B"]))
            await store!.close()
        }
    }

    func testEventGapPersistsAcrossRestartUntilCompleteReconciliation() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 1)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_007_000)
        var store: EvidenceStore? = try EvidenceStore(url: fixture.databaseURL)
        try await store!.recordReconciliationInvalidation(at: start)
        let pendingBeforeRestart = try await store!.hasPendingReconciliation()
        XCTAssertTrue(pendingBeforeRestart)
        await store!.close()
        store = nil

        store = try EvidenceStore(url: fixture.databaseURL)
        let pendingAfterRestart = try await store!.hasPendingReconciliation()
        XCTAssertTrue(pendingAfterRestart)
        let result = try await Self.completeGeneration(store: store!, policy: policy, start: start.addingTimeInterval(1), snapshotBase: 900)

        let pendingAfterCompletion = try await store!.hasPendingReconciliation()
        XCTAssertFalse(pendingAfterCompletion)
        let eventGap = try XCTUnwrap(result.coverageGaps.first { $0.reason == "event-drop" })
        XCTAssertEqual(eventGap.startedAt, start)
        XCTAssertNotNil(eventGap.endedAt)
        await store!.close()
    }

    func testRepeatedEventGapsCoalesceUntilReconciliationAndCanReopen() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 1)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_007_100)
        let store = try EvidenceStore(url: fixture.databaseURL)

        try await store.recordReconciliationInvalidation(at: start.addingTimeInterval(10))
        try await store.recordReconciliationInvalidation(at: start)
        try await store.recordReconciliationInvalidation(at: start.addingTimeInterval(20))
        let pendingBeforeCompletion = try await store.pendingReconciliationCount()
        XCTAssertEqual(pendingBeforeCompletion, 1)

        let first = try await Self.completeGeneration(
            store: store,
            policy: policy,
            start: start.addingTimeInterval(30),
            snapshotBase: 950
        )
        XCTAssertEqual(first.coverageGaps.first { $0.reason == "event-drop" }?.startedAt, start)
        let pendingAfterCompletion = try await store.pendingReconciliationCount()
        XCTAssertEqual(pendingAfterCompletion, 0)

        try await store.recordReconciliationInvalidation(at: start.addingTimeInterval(40))
        let pendingAfterReopen = try await store.pendingReconciliationCount()
        XCTAssertEqual(pendingAfterReopen, 1)
        await store.close()
    }

    func testLegacyPersistedGenerationDecodesWithoutNewCursorFields() throws {
        let generation = MetadataScanGeneration(
            generationID: "legacy",
            scopeVersionID: "scope",
            rootPaths: ["/tmp/watch"],
            excludedPaths: [],
            status: .active,
            roots: [.init(
                rootPath: "/tmp/watch",
                status: .active,
                frontier: [.init(directoryPath: "/tmp/watch", depth: 0, afterName: "B")]
            )],
            processedEntryCount: 1,
            stagedFileCount: 1,
            startedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let encoded = try JSONEncoder().encode(generation)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "schedulerCursor")
        var roots = try XCTUnwrap(object["roots"] as? [[String: Any]])
        var frontier = try XCTUnwrap(roots[0]["frontier"] as? [[String: Any]])
        frontier[0].removeValue(forKey: "directorySignature")
        roots[0]["frontier"] = frontier
        object["roots"] = roots

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MetadataScanGeneration.self, from: legacyData)

        XCTAssertNil(decoded.schedulerCursor)
        XCTAssertNil(decoded.roots[0].frontier[0].directorySignature)
        XCTAssertEqual(decoded.roots[0].frontier[0].afterName, "B")
    }

    func testHighFanoutSliceUsesOneStreamingPassAndRetainsOnlyItsBudget() throws {
        let fixture = try ConvergentScanFixture()
        for index in 0 ..< 2_000 {
            try fixture.write(String(format: "entry-%05d", index), bytes: 1)
        }
        let policy = fixture.policy(maximumEntries: 64)
        let start = Date(timeIntervalSince1970: 2_100_002_000)
        let scope = policy.scopeVersion(at: start)
        let generation = MetadataScanGeneration(
            generationID: "high-fanout",
            scopeVersionID: scope.scopeVersionID,
            rootPaths: scope.rootPaths,
            excludedPaths: scope.excludedPaths,
            status: .active,
            roots: scope.rootPaths.map { .init(rootPath: $0) },
            processedEntryCount: 0,
            stagedFileCount: 0,
            startedAt: start,
            updatedAt: start
        )

        let slice = DirectoryMetadataScanner().scanSlice(
            policy: policy,
            generation: generation,
            at: start.addingTimeInterval(1)
        )

        XCTAssertEqual(slice.entries.count, 64)
        XCTAssertEqual(slice.diagnostics.directoryEnumerationPasses, 1)
        XCTAssertEqual(slice.diagnostics.directoryEntriesInspected, 2_000)
        XCTAssertEqual(slice.diagnostics.peakRetainedDirectoryNames, 64)
        XCTAssertEqual(slice.generation.status, .active)
    }

    func testBoundedSelectorKeepsOnlyFirstBatchAcrossOneHundredThousandNames() {
        var selector = BoundedMaxNameHeap(capacity: 512)
        for index in (0 ..< 100_000).reversed() {
            selector.insert(String(format: "entry-%06d", index))
        }

        XCTAssertEqual(selector.retainedCount, 512)
        XCTAssertEqual(selector.sortedValues().first, "entry-000000")
        XCTAssertEqual(selector.sortedValues().last, "entry-000511")
    }

    func testDirectoryChangeBeforeResumeResetsCursorAndDoesNotSkipEarlierName() throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("B", bytes: 2)
        try fixture.write("C", bytes: 3)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_003_000)
        let scope = policy.scopeVersion(at: start)
        var generation = MetadataScanGeneration(
            generationID: "mutation-resume",
            scopeVersionID: scope.scopeVersionID,
            rootPaths: scope.rootPaths,
            excludedPaths: scope.excludedPaths,
            status: .active,
            roots: scope.rootPaths.map { .init(rootPath: $0) },
            processedEntryCount: 0,
            stagedFileCount: 0,
            startedAt: start,
            updatedAt: start
        )
        let scanner = DirectoryMetadataScanner()
        var seen = Set<String>()

        var slice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(1))
        seen.formUnion(slice.entries.map(\.path))
        generation = slice.generation
        XCTAssertEqual(slice.entries.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["B"])

        // Ensure a distinct directory timestamp even on coarse filesystems.
        Thread.sleep(forTimeInterval: 0.01)
        try fixture.write("A", bytes: 1)
        slice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(2))
        XCTAssertEqual(slice.diagnostics.directoryChangeRestarts, 1)
        XCTAssertEqual(slice.entries.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["A"])
        seen.formUnion(slice.entries.map(\.path))
        generation = slice.generation

        var attempts = 0
        while generation.status == .active, attempts < 10 {
            slice = scanner.scanSlice(
                policy: policy,
                generation: generation,
                at: start.addingTimeInterval(Double(3 + attempts))
            )
            seen.formUnion(slice.entries.map(\.path))
            generation = slice.generation
            attempts += 1
        }

        XCTAssertEqual(generation.status, .completed)
        XCTAssertEqual(seen, Set(fixture.paths(["A", "B", "C"])))
    }

    func testMultipleRootsReceiveWorkInTheSameBoundedSlice() throws {
        let fixture = try ConvergentScanFixture()
        let secondRoot = fixture.directory.appending(path: "watch-two", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        for index in 0 ..< 10 {
            try fixture.write("first-\(index)", bytes: 1)
            try Data([1]).write(to: secondRoot.appending(path: "second-\(index)"))
        }
        let policy = MonitoringPolicy(watchedRoots: [fixture.root, secondRoot], maximumEntries: 4, maximumDepth: 8)
        let start = Date(timeIntervalSince1970: 2_100_004_000)
        let scope = policy.scopeVersion(at: start)
        let generation = MetadataScanGeneration(
            generationID: "fair-roots",
            scopeVersionID: scope.scopeVersionID,
            rootPaths: scope.rootPaths,
            excludedPaths: scope.excludedPaths,
            status: .active,
            roots: scope.rootPaths.map { .init(rootPath: $0) },
            processedEntryCount: 0,
            stagedFileCount: 0,
            startedAt: start,
            updatedAt: start
        )

        let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(1))
        XCTAssertEqual(slice.entries.count, 4)
        XCTAssertEqual(Set(slice.entries.map(\.rootPath)), Set(scope.rootPaths))
        XCTAssertEqual(slice.diagnostics.directoryEnumerationPasses, 2)
        XCTAssertLessThanOrEqual(slice.diagnostics.peakRetainedDirectoryNames, 2)
    }

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

    private static func completeGeneration(
        store: EvidenceStore,
        policy: MonitoringPolicy,
        start: Date,
        snapshotBase: Int
    ) async throws -> ObservationCommitResult {
        let scanner = DirectoryMetadataScanner()
        var generation = try await store.beginOrResumeScanGeneration(scope: policy.scopeVersion(at: start), at: start)
        for attempt in 0 ..< 100 {
            let slice = scanner.scanSlice(
                policy: policy,
                generation: generation,
                at: start.addingTimeInterval(Double(attempt + 1))
            )
            let commit = try await store.recordScanSlice(
                snapshot: snapshot(snapshotBase + attempt),
                slice: slice,
                scope: policy.scopeVersion(at: start),
                trigger: .scheduled
            )
            generation = commit.generation
            if let observation = commit.observation { return observation }
        }
        throw ReconciliationCheckpointFailure.didNotComplete
    }
}

private enum ReconciliationCheckpointFailure: Error {
    case injected
    case didNotComplete
}

private final class ReconciliationCheckpointArm: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func check(_ checkpoint: String) throws {
        let shouldThrow = lock.withLock { () -> Bool in
            guard storage == checkpoint else { return false }
            storage = nil
            return true
        }
        if shouldThrow { throw ReconciliationCheckpointFailure.injected }
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
