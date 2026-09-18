@testable import DiskStewardCore
@testable import DiskStewardApp
import Foundation
import XCTest

/// Representative-cardinality composition: tens of thousands of retained
/// events plus scanned current state, read through real IPC with the public
/// row/byte budgets, typed budget refusals, and the occurrence-time contract.
final class EvidenceCardinalityIPCIntegrationTests: XCTestCase {
    func testBoundedQueriesHonorBudgetsAndOccurrenceContractAtRepresentativeCardinality() async throws {
        let started = Date()
        let root = URL(fileURLWithPath: "/tmp/ds-card-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let watched = root.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileCount = 200
        for index in 0..<fileCount { try Data(repeating: 1, count: 256).write(to: watched.appending(path: "f-\(index).bin")) }
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        // A 300-row overlap admission makes the typed refusal provable here;
        // the product default (100,000 rows, 8 MiB) uses the same path.
        let backend = try AppEvidenceQueryBackend(databaseURL: database, taskImpactMaximumRows: 300)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)

        // A session registered before both observations covers the measured
        // modification intervals, so attribution is honest, not fabricated.
        let registered = try client.send(method: "sessions/register", payload: .object([
            "client": .string("codex"), "session_id": .string("cardinality-task"),
            "workspace_roots": .array([.string(watched.path)]), "lease_seconds": .integer(3_600),
        ]), isCancelled: { false })
        let registrationID = try XCTUnwrap(registered.objectValue?["registration_id"]?.stringValue)
        let storedSessions = try await store.agentSessions()
        let registration = try XCTUnwrap(storedSessions.first { $0.registrationID.uuidString.lowercased() == registrationID })

        let policy = MonitoringPolicy(watchedRoots: [watched])
        let first = Date()
        func observe(_ id: String, at date: Date) async throws -> ObservationCommitResult {
            try await store.recordObservation(
                snapshot: .init(snapshotID: id, observedAt: EvidenceTimestamp.format(date), volumes: []),
                metadata: DirectoryMetadataScanner().scan(policy: policy, at: date),
                scope: policy.scopeVersion(at: date), trigger: .scheduled)
        }
        _ = try await observe("card-first", at: first)
        // Grow past one allocation block so allocated deltas are nonzero.
        for index in 0..<fileCount { try Data(repeating: 2, count: 8_192).write(to: watched.appending(path: "f-\(index).bin")) }
        let second = first.addingTimeInterval(1)
        let committed = try await observe("card-second", at: second)
        let modifications = committed.events.filter { $0.timing?.occurredStart != nil }
        XCTAssertEqual(modifications.count, fileCount, "Every modification carries a measured prior sample")
        let engine = ProvenanceEngine()
        var linked = 0
        for event in modifications {
            let claim = engine.attribute(.init(event: event, registrations: [registration]))
            XCTAssertNil(claim.actor)
            if claim.session?.registrationID == registration.registrationID { linked += 1 }
            try await store.persistProvenanceClaim(claim)
        }
        XCTAssertEqual(linked, fileCount)

        // Bulk raw history: 30,000 events over 400 paths inside the watched root,
        // spread across two hours before the observations.
        let rawCount = 30_000
        let bulkStart = first.addingTimeInterval(-7_200)
        var bulk: [EvidenceStoreEvent] = []
        bulk.reserveCapacity(rawCount)
        for index in 0..<rawCount {
            bulk.append(.init(
                eventID: "bulk-\(index)", observedAt: bulkStart.addingTimeInterval(Double(index) * 0.2),
                operation: .modify, path: watched.appending(path: "bulk-\(index % 400).bin").path,
                logicalDelta: 64, allocatedDelta: 64, consumerCategory: "watched-root", confidence: .unknown))
        }
        try await store.insert(bulk)
        let retainedEvents = try await store.eventCount()
        XCTAssertEqual(retainedEvents, rawCount + committed.events.count + fileCount)
        let ceiling = 1_024 * 1_024
        let encoder = JSONEncoder()
        func bytes(_ value: JSONValue) throws -> Int { try encoder.encode(value).count }

        // Provenance: the row budget is clamped before the read and the page is bounded.
        let provenance = try client.call(tool: "get_provenance", arguments: ["path_query": .string("bulk-7.bin"), "limit": .integer(500), "path_detail": .string("hashed")], isCancelled: { false })
        let provenanceBudget = try XCTUnwrap(provenance.objectValue?["budget"]?.objectValue)
        let provenanceApplied = try XCTUnwrap(provenanceBudget["row_limit_applied"]?.integerValue)
        XCTAssertLessThan(provenanceApplied, 500)
        XCTAssertLessThanOrEqual(try XCTUnwrap(provenance.objectValue?["returned_count"]?.integerValue), provenanceApplied)
        XCTAssertEqual(provenance.objectValue?["matched_count"], .integer(Int64(rawCount / 400)))
        XCTAssertLessThanOrEqual(try bytes(provenance), ceiling)

        // Growth over the whole window: bounded page, honest matched count, budget under the ceiling.
        let window: [String: JSONValue] = [
            "from": .string(EvidenceTimestamp.format(bulkStart.addingTimeInterval(-1))),
            "through": .string(EvidenceTimestamp.format(second.addingTimeInterval(1))),
        ]
        let growth = try client.call(tool: "explain_growth", arguments: window.merging(["limit": .integer(500), "path_detail": .string("hashed")]) { _, new in new }, isCancelled: { false })
        XCTAssertEqual(growth.objectValue?["returned_count"], .integer(500))
        XCTAssertEqual(growth.objectValue?["truncated"], .bool(true))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(growth.objectValue?["matched_count"]?.integerValue), Int64(rawCount))
        XCTAssertLessThanOrEqual(try bytes(growth), ceiling)

