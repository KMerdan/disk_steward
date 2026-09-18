@testable import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

final class InlineExportSafetyTests: XCTestCase {
    func testInlineZeroOneManyRowsAcceptFractionalBoundsAndDestroyTemporaryExports() async throws {
        for count in [0, 1, 150] {
            let root = FileManager.default.temporaryDirectory.appending(path: "ds-inline-safety-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let database = root.appending(path: "evidence.sqlite")
            let store = try EvidenceStore(url: database)
            if count > 0 { try await store.insert((0..<count).map { Self.event($0) }) }
            let backend = try AppEvidenceQueryBackend(databaseURL: database)
            let result = try await backend.handleIPC(method: "tools/call", payload: Self.request, peer: Self.peer)
            guard case let .array(events)? = result.objectValue?["events"] else { return XCTFail("Missing event array") }
            XCTAssertEqual(events.count, count)
            let records = try await store.exportRecords()
            XCTAssertEqual(records.map(\.status), [.destroyed])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "temporary-exports").path), [])
            await store.close()
        }
    }

    func testOversizedInlineExportReturnsTypedFailureAndCleansScratch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ds-inline-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        // Long but finite metadata, with output amplified by the exported schema.
        try await store.insert((0..<500).map { Self.event($0, name: String(repeating: "x", count: 5_000)) })
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        do {
            _ = try await backend.handleIPC(method: "tools/call", payload: Self.request, peer: Self.peer)
            XCTFail("Oversized output must be rejected")
        } catch { XCTAssertEqual(error as? DiskStewardIPCError, .responseTooLarge) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "temporary-exports").path), [])
        let records = try await store.exportRecords()
        XCTAssertEqual(records.map(\.status), [.failed])
        await store.close()
    }

    func testCorruptInlineEvidenceReturnsTypedErrorAndNoPartialExport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ds-inline-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        try await store.recordSnapshot(.init(snapshotID: "broken", observedAt: "2033-05-18T03:33:20.125Z", volumes: [], limitations: []), observedAt: Date(timeIntervalSince1970: 2_000_000_000.125))
        let connection = try SQLiteConnection(url: database)
        try connection.execute("UPDATE snapshots SET payload = X'7B'")
        connection.close()
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        do {
            _ = try await backend.handleIPC(method: "tools/call", payload: Self.request, peer: Self.peer)
            XCTFail("Malformed stored JSON must not produce a partial result")
        } catch {
            guard case DiskStewardIPCError.remote(let code, _, let retryable) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(code, "invalid_evidence")
            XCTAssertFalse(retryable)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "temporary-exports").path), [])
        let records = try await store.exportRecords()
        XCTAssertEqual(records.map(\.status), [.failed])
        await store.close()
    }

    private static let peer = IPCPeerIdentity(uid: getuid(), gid: getgid(), pid: getpid())
    private static let request = JSONValue.object([
        "name": .string("export_evidence"), "arguments": .object([
            "from": .string("2033-05-18T03:33:20.100Z"),
            "through": .string("2033-05-18T03:33:20.200Z"),
            "path_detail": .string("basename"), "max_events": .integer(500),
        ]),
    ])
    private static func event(_ index: Int, name: String = "file") -> EvidenceStoreEvent {
        .init(eventID: "event-\(index)", observedAt: Date(timeIntervalSince1970: 2_000_000_000.125), operation: .create,
              path: "/fixture/\(name)-\(index)", logicalDelta: 1, allocatedDelta: 1, consumerCategory: "fixture", confidence: .inferred)
    }
}
