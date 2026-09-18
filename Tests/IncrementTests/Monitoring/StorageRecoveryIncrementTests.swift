import DiskStewardCore
import XCTest
@testable import DiskStewardApp
@testable import DiskStewardCore

/// TASK-532: a cap the watched tree cannot fit yields explicit non-progress
/// on every sample, never a repeating error; one bounded pressure retention run
/// is tried when history is evictable; raising the cap completes the scan; and
/// an over-cap store with only authoritative current state keeps sampling
/// volumes with the reason stated while evicting nothing.
@MainActor
final class StorageRecoveryIncrementTests: XCTestCase {
    private nonisolated static func fileBytes(_ url: URL) -> Int64 {
        [url.path, url.path + "-wal", url.path + "-shm"].reduce(0) { total, path in
            total + (((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    func testCapTooSmallForTheTreeYieldsExplicitNonProgressUntilTheCapIsRaised() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "storage-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let watched = directory.appending(path: "watch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileCount = 6_000
        for index in 0..<fileCount {
            let bucket = watched.appending(path: "bucket-\(index % 12)", directoryHint: .isDirectory)
            if index < 12 { try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true) }
            try Data([7]).write(to: bucket.appending(path: String(format: "s-%05d", index)))
        }
        let databaseURL = directory.appending(path: "support/evidence.sqlite")
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        settings.maxDatabaseMiB = 10
        let probe = try PersistentMonitoringProbe(
            databaseURL: databaseURL,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024),
            // The real database size feeds the circuit breaker: an over-cap
            // store must not turn every sample into a resource-limit error.
            resourceMeasurementSource: { url, load in
                .init(cpuPercent: 0, residentBytes: 0, databaseBytes: Self.fileBytes(url), pendingEvents: 0, receivedEvents: 0, droppedEvents: 0, underLoad: load)
            },
            volumeSampleSource: { previous in
                let snapshot = StorageSnapshot(snapshotID: UUID().uuidString, observedAt: EvidenceTimestamp.format(Date()),
                    volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)])
                _ = previous
                return (snapshot, .init(observedAt: snapshot.observedAt, usedByteDeltas: ["/": 0], limitations: []))
            },
            continuationBudget: 10
        )

        // 1. The first sample stages until the publication reserve no longer fits.
        let first = try await probe.sample(settings: settings)
        XCTAssertTrue(first.scanStalled, "Refused storage ends continuation for this sample")
        XCTAssertTrue(first.needsScanContinuation, "The generation keeps its committed progress")
        XCTAssertGreaterThan(first.continuationSlices, 0)
        XCTAssertTrue(first.growthReport.limitations.contains { $0.contains("Evidence storage refused new file detail (publication-reserve)") }, "\(first.growthReport.limitations)")
        let stagedAfterFirst = first.evidenceLifecycle?.storage?.stagedRowCount ?? 0
        XCTAssertGreaterThan(stagedAfterFirst, 0)

        // 2. The next sample tries one bounded pressure retention run, then reports.
        let second = try await probe.sample(settings: settings)
        XCTAssertTrue(second.scanStalled)
        XCTAssertTrue(second.needsScanContinuation)
        XCTAssertTrue(second.detailedEvents.isEmpty)
        XCTAssertTrue(second.growthReport.limitations.contains { $0.contains("One bounded pressure retention run could not make enough room.") }, "\(second.growthReport.limitations)")
        XCTAssertEqual(second.evidenceLifecycle?.storage?.admission, .capacityLimited)
        XCTAssertEqual(second.evidenceLifecycle?.storage?.stagedRowCount, stagedAfterFirst, "Staged work is neither lost nor evicted")

        // 3. With nothing left to evict, every further sample is explicit non-progress without retention.
        let third = try await probe.sample(settings: settings)
        XCTAssertTrue(third.scanStalled)
        XCTAssertEqual(third.evidenceLifecycle?.storage?.admission, .capacityLimited)
        XCTAssertTrue(third.growthReport.limitations.contains { $0.contains("raise the cap or narrow watched roots") }, "\(third.growthReport.limitations)")
        let store = try EvidenceStore(url: databaseURL)
        let runs = try await store.retentionRuns()
        XCTAssertEqual(runs.filter { $0.trigger == .pressure }.count, 1, "Retention is not repeated once history is gone")
        XCTAssertTrue(runs.allSatisfy { $0.result == .completed }, "\(runs.map(\.result))")

        // 4. Raising the cap admits the staged work and the scan completes in one sample.
        settings.maxDatabaseMiB = 64
        let fourth = try await probe.sample(settings: settings)
        XCTAssertFalse(fourth.needsScanContinuation, "\(fourth.growthReport.limitations)")
        XCTAssertFalse(fourth.scanStalled)
        XCTAssertEqual(fourth.evidenceLifecycle?.storage?.admission, .available)
        let publishedFiles = try await store.currentFiles()
        XCTAssertEqual(publishedFiles.count, fileCount)

        // 5. Lowered again below the published size, the store is capacity-limited:
        //    volume sampling continues, nothing is evicted, no error is thrown.
        settings.maxDatabaseMiB = 10
        let fifth = try await probe.sample(settings: settings)
        XCTAssertTrue(fifth.scanStalled)
        XCTAssertFalse(fifth.needsScanContinuation, "No generation was opened")
        XCTAssertEqual(fifth.evidenceLifecycle?.storage?.admission, .capacityLimited)
        XCTAssertGreaterThan(fifth.evidenceLifecycle?.storage?.liveBytes ?? 0, 10 * 1_024 * 1_024)
        XCTAssertEqual(fifth.snapshot.volumes.count, 1)
        let survivingFiles = try await store.currentFiles()
        XCTAssertEqual(survivingFiles.count, fileCount, "Authoritative current state survives the cap")
        let sixth = try await probe.sample(settings: settings)
        XCTAssertTrue(sixth.scanStalled)
        XCTAssertEqual(sixth.evidenceLifecycle?.storage?.admission, .capacityLimited)
        await store.close()
    }
}