        // Occurrence contract through IPC: a first sighting has no lower bound;
        // a measured modification is bounded by the two samples.
        let scanned = try client.call(tool: "get_provenance", arguments: ["path_query": .string("f-1.bin"), "limit": .integer(20)], isCancelled: { false })
        guard case let .array(items)? = scanned.objectValue?["items"] else { return XCTFail("Missing provenance items") }
        let changes = items.compactMap(\.objectValue).filter { $0["kind"] == .string("change") }
        XCTAssertEqual(changes.count, 2)
        let timings = changes.compactMap { $0["timing"]?.objectValue }
        XCTAssertTrue(timings.contains { $0["occurred_start"] == .null }, "First sighting must not carry a creation time")
        XCTAssertTrue(timings.contains { $0["occurred_start"] == .string(EvidenceTimestamp.format(first)) && $0["occurred_end"] == .string(EvidenceTimestamp.format(second)) })
        XCTAssertTrue(changes.contains { change in
            guard case let .array(claims)? = change["provenance_claims"] else { return false }
            return claims.contains { $0.objectValue?["session"]?.objectValue?["registration_id"] == .string(registrationID) }
        })

        // Task impact: a window that overlaps only the 200 measured modifications
        // returns bounded totals; a window whose possible overlap also admits the
        // 200 first sightings exceeds the 300-row admission and is refused with a
        // typed error rather than partial totals.
        let narrow = try client.call(tool: "get_task_impact", arguments: [
            "session_id": .string("cardinality-task"),
            "from": .string(EvidenceTimestamp.format(first.addingTimeInterval(0.5))),
            "through": .string(EvidenceTimestamp.format(second.addingTimeInterval(1))),
        ], isCancelled: { false })
        XCTAssertEqual(narrow.objectValue?["confidence"], .string("inferred"))
        XCTAssertEqual(narrow.objectValue?["surviving_object_count"], .integer(Int64(fileCount)))
        XCTAssertGreaterThan(try XCTUnwrap(narrow.objectValue?["historical_growth_bytes"]?.integerValue), 0)
        do {
            _ = try client.call(tool: "get_task_impact", arguments: window.merging(["session_id": .string("cardinality-task")]) { _, new in new }, isCancelled: { false })
            XCTFail("An overlap beyond the query budget must be refused, not partially totaled")
        } catch DiskStewardIPCError.remote(let code, _, let retryable) {
            XCTAssertEqual(code, "query_budget_exceeded")
            XCTAssertFalse(retryable)
        }

        // Decoded export: bounded event detail, explicit truncation, timing kept.
        let export = try client.call(tool: "export_evidence", arguments: window.merging(["max_events": .integer(100), "path_detail": .string("hashed")]) { _, new in new }, isCancelled: { false })
        guard case let .array(events)? = export.objectValue?["events"] else { return XCTFail("Missing exported events") }
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(export.objectValue?["truncated"], .bool(true))
        XCTAssertTrue(events.allSatisfy { $0.objectValue?["timing"]?.objectValue?["basis"] != nil })
        XCTAssertLessThanOrEqual(try bytes(export), ceiling)

        // Current consumers: 200 present objects, one page, byte-bounded.
        let current = try client.call(tool: "list_current_consumers", arguments: ["limit": .integer(500), "path_detail": .string("hashed")], isCancelled: { false })
        XCTAssertEqual(current.objectValue?["matched_count"], .integer(Int64(fileCount)))
        XCTAssertEqual(current.objectValue?["returned_count"], .integer(Int64(fileCount)))
        XCTAssertLessThanOrEqual(try bytes(current), ceiling)
        XCTAssertLessThan(Date().timeIntervalSince(started), 60, "Representative cardinality must stay interactive")
        await store.close()
    }
}
