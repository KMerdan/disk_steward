import Foundation
import SQLite3
import XCTest
@testable import DiskStewardCore

/// TASK-532: one storage accounting admits or refuses work explicitly. The
/// next publication's reserve is held back from the cap, retention targets the
/// refused demand, authoritative current state is never evicted, a
/// reader-pinned write-ahead log and a full volume are reported for what they
/// are, and an interrupted retention run is recovered as an explicit failure.
final class StorageHeadroomTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let root: URL
        let databaseURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "storage-headroom-\(UUID().uuidString)", directoryHint: .isDirectory)
            root = directory.appending(path: "watch", directoryHint: .isDirectory)
            databaseURL = directory.appending(path: "evidence.sqlite")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func makeFiles(_ count: Int, prefix: String = "f") throws {
            for index in 0..<count {
                try Data([UInt8(index % 251)]).write(to: root.appending(path: String(format: "%@-%05d", prefix, index)))
            }
        }

        var policy: MonitoringPolicy { MonitoringPolicy(watchedRoots: [root], maximumEntries: 512, maximumDepth: 8) }
    }

    private static let start = Date(timeIntervalSince1970: 2_100_000_000)
    private static let mebibyte: Int64 = 1_024 * 1_024

    private static func snapshot(_ index: Int) -> StorageSnapshot {
        StorageSnapshot(snapshotID: "headroom-volume-\(index)", observedAt: EvidenceTimestamp.format(start.addingTimeInterval(Double(index))),
                        volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)])
    }

    private static func event(_ index: Int) -> EvidenceStoreEvent {
        EvidenceStoreEvent(
            eventID: "headroom-event-\(index)", observedAt: start.addingTimeInterval(-Double(index % 3_600)), operation: .writeSummary,
            path: "/fixture/cache/segment-\(index % 97).bin", logicalDelta: 4_096, allocatedDelta: 4_096,
            consumerCategory: "developer-cache", confidence: .inferred, isAnomaly: false
        )
    }

    /// Drives slices until publication, the attempt cap, or a thrown error.
    @discardableResult
    private func drive(store: EvidenceStore, fixture: Fixture, attempts: Int = 200, sliceIndex: Int = 0) async throws -> ObservationCommitResult? {
        let scanner = DirectoryMetadataScanner()
        let scope = fixture.policy.scopeVersion(at: Self.start)
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: Self.start)
        for attempt in 0..<attempts {
            let slice = scanner.scanSlice(policy: fixture.policy, generation: generation, at: Self.start.addingTimeInterval(Double(sliceIndex + attempt + 1)))
            let commit = try await store.recordScanSlice(snapshot: Self.snapshot(sliceIndex + attempt), slice: slice, scope: scope, trigger: .scheduled)
            generation = commit.generation
            if let observation = commit.observation { return observation }
            if generation.status != .active { return nil }
        }
        return nil
    }

    private func fillHistory(store: EvidenceStore, untilLiveExceeds floor: Int64, batch: Int = 1_000, maximumBatches: Int = 80) async throws -> EvidenceStorageAccounting {
        var accounting = try await store.storageAccounting()
        var batches = 0
        while accounting.liveBytes <= floor, batches < maximumBatches {
            try await store.insert((0..<batch).map { Self.event(batches * batch + $0) })
            batches += 1
            accounting = try await store.storageAccounting()
        }
        XCTAssertGreaterThan(accounting.liveBytes, floor, "History filling stopped after \(batches) batches")
        return accounting
    }

    // MARK: - Publication reserve

    func testStagingIsRefusedWhenThePublicationReserveWouldExceedTheCap() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeFiles(600)
        // Below the cap with history: a 2 MiB cap admits one 512-row slice on
        // its own, but not together with the 1.2 MB reserve its publication needs.
        let store = try EvidenceStore(url: fixture.databaseURL, maximumStorageBytes: 2 * Self.mebibyte)
        let reader = try SQLiteConnection(url: fixture.databaseURL)
        try await store.insert((0..<300).map { Self.event($0) })
        let filled = try await store.storageAccounting()
        XCTAssertLessThan(filled.committedBytes + 512 * 1_024 + 1_024, 2 * Self.mebibyte, "Fixture premise: the slice itself fits")
        XCTAssertEqual(filled.admission, .available, "Fixture premise: nothing is staged and no generation is open")

        do {
            try await drive(store: store, fixture: fixture, attempts: 1)
            XCTFail("512 staged rows need a 1.2 MB publication reserve that a 2 MiB cap cannot hold")
        } catch let EvidenceStoreError.storageHeadroomUnavailable(reason, demand, accounting) {
            XCTAssertEqual(reason, "publication-reserve")
            XCTAssertGreaterThan(demand, 512 * 1_024 + 512 * 2_304, "The demand carries staging, publication reserve and the next slice")
            XCTAssertEqual(accounting.capBytes, 2 * Self.mebibyte)
            XCTAssertEqual(accounting.stagedRowCount, 0, "The refusal happened before any row was staged")
            XCTAssertLessThan(accounting.headroomBytes, 0, "With a generation open, the next slice is the next work and it does not fit")
            XCTAssertEqual(accounting.admission, .retentionRequired, "The 300 events are evictable history")
            XCTAssertTrue(accounting.limitations.contains { $0.contains("retention can evict history") }, "\(accounting.limitations)")
        }
        XCTAssertEqual(try reader.scalarInt("SELECT COUNT(*) FROM scan_generation_entries"), 0, "Nothing was written")
        let generation = try await store.activeScanGeneration()
        XCTAssertEqual(generation?.status, .active, "The generation stays open at its committed progress")
        XCTAssertEqual(generation?.processedEntryCount, 0)
        let integrity = try await store.integrityCheck()
        XCTAssertEqual(integrity, "ok")
        await store.close()
    }

    func testOneRetentionRunTargetsTheRefusedDemandAndTheScanThenCompletes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeFiles(1_200)
        let cap = 10 * Self.mebibyte
        // A small log bound keeps the checkpointed log from inflating the
        // accounting while 6 MiB of live history is written.
        let store = try EvidenceStore(url: fixture.databaseURL, maximumStorageBytes: cap, walJournalSizeLimit: 256 * 1_024)
        let before = try await fillHistory(store: store, untilLiveExceeds: 6 * Self.mebibyte)
        XCTAssertTrue(before.evictableHistory)
        XCTAssertEqual(before.admission, .available)

        var refusedDemand: Int64 = 0
        do {
            try await drive(store: store, fixture: fixture, attempts: 3)
            XCTFail("1,200 files need about 4 MB of staging and reserve on top of 6 MiB of history")
        } catch let EvidenceStoreError.storageHeadroomUnavailable(reason, demand, accounting) {
            XCTAssertEqual(reason, "publication-reserve")
            XCTAssertTrue(accounting.evictableHistory)
            refusedDemand = demand
        }
        // An unrelated small write between the refusal and retention, admitted
        // or refused, must not erase the refused demand (static review finding
        // F1). With a generation open, a small write needs the same reserve and
        // is refused here; the demand survives either way.
        do { try await store.insert([Self.event(999_999)]) } catch let EvidenceStoreError.storageHeadroomUnavailable(reason, _, _) { XCTAssertEqual(reason, "publication-reserve") }

        let policy = try EvidenceStoreRetentionPolicy(maxDatabaseBytes: cap)
        let report = try await store.applyRetention(policy, trigger: .pressure)
        XCTAssertGreaterThan(report.forcedEvictions, 0, "Retention evicted history to meet the refused demand")
        let after = try await store.storageAccounting()
        XCTAssertLessThan(after.committedBytes, before.committedBytes)
        XCTAssertLessThanOrEqual(after.committedBytes + refusedDemand, cap, "Retention made room for exactly the refused demand")

        let observation = try await drive(store: store, fixture: fixture, attempts: 20, sliceIndex: 10)
        XCTAssertNotNil(observation, "The same work is admitted after retention made room")
        let published = try await store.currentFiles()
        XCTAssertEqual(published.count, 1_200)
        let settled = try await store.storageAccounting()
        XCTAssertEqual(settled.admission, .available)
        XCTAssertEqual(settled.stagedRowCount, 0)
        XCTAssertEqual(settled.reservedPublicationBytes, 0)
        await store.close()
    }

    // MARK: - Above the cap with nothing to evict

    func testAboveCapWithoutEvictableHistoryPreservesCurrentStateAndRefusesExplicitly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = 8_000
        try fixture.makeFiles(files)
        let generous = try EvidenceStore(url: fixture.databaseURL, maximumStorageBytes: 256 * Self.mebibyte)
        let published = try await drive(store: generous, fixture: fixture, attempts: 40)
        XCTAssertNotNil(published)
        await generous.close()

        let policy = try EvidenceStoreRetentionPolicy(maxDatabaseBytes: 10 * Self.mebibyte)
        let store = try EvidenceStore(url: fixture.databaseURL, maximumStorageBytes: policy.maxDatabaseBytes)
        let sized = try await store.storageAccounting()
        XCTAssertGreaterThan(sized.liveBytes, policy.maxDatabaseBytes, "8,000 published files exceed a 10 MiB cap")
        XCTAssertEqual(sized.admission, .retentionRequired, "Volume snapshots recorded with each slice are evictable history")

        let report = try await store.applyRetention(policy, trigger: .pressure)
        XCTAssertTrue(report.limitations.contains { $0.contains("no evictable history remains") }, "\(report.limitations)")

        let accounting = try await store.storageAccounting()
        XCTAssertGreaterThan(accounting.liveBytes, policy.maxDatabaseBytes, "Compaction cannot shrink authoritative state under the cap")
        XCTAssertEqual(accounting.admission, .capacityLimited)
        XCTAssertFalse(accounting.evictableHistory)
        XCTAssertTrue(accounting.limitations.contains { $0.contains("Nothing was evicted") }, "\(accounting.limitations)")
        let current = try await store.currentFiles()
        XCTAssertEqual(current.count, files, "Authoritative current state is never evicted")

        do {
            try await store.insert([Self.event(0)])
            XCTFail("New history must be refused above the cap")
        } catch let EvidenceStoreError.storageCapacityExceeded(currentBytes, capBytes) {
            XCTAssertEqual(capBytes, policy.maxDatabaseBytes)
            XCTAssertGreaterThan(currentBytes, capBytes)
        }
        let rescope = MonitoringPolicy(watchedRoots: [fixture.root], excludedRoots: [fixture.root.appending(path: "none")], maximumEntries: 512)
        do {
            _ = try await store.beginOrResumeScanGeneration(scope: rescope.scopeVersion(at: Self.start), at: Self.start)
            XCTFail("A new generation must be refused above the cap")
        } catch let EvidenceStoreError.storageCapacityExceeded(_, capBytes) {
            XCTAssertEqual(capBytes, policy.maxDatabaseBytes)
        }
        let status = try await store.lifecycleStatus(policy, at: Self.start)
        XCTAssertEqual(status.storage?.admission, .capacityLimited)
        let survivors = try await store.currentFiles()
        XCTAssertEqual(survivors.count, files)
        let integrity = try await store.integrityCheck()
        XCTAssertEqual(integrity, "ok")
        await store.close()
    }

    // MARK: - Reader-pinned write-ahead log

    func testReaderPinnedWriteAheadLogIsReportedAndReclaimedWhenTheReaderCloses() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cap = 4 * Self.mebibyte
        let store = try EvidenceStore(url: fixture.databaseURL, maximumStorageBytes: cap, walJournalSizeLimit: 64 * 1_024)
        try await store.insert([Self.event(0)])
        let reader = try SQLiteConnection(url: fixture.databaseURL)
        try reader.execute("BEGIN")
        XCTAssertEqual(try reader.scalarInt("SELECT COUNT(*) FROM events"), 1, "The reader now holds a snapshot")

        var accounting = try await store.storageAccounting()
        var batches = 0
        while accounting.walBytes < 1 * Self.mebibyte, batches < 40 {
            try await store.insert((0..<300).map { Self.event(1 + batches * 300 + $0) })
            batches += 1
            accounting = try await store.storageAccounting()
        }
        XCTAssertGreaterThanOrEqual(accounting.walBytes, 1 * Self.mebibyte, "The log grew past its bound behind the reader")
        XCTAssertTrue(accounting.walPinnedByReader)

        let needed = Int((cap - accounting.committedBytes) / 512) + 256
        do {
            try await store.insert((0..<needed).map { Self.event(100_000 + $0) })
            XCTFail("The pinned log counts against the cap")
        } catch let EvidenceStoreError.storageHeadroomUnavailable(reason, _, refused) {
            XCTAssertEqual(reason, "wal-pinned")
            XCTAssertTrue(refused.walPinnedByReader)
        }

        try reader.execute("END")
        let released = try await store.storageAccounting()
        XCTAssertFalse(released.walPinnedByReader)
        XCTAssertLessThan(released.walBytes, 64 * 1_024 + 4_096, "A fully checkpointed log is truncated")
        XCTAssertLessThan(released.committedBytes, accounting.committedBytes)
        try await store.insert((0..<needed).map { Self.event(100_000 + $0) })
        XCTAssertEqual(try reader.scalarInt("SELECT COUNT(*) FROM events"), Int64(1 + batches * 300 + needed))
        await store.close()
    }

    // MARK: - Interrupted retention

    func testInterruptedRetentionIsRecoveredOnReopenAsAnExplicitFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let crashImage = fixture.directory.appending(path: "crash/evidence.sqlite")
        try FileManager.default.createDirectory(at: crashImage.deletingLastPathComponent(), withIntermediateDirectories: true)
        let databasePath = fixture.databaseURL.path
        let imagePath = crashImage.path
        let store = try EvidenceStore(
            url: fixture.databaseURL,
            retentionCheckpoint: { stage in
                // The process dies right after tier compaction committed and the
                // log was truncated: the database file alone is the crash image.
                guard stage == "after-tier-compaction" else { return }
                try FileManager.default.copyItem(atPath: databasePath, toPath: imagePath)
            }
        )
        try await store.insert((0..<500).map { Self.event($0) })
        let policy = try EvidenceStoreRetentionPolicy()
        _ = try await store.applyRetention(policy, trigger: .manual)
        await store.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))

        let image = try SQLiteConnection(url: crashImage)
        XCTAssertEqual(try image.scalarInt("SELECT COUNT(*) FROM retention_runs WHERE result = 'started'"), 1, "The crash image holds an unfinished run")

        // Reopened within the staleness window the run is still considered in flight.
        let soon = try EvidenceStore(url: crashImage, dateSource: { Date() })
        XCTAssertEqual(try image.scalarInt("SELECT COUNT(*) FROM retention_runs WHERE result = 'started'"), 1)
        await soon.close()

        let later = try EvidenceStore(url: crashImage, dateSource: { Date().addingTimeInterval(7 * 3_600) })
        let status = try await later.lifecycleStatus(policy, at: Date().addingTimeInterval(7 * 3_600))
        XCTAssertEqual(status.lastCompaction?.result, .failed)
        XCTAssertTrue(status.lastCompaction?.limitations.contains { $0.contains("The process stopped before this retention run completed") } ?? false, "\(String(describing: status.lastCompaction?.limitations))")
        XCTAssertEqual(status.lastCompaction?.storageBytesAfter, status.lastCompaction?.storageBytesBefore, "No completion result is inferred")
        XCTAssertEqual(try image.scalarInt("SELECT COUNT(*) FROM events"), 500, "Tier compaction of fresh events changed nothing; the history is intact")
        try await later.insert([Self.event(9_999)])
        let rerun = try await later.applyRetention(policy, trigger: .startup)
        XCTAssertTrue(rerun.limitations.allSatisfy { !$0.contains("stopped") })
        let laterIntegrity = try await later.integrityCheck()
        XCTAssertEqual(laterIntegrity, "ok")
        await later.close()
    }

    // MARK: - Disk full

    func testDiskFullDuringStagingRollsBackAndTheGenerationResumesOnceSpaceReturns() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = 3_000
        try fixture.makeFiles(files)
        let reader = try SQLiteConnection(url: fixture.databaseURL)
        let fresh = try EvidenceStore(url: fixture.databaseURL, maximumStorageBytes: 64 * Self.mebibyte)
        await fresh.close()
        let schemaPages = try reader.scalarInt("PRAGMA page_count")

        let constrained = try EvidenceStore(
            url: fixture.databaseURL, availableCapacitySource: { _ in 100 * 1_024 * Self.mebibyte },
            maximumStorageBytes: 64 * Self.mebibyte, maximumPageCount: schemaPages + 400
        )
        var lastCommitted: Int64 = 0
        do {
            let scanner = DirectoryMetadataScanner()
            let scope = fixture.policy.scopeVersion(at: Self.start)
            var generation = try await constrained.beginOrResumeScanGeneration(scope: scope, at: Self.start)
            for attempt in 0..<40 {
                let slice = scanner.scanSlice(policy: fixture.policy, generation: generation, at: Self.start.addingTimeInterval(Double(attempt + 1)))
                generation = try await constrained.recordScanSlice(snapshot: Self.snapshot(attempt), slice: slice, scope: scope, trigger: .scheduled).generation
                lastCommitted = try reader.scalarInt("SELECT COUNT(*) FROM scan_generation_entries")
            }
            XCTFail("1.6 MB of pages cannot hold 3,000 staged rows")
        } catch let EvidenceStoreError.sqlite(code, message) {
            XCTAssertEqual(code, SQLITE_FULL, message)
        }
        XCTAssertEqual(try reader.scalarInt("SELECT COUNT(*) FROM scan_generation_entries"), lastCommitted, "The failed slice was rolled back whole")
        XCTAssertGreaterThan(lastCommitted, 0)
        let generation = try await constrained.activeScanGeneration()
        XCTAssertEqual(generation?.status, .active)
        let constrainedIntegrity = try await constrained.integrityCheck()
        XCTAssertEqual(constrainedIntegrity, "ok")
        await constrained.close()

        let recovered = try EvidenceStore(url: fixture.databaseURL, maximumStorageBytes: 64 * Self.mebibyte)
        let observation = try await drive(store: recovered, fixture: fixture, attempts: 40, sliceIndex: 100)
        XCTAssertNotNil(observation, "The generation resumed from its committed progress")
        let recoveredFiles = try await recovered.currentFiles()
        XCTAssertEqual(recoveredFiles.count, files)
        await recovered.close()
    }

    func testInsufficientVolumeSpaceIsRefusedBeforeAnyWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeFiles(600)
        let store = try EvidenceStore(url: fixture.databaseURL, availableCapacitySource: { _ in 1 * Self.mebibyte }, maximumStorageBytes: 64 * Self.mebibyte)
        let reader = try SQLiteConnection(url: fixture.databaseURL)
        do {
            try await drive(store: store, fixture: fixture, attempts: 1)
            XCTFail("A volume with 1 MiB free cannot hold the publication log")
        } catch let EvidenceStoreError.storageHeadroomUnavailable(reason, demand, accounting) {
            XCTAssertEqual(reason, "disk-space")
            XCTAssertGreaterThan(demand, 0)
            XCTAssertEqual(accounting.availableDiskBytes, 1 * Self.mebibyte)
        }
        XCTAssertEqual(try reader.scalarInt("SELECT COUNT(*) FROM scan_generation_entries"), 0)
        let accounting = try await store.storageAccounting()
        XCTAssertEqual(accounting.admission, .diskSpaceLimited, "A 64 MiB volume reserve applies before anything is staged")
        XCTAssertTrue(accounting.limitations.contains { $0.contains("Nothing was written") }, "\(accounting.limitations)")
        await store.close()
    }
}
