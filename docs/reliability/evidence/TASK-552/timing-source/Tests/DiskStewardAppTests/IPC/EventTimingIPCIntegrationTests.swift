import DiskStewardCore
@testable import DiskStewardApp
import Foundation
import XCTest

final class EventTimingIPCIntegrationTests: XCTestCase {
    func testMetadataOnlyTimingReachesRealIPCAndDecodedExportWithoutWriterClaims() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-time-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let watch = root.appending(path: "watched").path
        let scope = EvidenceScopeVersion(scopeVersionID: "time-scope", effectiveAt: start,
            rootPaths: [watch], excludedPaths: [], maximumEntries: 10, maximumDepth: 2)
        let store = try EvidenceStore(url: database)
        func observe(_ id: String, path: String, bytes: Int64, sample: Double, publication: Double) async throws {
            let file = FileMetadata(objectID: "timed", rootPath: watch, path: path,
                logicalBytes: bytes, allocatedBytes: bytes, modifiedAt: nil, observedAt: start.addingTimeInterval(sample))
            _ = try await store.recordObservation(
                snapshot: .init(snapshotID: id, observedAt: EvidenceTimestamp.format(start.addingTimeInterval(publication)),
                    volumes: [.init(mountPath: "/", totalBytes: 1000, availableBytes: 500, isInternal: true, isReadOnly: false)]),
                metadata: .init(observationID: id, scopeVersionID: scope.scopeVersionID,
                    observedAt: start.addingTimeInterval(publication), entries: [path: file],
                    rootCoverage: [.init(rootPath: watch, coverage: .complete)], limitations: []),
                scope: scope, trigger: .scheduled)
        }
        try await observe("first", path: watch + "/A", bytes: 3, sample: 100, publication: 200)
        try await observe("second", path: watch + "/B", bytes: 7, sample: 300, publication: 400)
        try await store.insert(.init(eventID: "manual", observedAt: start.addingTimeInterval(50), operation: .writeSummary,
            path: watch + "/B", logicalDelta: 1, allocatedDelta: 1, consumerCategory: "test", confidence: .unknown))
        await store.close()

        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "private/service.sock")
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket.path)
        for detail in ["basename", "hashed"] {
            let response = try client.call(tool: "get_provenance", arguments: [
                "path_query": .string("B"), "path_detail": .string(detail), "limit": .integer(10)
            ], isCancelled: { false })
            guard case let .array(items)? = response.objectValue?["items"] else { return XCTFail("Missing evidence page") }
            let changes = items.filter { $0.objectValue?["kind"] == .string("change") }
            XCTAssertEqual(changes.count, 3)
            for change in changes {
                XCTAssertEqual(change.objectValue?["provenance_claims"], .array([]), "Metadata is not writer attribution")
                let timing = try XCTUnwrap(change.objectValue?["timing"]?.objectValue)
                XCTAssertEqual(timing["schema"], .string("event-timing-v1"))
                XCTAssertEqual(timing["basis"], .string("measured-observation"))
                let operation = change.objectValue?["operation"]?.stringValue
                XCTAssertEqual(timing["occurred_start"], operation == "baseline" ? .null : .string(EvidenceTimestamp.format(start.addingTimeInterval(100))))
                let upper = operation == "baseline" ? 100.0 : (operation == "rename" ? 400.0 : 300.0)
                XCTAssertEqual(timing["occurred_end"], .string(EvidenceTimestamp.format(start.addingTimeInterval(upper))))
                XCTAssertEqual(timing["detected_at"], .string(EvidenceTimestamp.format(start.addingTimeInterval(operation == "baseline" ? 200 : 400))))
            }
            let export = try client.call(tool: "export_evidence", arguments: [
                "from": .string(EvidenceTimestamp.format(start)),
                "through": .string(EvidenceTimestamp.format(start.addingTimeInterval(500))),
                "path_detail": .string(detail), "max_events": .integer(10)
            ], isCancelled: { false })
            guard case let .array(events)? = export.objectValue?["events"] else { return XCTFail("Missing decoded export") }
            XCTAssertEqual(events.count, 4)
            for change in changes {
                let event = try XCTUnwrap(events.first { $0.objectValue?["event_id"] == change.objectValue?["event_id"] })
                XCTAssertEqual(event.objectValue?["schema"], .string("evidence-event-v2"))
                XCTAssertEqual(event.objectValue?["timing"], change.objectValue?["timing"])
            }
            let unknown = try XCTUnwrap(events.first { $0.objectValue?["event_id"] == .string("manual") }?.objectValue?["timing"]?.objectValue)
            XCTAssertEqual(unknown["basis"], .string("unverified"))
            for key in ["occurred_start", "occurred_end", "detected_at"] { XCTAssertEqual(unknown[key], .null) }
            for value in [response, export] {
                let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                XCTAssertFalse(text.contains(watch))
            }
        }
    }
}
