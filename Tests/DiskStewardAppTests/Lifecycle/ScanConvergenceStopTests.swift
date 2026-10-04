@testable import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

/// TASK-614: a scan generation that cannot converge is abandoned with one
/// explicit stop before any further slice, survives relaunch, and is retried
/// only after the cooldown or when the scope or store limit changes.
@MainActor
final class ScanConvergenceStopTests: XCTestCase {
    private final class CommitCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct Fixture {
        let directory: URL
        let watched: URL
        let database: URL
        var settings: MonitoringSettings

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "convergence-\(UUID().uuidString)", directoryHint: .isDirectory)
            watched = directory.appending(path: "watch", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
            try Data([1]).write(to: watched.appending(path: "a.bin"))
            database = directory.appending(path: "support/evidence.sqlite")
            settings = MonitoringSettings.defaults
            settings.watchedRoots = [watched.path]
            settings.excludedRoots = []
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func probe(store: EvidenceStore? = nil, commits: CommitCounter) throws -> PersistentMonitoringProbe {
            try PersistentMonitoringProbe(
                databaseURL: database,
                evidenceStore: store,
                resourceMeasurementSource: { _, load in
                    .init(cpuPercent: 0, residentBytes: 0, databaseBytes: 0, pendingEvents: 0, receivedEvents: 0, droppedEvents: 0, underLoad: load)
                },
                volumeSampleSource: { _ in
                    let snapshot = StorageSnapshot(snapshotID: UUID().uuidString, observedAt: EvidenceTimestamp.format(Date()),
                        volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)])
                    return (snapshot, .init(observedAt: snapshot.observedAt, usedByteDeltas: ["/": 0], limitations: []))
                },
                afterScanCommit: { commits.increment() },
                continuationBudget: 0
            )
        }

        /// Reproduces the live store's stuck generation: 488 M entries
        /// processed against far fewer staged files.
        func seedStuckGeneration() async throws {
            let store = try EvidenceStore(url: database)
            let now = Date()
            let scope = settings.monitoringPolicy(at: now).scopeVersion(at: now)
            let initial = try await store.beginOrResumeScanGeneration(scope: scope, at: now)
            let stuck = MetadataScanGeneration(generationID: initial.generationID, scopeVersionID: initial.scopeVersionID,
                rootPaths: initial.rootPaths, excludedPaths: initial.excludedPaths, status: .active, roots: initial.roots,
                processedEntryCount: 488_301_862, stagedFileCount: 123_280, startedAt: now, updatedAt: now,
                reconciliationToken: initial.reconciliationToken)
            _ = try await store.recordScanSlice(snapshot: .init(snapshotID: "stuck", observedAt: EvidenceTimestamp.format(now), volumes: []),
                slice: .init(generation: stuck, entries: []), scope: scope, trigger: .scheduled)
            let summary = try await store.activeScanGenerationSummary()
            XCTAssertEqual(summary?.processedEntryCount, 488_301_862, "fixture reproduces the live counters")
            await store.close()
        }
    }

    func testStuckGenerationStopsBeforeAnySliceAndStaysStoppedAcrossRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await fixture.seedStuckGeneration()

        let commits = CommitCounter()
        let first = try await fixture.probe(commits: commits).sample(settings: fixture.settings)
        let stop = try XCTUnwrap(first.scanStop)
        XCTAssertEqual(stop.reason, .processedFarBeyondStaged)
        XCTAssertEqual(stop.processedEntryCount, 488_301_862)
        // The store derives staged files from staged rows, which this fixture
        // does not materialize; the captured-store run records 123,280.
        XCTAssertLessThan(stop.stagedFileCount, 100_000)
        XCTAssertEqual(commits.count, 0, "The stop fires before any slice is attempted")
        XCTAssertFalse(first.needsScanContinuation)
        XCTAssertTrue(first.scanStalled)
        XCTAssertEqual(first.snapshot.volumes.count, 1, "Capacity sampling continues")
        XCTAssertTrue(first.growthReport.limitations.contains(stop.message))
        XCTAssertTrue(stop.message.contains("remove large folders from the watched roots or raise the store limit"))

        let reader = try EvidenceStore(url: fixture.database)
        let active = try await reader.activeScanGeneration()
        XCTAssertNil(active, "The stuck generation is abandoned")
        let runs = try await reader.retentionRuns()
        XCTAssertTrue(runs.isEmpty, "No retention ran on the stopped sample")
        await reader.close()

        // Relaunch: a new probe honours the persisted stop and scans nothing.
        let relaunched = try await fixture.probe(commits: commits).sample(settings: fixture.settings)
        XCTAssertEqual(relaunched.scanStop, stop)
        XCTAssertEqual(commits.count, 0)
        let afterRelaunch = try EvidenceStore(url: fixture.database)
        let restarted = try await afterRelaunch.activeScanGeneration()
        XCTAssertNil(restarted, "The stopped scope is not restarted")
        await afterRelaunch.close()
    }

    func testStopLiftsAfterCooldownOrScopeChange() async throws {
        for trigger in ["cooldown", "scope"] {
            var fixture = try Fixture()
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.database.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await fixture.seedStuckGeneration()
            let commits = CommitCounter()
            let probe = try fixture.probe(commits: commits)
            let stopped = try await probe.sample(settings: fixture.settings)
            XCTAssertNotNil(stopped.scanStop)

            if trigger == "cooldown" {
                let url = ScanConvergenceRecord.url(beside: fixture.database)
                var record = ScanConvergenceRecord.load(from: url)
                let stop = try XCTUnwrap(record.stop)
                record.stop = ScanConvergenceStop(
                    generationID: stop.generationID, scopeVersionID: stop.scopeVersionID, capBytes: stop.capBytes,
                    stoppedAt: Date().addingTimeInterval(-25 * 60 * 60), reason: stop.reason,
                    processedEntryCount: stop.processedEntryCount, stagedFileCount: stop.stagedFileCount)
                try record.save(to: url)
            } else {
                let other = fixture.directory.appending(path: "other", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
                try Data([2]).write(to: other.appending(path: "b.bin"))
                fixture.settings.watchedRoots = [other.path]
            }
            let resumed = try await probe.sample(settings: fixture.settings)
            XCTAssertNil(resumed.scanStop, "\(trigger) lifts the stop")
            XCTAssertGreaterThan(commits.count, 0, "\(trigger): scanning resumes")
            XCTAssertNil(ScanConvergenceRecord.load(from: ScanConvergenceRecord.url(beside: fixture.database)).stop)
        }
    }

    func testVerdictThresholds() {
        let policy = ScanConvergencePolicy()
        XCTAssertNil(policy.verdict(processed: 2_000_000, staged: 0, consecutiveRefusals: 0, activeWork: 0), "A young generation is judged against the 100k floor")
        XCTAssertEqual(policy.verdict(processed: 2_000_001, staged: 0, consecutiveRefusals: 0, activeWork: 0), .processedFarBeyondStaged)
        XCTAssertNil(policy.verdict(processed: 4_000_000, staged: 200_000, consecutiveRefusals: 0, activeWork: 0))
        XCTAssertEqual(policy.verdict(processed: 488_301_862, staged: 123_280, consecutiveRefusals: 0, activeWork: 0), .processedFarBeyondStaged)
        XCTAssertNil(policy.verdict(processed: 10, staged: 10, consecutiveRefusals: 2, activeWork: 0))
        XCTAssertEqual(policy.verdict(processed: 10, staged: 10, consecutiveRefusals: 3, activeWork: 0), .storageRefused)
        XCTAssertNil(policy.verdict(processed: 10, staged: 10, consecutiveRefusals: 0, activeWork: 6 * 60 * 60))
        XCTAssertEqual(policy.verdict(processed: 10, staged: 10, consecutiveRefusals: 0, activeWork: 6 * 60 * 60 + 1), .activeWorkExceeded)

        let stop = ScanConvergenceStop(generationID: "g", scopeVersionID: "s", capBytes: 10, stoppedAt: Date(timeIntervalSince1970: 0),
                                       reason: .storageRefused, processedEntryCount: 1, stagedFileCount: 1)
        XCTAssertTrue(stop.applies(scopeVersionID: "s", capBytes: 10, at: Date(timeIntervalSince1970: 3_600), policy: policy))
        XCTAssertFalse(stop.applies(scopeVersionID: "s", capBytes: 11, at: Date(timeIntervalSince1970: 3_600), policy: policy), "A new limit lifts the stop")
        XCTAssertFalse(stop.applies(scopeVersionID: "t", capBytes: 10, at: Date(timeIntervalSince1970: 3_600), policy: policy), "A new scope lifts the stop")
        XCTAssertFalse(stop.applies(scopeVersionID: "s", capBytes: 10, at: Date(timeIntervalSince1970: 24 * 3_600), policy: policy), "The cooldown lifts the stop")

        var record = ScanConvergenceRecord()
        record.addActiveWork(10, generationID: "g")
        record.addActiveWork(5, generationID: "g")
        XCTAssertEqual(record.activeWork(for: "g"), 15)
        record.addActiveWork(1, generationID: "h")
        XCTAssertEqual(record.activeWork(for: "g"), 0, "Active work belongs to one generation")
        XCTAssertEqual(record.activeWork(for: "h"), 1)
    }
}
