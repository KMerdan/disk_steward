import Foundation
import XCTest
@testable import DiskStewardCore
@testable import DiskStewardEndpoint

final class PerformanceTests: XCTestCase {
    func testSeventyTwoHourEquivalentEvidenceSoakStaysBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let database = directory.appending(path: "evidence.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LockedDate(start)
        let store = try EvidenceStore(
            url: database,
            dateSource: { clock.value },
            maximumStorageBytes: 32 * 1_024 * 1_024
        )
        let retention = try EvidenceStoreRetentionPolicy(
            rawEventDays: 1,
            anomalyDetailDays: 7,
            hourlySummaryDays: 14,
            dailySummaryDays: 90,
            maxDatabaseBytes: 16 * 1_024 * 1_024,
            writeCoalesceSeconds: 300,
            preserveUnreviewedAnomalies: true
        )

        // 864 five-minute scheduling cycles model 72 hours. The first 288
        // cycles are the denser 24-hour workload; retention runs every six
        // virtual hours, matching the production scheduler boundary.
        for cycle in 0 ..< 864 {
            let now = start.addingTimeInterval(Double(cycle * 300))
            clock.value = now
            let eventCount = cycle < 288 ? 8 : 3
            try await store.insert((0 ..< eventCount).map { event in
                EvidenceStoreEvent(
                    eventID: "soak-\(cycle)-\(event)",
                    observedAt: now,
                    operation: .writeSummary,
                    path: "/fixture/cache/worker-\(event).bin",
                    logicalDelta: 4_096,
                    allocatedDelta: 4_096,
                    consumerCategory: "developer-cache",
                    confidence: .inferred
                )
            })
            try await store.recordSnapshot(
                StorageSnapshot(
                    snapshotID: "soak-snapshot-\(cycle)",
                    observedAt: "virtual-cycle-\(cycle)",
                    volumes: [.init(
                        mountPath: "/",
                        totalBytes: 1_000_000_000,
                        availableBytes: 500_000_000 - Int64(cycle * 4_096),
                        isInternal: true,
                        isReadOnly: false
                    )]
                ),
                observedAt: now
            )
            if cycle % 72 == 71 {
                _ = try await store.applyRetention(retention)
            }
        }

        let finalReport = try await store.applyRetention(retention)
        let diagnostics = try await store.diagnostics()
        XCTAssertEqual(diagnostics.integrity, "ok")
        XCTAssertLessThanOrEqual(finalReport.storageBytes, retention.maxDatabaseBytes)
        XCTAssertLessThan(diagnostics.eventCount, 4_032)
        XCTAssertGreaterThan(diagnostics.hourlySummaryCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.snapshotCount, 864)
        await store.close()
    }

    func testSustainedEventStormRemainsBoundedAndReportsEveryDrop() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let process = ProcessIdentity(pid: 88, startTime: start.addingTimeInterval(-1), executablePath: "/bin/tool")
        var buffer = BoundedEndpointEventBuffer(maximumEvents: 512, maximumEstimatedBytes: 256 * 1_024, coalescingWindow: 0.01)
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for index in 0 ..< 100_000 {
                let path = "/Users/example/work/item-\(index).bin"
                let raw = RawPrivilegedNotification(
                    eventID: "storm-\(index)", streamID: "load", sequence: UInt64(index + 1),
                    observedAt: start.addingTimeInterval(Double(index) / 1_000), operation: .create,
                    path: path, process: process,
                    fileIdentity: .init(volumeID: "data", fileID: UInt64(index + 1)),
                    size: .init(logicalBefore: 0, logicalAfter: 1, allocatedBefore: 0, allocatedAfter: 4_096, method: "fstat")
                )
                let event = try XCTUnwrap(EndpointEventNormalizer().normalize(raw, scope: .init(watchedRoots: ["/Users/example/work"], excludedRoots: []), gapBefore: false))
                _ = buffer.append(event)
            }
        }
        XCTAssertLessThanOrEqual(buffer.count, 512)
        XCTAssertEqual(buffer.count + buffer.droppedEvents, 100_000)
        XCTAssertTrue(buffer.hasGap)
        XCTAssertLessThan(elapsed, .seconds(10))
    }

    func testResourceHistoryAndDatabaseBudgetStayBounded() {
        var history = BoundedResourceHistory(capacity: 60)
        for index in 0 ..< 10_000 {
            history.append(.init(cpuPercent: 2, residentBytes: 50_000_000, databaseBytes: Int64(index), pendingEvents: 4, receivedEvents: index, droppedEvents: 0, underLoad: true))
        }
        XCTAssertEqual(history.samples.count, 60)
        let assessment = ResourceBudgetEvaluator().assess(history.samples.last!, against: ResourceBudget())
        XCTAssertTrue(assessment.withinBudget)
        XCTAssertFalse(assessment.backpressureRequired)
    }

    func testLiveResourceMeasurementCountsDatabaseWALAndSharedMemory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let database = directory.appending(path: "evidence.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: database)
        try Data(repeating: 2, count: 20).write(to: URL(fileURLWithPath: database.path + "-wal"))
        try Data(repeating: 3, count: 30).write(to: URL(fileURLWithPath: database.path + "-shm"))

        let source = LiveResourceMeasurementSource()
        let first = source.measure(databaseURL: database, underLoad: false)
        usleep(1_000)
        let second = source.measure(databaseURL: database, underLoad: true)

        XCTAssertEqual(first.databaseBytes, 60)
        XCTAssertGreaterThan(first.residentBytes, 0)
        XCTAssertGreaterThanOrEqual(second.cpuPercent, 0)
        XCTAssertTrue(second.underLoad)
    }

    func testCircuitBreakerStopsMemoryStorageAndBackpressureButNotCPUAlone() {
        let evaluator = ResourceBudgetEvaluator()
        let budget = ResourceBudget(
            maximumIdleCPUPercent: 1,
            maximumLoadCPUPercent: 10,
            maximumResidentBytes: 32 * 1_024 * 1_024,
            maximumDatabaseBytes: 32 * 1_024 * 1_024,
            maximumPendingEvents: 10
        )

        let cpuOnly = evaluator.assess(
            .init(cpuPercent: 99, residentBytes: 1, databaseBytes: 1, pendingEvents: 0, receivedEvents: 1, droppedEvents: 0, underLoad: true),
            against: budget
        )
        XCTAssertFalse(ResourceCircuitBreaker.mustStop(cpuOnly))

        let memory = evaluator.assess(
            .init(cpuPercent: 0, residentBytes: 33 * 1_024 * 1_024, databaseBytes: 1, pendingEvents: 0, receivedEvents: 1, droppedEvents: 0, underLoad: true),
            against: budget
        )
        XCTAssertTrue(ResourceCircuitBreaker.mustStop(memory))

        let queue = evaluator.assess(
            .init(cpuPercent: 0, residentBytes: 1, databaseBytes: 1, pendingEvents: 10, receivedEvents: 1, droppedEvents: 0, underLoad: true),
            against: budget
        )
        XCTAssertTrue(ResourceCircuitBreaker.mustStop(queue))
    }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(_ value: Date) {
        storage = value
    }

    var value: Date {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
