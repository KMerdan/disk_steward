import Foundation
import XCTest
@testable import DiskStewardCore

/// TASK-531: the scan frontier is bounded in memory, streams each directory
/// once per pass, spills discovery into durable rows, and restarts only the
/// unfinished pass when its in-process stream is lost.
final class BoundedFrontierTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let root: URL
        let databaseURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "bounded-frontier-\(UUID().uuidString)", directoryHint: .isDirectory)
            root = directory.appending(path: "watch", directoryHint: .isDirectory)
            databaseURL = directory.appending(path: "evidence.sqlite")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func policy(maximumEntries: Int) -> MonitoringPolicy {
            MonitoringPolicy(watchedRoots: [root], maximumEntries: maximumEntries, maximumDepth: 8)
        }
    }

    private static func snapshot(_ index: Int) -> StorageSnapshot {
        StorageSnapshot(snapshotID: "frontier-volume-\(index)", observedAt: "2036-07-18T13:20:00.000Z",
                        volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)])
    }

    private struct Run {
        var slices = 0
        var inspected = 0
        var passes = 0
        var restarts = 0
        var peakRetained = 0
        var peakWindow = 0
        var peakPendingRows: Int64 = 0
        var peakProgressBytes: Int64 = 0
        var sawDurablePending = false
        var observation: ObservationCommitResult?
    }

    /// Drives slices with the given scanner until publication or the attempt cap.
    private func complete(store: EvidenceStore, reader: SQLiteConnection, scanner: DirectoryMetadataScanner,
                          policy: MonitoringPolicy, start: Date, attempts: Int = 400) async throws -> Run {
        var run = Run()
        let scope = policy.scopeVersion(at: start)
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        for attempt in 0..<attempts {
            let slice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(Double(attempt + 1)))
            run.inspected += slice.diagnostics.directoryEntriesInspected
            run.passes += slice.diagnostics.directoryEnumerationPasses
            run.restarts += slice.diagnostics.directoryChangeRestarts
            run.peakRetained = max(run.peakRetained, slice.diagnostics.peakRetainedDirectoryNames)
            let commit = try await store.recordScanSlice(snapshot: Self.snapshot(attempt), slice: slice, scope: scope, trigger: .scheduled)
            run.slices += 1
            generation = commit.generation
            run.peakWindow = max(run.peakWindow, generation.roots.reduce(0) { $0 + $1.frontier.count })
            let pending = try reader.scalarInt("SELECT COUNT(*) FROM scan_frontier WHERE generation_id = '\(generation.generationID)'")
            run.peakPendingRows = max(run.peakPendingRows, pending)
            if pending > 0 { run.sawDurablePending = true }
            run.peakProgressBytes = max(run.peakProgressBytes, try reader.scalarInt("SELECT COALESCE(MAX(length(progress)), 0) FROM scan_generations"))
            if let observation = commit.observation { run.observation = observation; break }
            if generation.status == .abandoned { break }
        }
        return run
    }

    func testWideDirectoryStreamsOnceAcrossSlicesWithoutRereading() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let count = 2_000
        for index in 0..<count { try Data([1]).write(to: fixture.root.appending(path: String(format: "wide-%05d", index))) }
        let store = try EvidenceStore(url: fixture.databaseURL)
        let reader = try SQLiteConnection(url: fixture.databaseURL)
        defer { reader.close() }
        let policy = fixture.policy(maximumEntries: 100)
        let run = try await complete(store: store, reader: reader, scanner: DirectoryMetadataScanner(), policy: policy, start: Date(timeIntervalSince1970: 2_200_000_000))
        XCTAssertNotNil(run.observation, "The wide directory must publish")
        let published1 = try await store.currentFiles()
        XCTAssertEqual(published1.count, count)
        // One pass streams the directory exactly once: no quadratic rereads.
        XCTAssertEqual(run.passes, 1)
        XCTAssertEqual(run.inspected, count)
        XCTAssertEqual(run.restarts, 0)
        XCTAssertLessThanOrEqual(run.peakRetained, 100)
        XCTAssertEqual(DirectoryStreamRegistry.shared.openStreamCount, 0, "Completed passes release their streams")
        await store.close()
    }

    func testHighFanoutSpillsDiscoveryIntoDurableRowsAndKeepsTheWindowBounded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directories = 300
        for index in 0..<directories {
            let child = fixture.root.appending(path: String(format: "d-%04d", index), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data([2]).write(to: child.appending(path: "leaf"))
        }
        let store = try EvidenceStore(url: fixture.databaseURL)
        let reader = try SQLiteConnection(url: fixture.databaseURL)
        defer { reader.close() }
        let run = try await complete(store: store, reader: reader, scanner: DirectoryMetadataScanner(), policy: fixture.policy(maximumEntries: 50), start: Date(timeIntervalSince1970: 2_200_001_000))
        XCTAssertNotNil(run.observation)
        let published2 = try await store.currentFiles()
        XCTAssertEqual(published2.count, directories)
        XCTAssertLessThanOrEqual(run.peakWindow, DirectoryMetadataScanner.frontierWindowSize)
        XCTAssertTrue(run.sawDurablePending, "Directories beyond the window live in scan_frontier rows")
        XCTAssertGreaterThan(run.peakPendingRows, 100)
        XCTAssertLessThan(run.peakProgressBytes, 32 * 1_024, "Persisted progress stays bounded by the window, not the tree width")
        XCTAssertEqual(try reader.scalarInt("SELECT COUNT(*) FROM scan_frontier"), 0, "Completion reclaims the durable frontier")
        // The summary's pending count included durable rows while scanning.
        let summary = try await store.scanCoverageStatus()
        XCTAssertEqual(summary?.latestGeneration?.status, .completed)
        await store.close()
    }

    func testLostStreamRestartsOnlyTheUnfinishedPassWithoutStaleMembership() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let count = 300
        for index in 0..<count { try Data([3]).write(to: fixture.root.appending(path: String(format: "file-%04d", index))) }
        let store = try EvidenceStore(url: fixture.databaseURL)
        let reader = try SQLiteConnection(url: fixture.databaseURL)
        defer { reader.close() }
        let policy = fixture.policy(maximumEntries: 100)
        let start = Date(timeIntervalSince1970: 2_200_002_000)
        let scope = policy.scopeVersion(at: start)
        // Process one: a private registry whose stream is then lost.
        let firstProcess = DirectoryStreamRegistry()
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        let first = DirectoryMetadataScanner(streams: firstProcess).scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(1))
        XCTAssertEqual(first.entries.count, 100)
        XCTAssertEqual(firstProcess.openStreamCount, 1, "The unfinished pass keeps its stream open in process one")
        generation = try await store.recordScanSlice(snapshot: Self.snapshot(0), slice: first, scope: scope, trigger: .scheduled).generation
        firstProcess.closeAll()
        // Process two: no stream for the persisted pass, so the pass restarts.
        let secondProcess = DirectoryStreamRegistry()
        let run = try await complete(store: store, reader: reader, scanner: DirectoryMetadataScanner(streams: secondProcess), policy: policy, start: start.addingTimeInterval(10))
        XCTAssertNotNil(run.observation)
        XCTAssertEqual(run.restarts, 1, "Exactly the unfinished pass restarted")
        XCTAssertEqual(run.inspected, count, "The restarted pass streams the directory once")
        let published = try await store.currentFiles()
        XCTAssertEqual(published.count, count)
        XCTAssertEqual(Set(published.map(\.path)).count, count, "No duplicate or stale membership survives the restart")
        XCTAssertEqual(secondProcess.openStreamCount, 0)
        await store.close()
    }

    func testLegacyOversizedFrontierIsSpilledIntoDurableRowsOnResume() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let policy = fixture.policy(maximumEntries: 50)
        let start = Date(timeIntervalSince1970: 2_200_003_000)
        let scope = policy.scopeVersion(at: start)
        let store = try EvidenceStore(url: fixture.databaseURL)
        let created = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        await store.close()
        // Overwrite the persisted progress with a legacy whole-frontier array.
        let cursors = (0..<200).map { MetadataScanDirectoryCursor(directoryPath: fixture.root.appending(path: "legacy-\($0)").path, depth: 1) }
        let legacy = MetadataScanGeneration(
            generationID: created.generationID, scopeVersionID: created.scopeVersionID, rootPaths: created.rootPaths,
            excludedPaths: created.excludedPaths, status: .active,
            roots: [.init(rootPath: fixture.root.path, status: .active, frontier: cursors)],
            processedEntryCount: 0, stagedFileCount: 0, startedAt: start, updatedAt: start,
            reconciliationToken: created.reconciliationToken)
        let connection = try SQLiteConnection(url: fixture.databaseURL)
        let payload = try JSONEncoder().encode(legacy)
        try connection.withStatement("UPDATE scan_generations SET progress = ? WHERE generation_id = ?") { statement in
            try connection.bind(payload, at: 1, in: statement)
            try connection.bind(created.generationID, at: 2, in: statement)
            try connection.stepDone(statement)
        }
        XCTAssertGreaterThan(try connection.scalarInt("SELECT length(progress) FROM scan_generations"), 20_000)
        let reopened = try EvidenceStore(url: fixture.databaseURL)
        let resumed = try await reopened.beginOrResumeScanGeneration(scope: scope, at: start.addingTimeInterval(5))
        XCTAssertEqual(resumed.generationID, created.generationID)
        XCTAssertEqual(resumed.roots.first?.frontier.count, DirectoryMetadataScanner.frontierWindowSize)
        XCTAssertEqual(resumed.roots.first?.pendingDirectoryCount, 200 - DirectoryMetadataScanner.frontierWindowSize)
        XCTAssertEqual(try connection.scalarInt("SELECT COUNT(*) FROM scan_frontier"), Int64(200 - DirectoryMetadataScanner.frontierWindowSize))
        XCTAssertLessThan(try connection.scalarInt("SELECT length(progress) FROM scan_generations"), 20_000)
        connection.close()
        await reopened.close()
    }

    func testStreamRegistryDeliversEachNameOnceAcrossBoundedReads() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for index in 0..<3_000 { try Data([4]).write(to: fixture.root.appending(path: String(format: "n-%05d", index))) }
        let registry = DirectoryStreamRegistry()
        var names: [String] = []
        var reads = 0
        while true {
            let batch = try registry.read(passID: "pass-a", directoryPath: fixture.root.path, limit: 512)
            reads += 1
            XCTAssertLessThanOrEqual(batch.names.count, 512)
            XCTAssertEqual(batch.opened, reads == 1)
            names += batch.names
            if batch.exhausted { break }
        }
        XCTAssertEqual(names.count, 3_000)
        XCTAssertEqual(Set(names).count, 3_000)
        XCTAssertEqual(registry.openStreamCount, 1)
        registry.close(passID: "pass-a")
        XCTAssertEqual(registry.openStreamCount, 0)
    }

    func testStreamRegistryEvictsTheLeastRecentlyUsedStreamBeyondItsBound() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let registry = DirectoryStreamRegistry()
        for index in 0..<(DirectoryStreamRegistry.maximumOpenStreams + 8) {
            _ = try registry.read(passID: "pass-\(index)", directoryPath: fixture.root.path, limit: 1)
        }
        XCTAssertEqual(registry.openStreamCount, DirectoryStreamRegistry.maximumOpenStreams)
        XCTAssertFalse(registry.contains(passID: "pass-0"), "The oldest stream was evicted; its pass will restart")
        XCTAssertTrue(registry.contains(passID: "pass-\(DirectoryStreamRegistry.maximumOpenStreams + 7)"))
        registry.closeAll()
        XCTAssertEqual(registry.openStreamCount, 0)
    }
}
