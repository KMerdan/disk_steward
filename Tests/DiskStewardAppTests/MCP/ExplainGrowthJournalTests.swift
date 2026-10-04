import CoreServices
@testable import DiskStewardApp
import DiskStewardCore
import Foundation
import XCTest

/// TASK-652: `explain_growth` answers what changed from the capacity ring and
/// the change journal, whether or not the evidence store can add file detail.
final class ExplainGrowthJournalTests: XCTestCase {
    private var directory: URL!
    private let gib: Int64 = 1_073_741_824

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp/ds-growth-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func seed(now: Date) async throws -> (ring: URL, journal: URL) {
        let ringURL = directory.appending(path: "capacity.sqlite")
        let selected = try XCTUnwrap(selectedCapacityVolume(in: try VolumeSnapshotService().capture()))
        let ring = try CapacityRing(url: ringURL)
        try await ring.record(volumeUUID: "UUID-root", mountPath: selected.mountPath, totalBytes: 1_000 * gib, availableBytes: 300 * gib, at: now.addingTimeInterval(-3_600))
        try await ring.record(volumeUUID: "UUID-root", mountPath: selected.mountPath, totalBytes: 1_000 * gib, availableBytes: 295 * gib, at: now.addingTimeInterval(-600))
        await ring.close()
        let journalURL = directory.appending(path: "steward.sqlite")
        let journal = try ChangeJournal(url: journalURL)
        try await journal.recordGap(reason: "journal-started", path: "/r", at: now.addingTimeInterval(-3_000))
        let modified = UInt32(kFSEventStreamEventFlagItemModified)
        let events = ["/r/proj/web/.next/cache", "/r/proj/web/.next", "/r/proj/web/src", "/r/other/a/b"].enumerated().map { ($0.element, modified, UInt64(10 + $0.offset)) }
        try await journal.record(DirectoryChangeBatch.interpret(events), roots: ["/r"], at: now.addingTimeInterval(-1_800))
        await journal.close()
        return (ringURL, journalURL)
    }

    private func growth(_ backend: AppEvidenceQueryBackend, now: Date) throws -> [String: JSONValue] {
        let socket = directory.appending(path: "ipc/s.sock")
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: backend)
        try server.start()
        defer { server.stop() }
        let formatter = ISO8601DateFormatter()
        let value = try UnixSocketDiskStewardIPCClient(socketPath: socket.path).call(tool: "explain_growth", arguments: [
            "from": .string(formatter.string(from: now.addingTimeInterval(-7_200))),
            "through": .string(formatter.string(from: now)),
            "path_detail": .string("full"),
        ], isCancelled: { false })
        return try XCTUnwrap(value.objectValue)
    }

    private func array(_ value: JSONValue?) -> [JSONValue] {
        if case let .array(values)? = value { return values }
        return []
    }

    func testGrowthNamesChangedDirectoriesAndTheCapacityChangeWithoutTheEvidenceStore() async throws {
        let now = Date()
        let (ring, journal) = try await seed(now: now)
        let database = directory.appending(path: "evidence.sqlite")
        try Data(repeating: 0x5A, count: 8_192).write(to: database)  // the evidence store is corrupt
        let backend = try AppEvidenceQueryBackend(databaseURL: database, capacityRingURL: ring, changeJournalURL: journal)
        let object = try growth(backend, now: now)

        XCTAssertEqual(object["detail_status"], .string("unavailable"))
        XCTAssertEqual(object["schema"], .string("evidence-query-page-v1"), "the degraded answer keeps the page shape")
        XCTAssertEqual(object["returned_count"], .integer(0))
        let capacity = try XCTUnwrap(object["capacity_change"]?.objectValue)
        XCTAssertEqual(capacity["status"], .string("available"))
        XCTAssertEqual(capacity["used_delta_bytes"], .integer(5 * gib))

        let changed = try XCTUnwrap(object["changed_directories"]?.objectValue)
        let items = array(changed["items"]).compactMap(\.objectValue)
        XCTAssertEqual(items.first?["path"], .string("/r/proj/web"), "changes inside the project collapse to it, most changes first")
        XCTAssertEqual(items.first?["changes"], .integer(3))
        XCTAssertEqual(items.map { $0["path"] }, [.string("/r/proj/web"), .string("/r/other/a")])
        XCTAssertTrue(items.allSatisfy { $0["measured"] == .bool(false) }, "the journal names directories; it does not measure them")
        XCTAssertEqual(changed["total"], .integer(2))
        XCTAssertEqual(changed["truncated"], .bool(false))

        let gaps = array(object["journal_gaps"]).compactMap(\.objectValue)
        XCTAssertEqual(gaps.map { $0["reason"] }, [.string("journal-started")])
        let limitations = array(object["journal_limitations"]).compactMap(\.stringValue)
        XCTAssertTrue(limitations.contains { $0.contains("earlier changes are unknown, not absent") }, "\(limitations)")
    }

    func testReadsCreateNeitherTheJournalNorTheRing() async throws {
        let database = directory.appending(path: "evidence.sqlite")
        try Data(repeating: 0x5A, count: 8_192).write(to: database)
        let ring = directory.appending(path: "capacity.sqlite")
        let journal = directory.appending(path: "steward.sqlite")
        let backend = try AppEvidenceQueryBackend(databaseURL: database, capacityRingURL: ring, changeJournalURL: journal)
        let object = try growth(backend, now: Date())
        XCTAssertEqual(object["changed_directories"], .null)
        XCTAssertTrue(array(object["journal_limitations"]).contains { $0.stringValue?.contains("has not started") == true })
        XCTAssertEqual(object["capacity_change"]?.objectValue?["status"], .string("no-samples"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path), "a query does not create the journal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ring.path), "a query does not create the ring")
    }

    func testGrowthStillRefusesAnExpiredCursorAndABadRange() async throws {
        let watched = directory.appending(path: "watched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        for name in ["a.bin", "b.bin", "c.bin"] { try Data(repeating: 1, count: 4_096).write(to: watched.appending(path: name)) }
        let database = directory.appending(path: "evidence.sqlite")
        let now = Date()
        let policy = MonitoringPolicy(watchedRoots: [watched])
        let store = try EvidenceStore(url: database)
        _ = try await store.recordObservation(
            snapshot: .init(snapshotID: "growth-baseline", observedAt: EvidenceTimestamp.format(now), volumes: []),
            metadata: DirectoryMetadataScanner().scan(policy: policy, at: now),
            scope: policy.scopeVersion(at: now), trigger: .scheduled)
        for (index, name) in ["a.bin", "b.bin", "c.bin"].enumerated() {
            try await store.insert(.init(eventID: "growth-\(index)", observedAt: now.addingTimeInterval(Double(index) - 10), operation: .modify,
                                         path: watched.appending(path: name).path, logicalDelta: 4_096, allocatedDelta: 4_096,
                                         consumerCategory: "watched-root", confidence: .unknown))
        }
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = directory.appending(path: "ipc/s.sock")
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket.path)
        let window: [String: JSONValue] = [
            "from": .string(EvidenceTimestamp.format(now.addingTimeInterval(-60))),
            "through": .string(EvidenceTimestamp.format(now.addingTimeInterval(60))), "limit": .integer(1),
        ]
        let first = try client.call(tool: "explain_growth", arguments: window, isCancelled: { false })
        XCTAssertEqual(first.objectValue?["detail_status"], .string("available"))
        let cursor = try XCTUnwrap(first.objectValue?["next_cursor"]?.stringValue)
        try await store.insert(.init(eventID: "growth-revision", observedAt: now.addingTimeInterval(1), operation: .modify,
                                     path: watched.appending(path: "a.bin").path, logicalDelta: 1, allocatedDelta: 1,
                                     consumerCategory: "watched-root", confidence: .unknown))
        var continuation = window
        continuation["cursor"] = .string(cursor)
        do { _ = try client.call(tool: "explain_growth", arguments: continuation, isCancelled: { false }); XCTFail("an expired page is refused, not degraded") }
        catch DiskStewardIPCError.remote(let code, _, _) { XCTAssertEqual(code, "cursor_expired") }
        var reversed = window
        reversed["from"] = window["through"]
        reversed["through"] = window["from"]
        do { _ = try client.call(tool: "explain_growth", arguments: reversed, isCancelled: { false }); XCTFail("a bad range is refused") }
        catch DiskStewardIPCError.remote(let code, _, _) { XCTAssertEqual(code, "invalid_range") }
        await store.close()
    }

    func testGrowthKeepsFileDetailAndAddsTheJournalWhenTheStoreIsReadable() async throws {
        let now = Date()
        let (ring, journal) = try await seed(now: now)
        let database = directory.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        await store.close()
        let backend = try AppEvidenceQueryBackend(databaseURL: database, capacityRingURL: ring, changeJournalURL: journal)
        let object = try growth(backend, now: now)
        XCTAssertEqual(object["detail_status"], .string("available"))
        guard case .array? = object["items"] else { return XCTFail("file-level rows are still returned") }
        XCTAssertEqual(object["changed_directories"]?.objectValue?["total"], .integer(2))
        XCTAssertEqual(object["capacity_change"]?.objectValue?["used_delta_bytes"], .integer(5 * gib))
    }
}
