@testable import DiskStewardCore
@testable import DiskStewardApp
import Foundation
import XCTest

final class EvidenceQueryPrivacyIPCIntegrationTests: XCTestCase {
    func testProvenanceCursorExpiresWhenPathBindingsChangeItsQueryBranch() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-branch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let watched = root.appending(path: "watch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = watched.appending(path: "new.bin")
        try Data([1]).write(to: path)
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        let now = Date()
        for index in 0..<2 {
            try await store.insert(.init(eventID: "raw-\(index)", observedAt: now.addingTimeInterval(Double(index)),
                operation: .modify, path: path.path, logicalDelta: 1, allocatedDelta: 1,
                consumerCategory: "watched-root", confidence: .unknown))
        }
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)
        let arguments: [String: JSONValue] = ["path_query": .string("new.bin"), "limit": .integer(1)]
        func pageCursor() throws -> String {
            try XCTUnwrap(client.call(tool: "get_provenance", arguments: arguments, isCancelled: { false }).objectValue?["next_cursor"]?.stringValue)
        }
        func assertExpired(_ cursor: String) throws {
            do {
                _ = try client.call(tool: "get_provenance", arguments: arguments.merging(["cursor": .string(cursor)]) { _, new in new }, isCancelled: { false })
                XCTFail("Branch-changing evidence must invalidate the page")
            } catch DiskStewardIPCError.remote(let code, _, let retryable) {
                XCTAssertEqual(code, "cursor_expired")
                XCTAssertFalse(retryable)
            }
        }
        let rawCursor = try pageCursor()
        let policy = MonitoringPolicy(watchedRoots: [watched])
        _ = try await store.recordObservation(
            snapshot: .init(snapshotID: "first-binding", observedAt: EvidenceTimestamp.format(now), volumes: []),
            metadata: DirectoryMetadataScanner().scan(policy: policy, at: now),
            scope: policy.scopeVersion(at: now), trigger: .scheduled)
        try assertExpired(rawCursor)
        let linkedCursor = try pageCursor()
        // Synthetic storage-boundary fixture only: force the reverse branch
        // transition without scanning or changing any real user's evidence.
        let fixture = try SQLiteConnection(url: database)
        try fixture.execute("DELETE FROM path_bindings")
        fixture.close()
        try assertExpired(linkedCursor)
        await store.close()
    }

    func testProvenanceLinkedSessionWithholdsTaskContextOutsideFullDetail() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-linked-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let watched = root.appending(path: "private-workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = watched.appending(path: "linked.bin")
        try Data([1]).write(to: file)
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)
        let privatePath = "/Users/private-owner/another-project"
        let registered = try client.send(method: "sessions/register", payload: .object([
            "client": .string("codex"), "session_id": .string("linked-task"),
            "workspace_roots": .array([.string(watched.path)]),
            "task_context": .string("Rewrite \(file.path); compare with \(privatePath)"),
            "lease_seconds": .integer(600)
        ]), isCancelled: { false })
        let registrationID = try XCTUnwrap(registered.objectValue?["registration_id"]?.stringValue)
        let storedSessions = try await store.agentSessions()
        let registration = try XCTUnwrap(storedSessions.first { $0.registrationID.uuidString.lowercased() == registrationID })
        let taskContext = try XCTUnwrap(registration.taskContext)
        XCTAssertTrue(taskContext.contains(privatePath))
        // Two observations inside the session lease bound the modification;
        // a first sighting alone has no supported occurrence lower bound.
        let policy = MonitoringPolicy(watchedRoots: [watched])
        let first = Date()
        _ = try await store.recordObservation(
            snapshot: .init(snapshotID: "linked-first", observedAt: EvidenceTimestamp.format(first), volumes: []),
            metadata: DirectoryMetadataScanner().scan(policy: policy, at: first),
            scope: policy.scopeVersion(at: first), trigger: .scheduled)
        try Data([1, 2, 3]).write(to: file)
        let second = first.addingTimeInterval(1)
        _ = try await store.recordObservation(
            snapshot: .init(snapshotID: "linked-second", observedAt: EvidenceTimestamp.format(second), volumes: []),
            metadata: DirectoryMetadataScanner().scan(policy: policy, at: second),
            scope: policy.scopeVersion(at: second), trigger: .scheduled)
        let chain = try await store.provenanceChain(pathQuery: "linked.bin", cursor: nil, limit: 100)
        let bounded = chain.events.filter { $0.timing?.occurredStart != nil }
        XCTAssertEqual(bounded.count, 1, "Exactly the modification carries a measured prior sample")
        let modification = try XCTUnwrap(bounded.first)
        // The product engine links the event to the registered session from
        // workspace and interval overlap alone; the fixture invents no writer.
        let claim = ProvenanceEngine().attribute(.init(event: modification, registrations: [registration]))
        XCTAssertNil(claim.actor)
        XCTAssertEqual(claim.confidence, .inferred)
        XCTAssertEqual(claim.session?.registrationID, registration.registrationID)
        try await store.persistProvenanceClaim(claim)
        for detail in ["basename", "hashed", "full"] {
            var arguments: [String: JSONValue] = [
                "path_query": .string("linked.bin"), "limit": .integer(1), "path_detail": .string(detail)
            ]
            var eventPage: JSONValue?
            var requests = 0
            while eventPage == nil {
                requests += 1
                guard requests <= 8 else { return XCTFail("\(detail): the linked event page was not reached") }
                let page = try client.call(tool: "get_provenance", arguments: arguments, isCancelled: { false })
                guard case let .array(items)? = page.objectValue?["items"] else { return XCTFail("\(detail): missing items") }
                if items.contains(where: { $0.objectValue?["event_id"] == .string(modification.eventID) }) {
                    eventPage = page
                    break
                }
                XCTAssertEqual(page.objectValue?["sessions"], .array([]), "\(detail) page \(requests) has no linked event")
                guard let cursor = page.objectValue?["next_cursor"]?.stringValue else {
                    return XCTFail("\(detail): pagination ended before the linked event")
                }
                arguments["cursor"] = .string(cursor)
            }
            let page = try XCTUnwrap(eventPage)
            guard case let .array(sessions)? = page.objectValue?["sessions"], let session = sessions.first?.objectValue else {
                return XCTFail("\(detail): the linked event page must carry its session")
            }
            XCTAssertEqual(sessions.count, 1, detail)
            XCTAssertEqual(session["registration_id"], .string(registrationID), detail)
            guard case let .array(items)? = page.objectValue?["items"],
                  let item = items.first(where: { $0.objectValue?["event_id"] == .string(modification.eventID) })?.objectValue,
                  case let .array(claims)? = item["provenance_claims"]
            else { return XCTFail("\(detail): missing linked claim projection") }
            XCTAssertEqual(claims.count, 1, detail)
            XCTAssertEqual(claims.first?.objectValue?["session"]?.objectValue?["registration_id"], .string(registrationID), detail)
            XCTAssertEqual(claims.first?.objectValue?["actor"], .null, detail)
            if detail == "full" {
                XCTAssertEqual(session["task_context"], .string(taskContext), "Full detail preserves unstructured context")
                XCTAssertEqual(session["task_context_withheld"], .bool(false))
            } else {
                XCTAssertEqual(session["task_context"], .null, "\(detail) must not project unstructured context")
                XCTAssertEqual(session["task_context_withheld"], .bool(true), detail)
                try assertPrivate(page, hidden: [root.path, privatePath], label: "get_provenance \(detail) linked session")
            }
        }
        await store.close()
    }

    func testAllTenToolsAndBothResourcesThroughIPCDoNotExposeSessionPaths() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-privacy-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let watched = root.appending(path: "private-workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["artifact-a.bin", "artifact-b.bin", "artifact-c.bin"] {
            try Data(repeating: 1, count: 4_096).write(to: watched.appending(path: name))
        }
        let database = root.appending(path: "evidence.sqlite")
        let now = Date()
        let policy = MonitoringPolicy(watchedRoots: [watched])
        let store = try EvidenceStore(url: database)
        _ = try await store.recordObservation(
            snapshot: .init(snapshotID: "privacy-baseline", observedAt: EvidenceTimestamp.format(now), volumes: []),
            metadata: DirectoryMetadataScanner().scan(policy: policy, at: now),
            scope: policy.scopeVersion(at: now), trigger: .scheduled)
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)
        _ = try client.send(method: "sessions/register", payload: .object([
            "client": .string("codex"), "session_id": .string("privacy-task"),
            "workspace_roots": .array([.string(watched.path)]),
            "task_context": .string("Investigate \(watched.path)/artifact-a.bin; also see /Users/private-owner/another-project"),
            "lease_seconds": .integer(600)
        ]), isCancelled: { false })
        let storedSessions = try await store.agentSessions()
        XCTAssertEqual(storedSessions.count, 1)
        XCTAssertTrue(try XCTUnwrap(storedSessions.first?.taskContext).contains(watched.path))
        let interval: [String: JSONValue] = [
            "from": .string(EvidenceTimestamp.format(now.addingTimeInterval(-60))),
            "through": .string(EvidenceTimestamp.format(now.addingTimeInterval(60)))
        ]
        let tools: [(String, [String: JSONValue], String)] = [
            ("get_storage_summary", [:], "storage-summary-v1"),
            ("get_evidence_lifecycle", [:], "evidence-lifecycle-v1"),
            ("list_current_consumers", ["limit": .integer(1)], "evidence-query-page-v1"),
            ("explain_growth", interval.merging(["limit": .integer(1)]) { _, new in new }, "evidence-query-page-v1"),
            ("get_provenance", ["path_query": .string("artifact-a.bin"), "limit": .integer(1)], "evidence-query-page-v1"),
            ("list_active_agent_sessions", ["limit": .integer(1)], "active-agent-sessions-v1"),
            ("list_active_writers", ["limit": .integer(1)], "active-writers-v1"),
            ("get_task_impact", ["session_id": .string("privacy-task"), "limit": .integer(1)], "task-impact-v1"),
            ("find_cleanup_candidates", ["minimum_bytes": .integer(1), "limit": .integer(1)], "cleanup-candidates-v2"),
            ("export_evidence", interval.merging(["max_events": .integer(1)]) { _, new in new }, "inline-evidence-bundle-v1")
        ]
        XCTAssertEqual(Set(tools.map { $0.0 }).count, 10)
        let detailTools: Set<String> = ["list_current_consumers", "explain_growth", "get_provenance", "find_cleanup_candidates", "export_evidence"]
        for (tool, arguments, schema) in tools {
            for detail in detailTools.contains(tool) ? ["basename", "hashed"] : ["basename"] {
                var request = arguments
                if detailTools.contains(tool) { request["path_detail"] = .string(detail) }
                let response = try client.call(tool: tool, arguments: request, isCancelled: { false })
                XCTAssertEqual(response.objectValue?["schema"], .string(schema), tool)
                if tool == "list_active_agent_sessions" {
                    guard case let .array(sessions)? = response.objectValue?["sessions"] else { return XCTFail("Missing sessions") }
                    XCTAssertEqual(sessions.count, 1)
                    XCTAssertEqual(sessions.first?.objectValue?["task_context"], .null, "Unstructured context is not path-private merely because workspace_roots are redacted")
                    XCTAssertEqual(sessions.first?.objectValue?["task_context_withheld"], .bool(true))
                }
                try assertPrivate(response, hidden: [root.path, "/Users/private-owner/another-project"], label: "\(tool) \(detail)")
                assertNoAbsolutePaths(response, label: "\(tool) \(detail)")
                if let count = response.objectValue?["returned_count"]?.integerValue {
                    XCTAssertLessThanOrEqual(count, 1, tool)
                }
                if let cursor = response.objectValue?["next_cursor"]?.stringValue {
                    XCTAssertTrue(cursor.hasPrefix("ds-page-"), tool)
                    XCTAssertNil(Data(base64Encoded: cursor), tool)
                    request["cursor"] = .string(cursor)
                    let next = try client.call(tool: tool, arguments: request, isCancelled: { false })
                    try assertPrivate(next, hidden: [root.path, "/Users/private-owner/another-project"], label: "\(tool) continuation")
                    assertNoAbsolutePaths(next, label: "\(tool) \(detail) continuation")
                }
            }
        }
        for (uri, schema) in [("disk-steward://status", "service-status-v1"), ("disk-steward://evidence-guide", "evidence-guide-v1")] {
            let response = try client.readResource(uri: uri, isCancelled: { false })
            XCTAssertEqual(response.objectValue?["schema"], .string(schema))
            try assertPrivate(response, hidden: [root.path, "/Users/private-owner/another-project"], label: uri)
            assertNoAbsolutePaths(response, label: uri)
        }
        let fullExport = try client.call(tool: "export_evidence", arguments: interval.merging([
            "path_detail": .string("full"), "max_events": .integer(1)
        ]) { _, new in new }, isCancelled: { false })
        guard case let .array(exportedSessions)? = fullExport.objectValue?["sessions"]?.objectValue?["sessions"] else {
            return XCTFail("Missing full-detail session history")
        }
        XCTAssertEqual(exportedSessions.count, 1)
        XCTAssertEqual(exportedSessions.first?.objectValue?["task_context"], storedSessions.first?.taskContext.map(JSONValue.string))
        XCTAssertEqual(exportedSessions.first?.objectValue?["task_context_withheld"], .bool(false))
        await store.close()
    }

    func testProvenancePagesShareOneRowBudgetWithoutLosingStatesOrEvents() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-provenance-page-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let watched = root.appending(path: "watch", directoryHint: .isDirectory)
        for name in ["one", "two", "three"] {
            let directory = watched.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appending(path: "same.bin"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let now = Date()
        let policy = MonitoringPolicy(watchedRoots: [watched])
        let store = try EvidenceStore(url: database)
        _ = try await store.recordObservation(
            snapshot: .init(snapshotID: "page-baseline", observedAt: EvidenceTimestamp.format(now), volumes: []),
            metadata: DirectoryMetadataScanner().scan(policy: policy, at: now),
            scope: policy.scopeVersion(at: now), trigger: .scheduled)
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)
        var expectedIDs: Set<String>?
        for limit in [1, 2, 3, 4, 6] {
            var cursor: String?
            var ids: [String] = []
            var kinds: [String] = []
            var requests = 0
            repeat {
                requests += 1
                guard requests <= 7 else { return XCTFail("Pagination did not converge") }
                var arguments: [String: JSONValue] = ["path_query": .string("same.bin"), "limit": .integer(Int64(limit)), "path_detail": .string("hashed")]
                if let cursor { arguments["cursor"] = .string(cursor) }
                let page = try client.call(tool: "get_provenance", arguments: arguments, isCancelled: { false })
                guard case let .array(items)? = page.objectValue?["items"] else { return XCTFail("Missing items") }
                XCTAssertFalse(items.isEmpty)
                XCTAssertLessThanOrEqual(items.count, limit)
                XCTAssertEqual(page.objectValue?["matched_count"], .integer(6), "Matched count must be stable across both page phases")
                XCTAssertEqual(page.objectValue?["state_as_of"], .string(EvidenceTimestamp.format(now)), "Paging into history must not lose the current-state observation time")
                for item in items {
                    let fields = try XCTUnwrap(item.objectValue)
                    let kind = try XCTUnwrap(fields["kind"]?.stringValue)
                    kinds.append(kind)
                    ids.append(kind + ":" + (try XCTUnwrap((fields["event_id"] ?? fields["object_id"])?.stringValue)))
                }
                try assertPrivate(page, hidden: [root.path], label: "provenance page")
                cursor = page.objectValue?["next_cursor"]?.stringValue
            } while cursor != nil
            XCTAssertEqual(ids.count, 6)
            XCTAssertEqual(Set(ids).count, 6)
            XCTAssertEqual(kinds.filter { $0 == "current-state" }.count, 3)
            XCTAssertEqual(kinds.filter { $0 == "change" }.count, 3)
            if let expectedIDs { XCTAssertEqual(Set(ids), expectedIDs) } else { expectedIDs = Set(ids) }
        }
        let first = try client.call(tool: "get_provenance", arguments: ["path_query": .string("same.bin"), "limit": .integer(1)], isCancelled: { false })
        let oldCursor = try XCTUnwrap(first.objectValue?["next_cursor"]?.stringValue)
        try await store.insert(.init(eventID: "revision-change", observedAt: now.addingTimeInterval(1), operation: .modify,
            path: watched.appending(path: "one/same.bin").path, logicalDelta: 1, allocatedDelta: 1, consumerCategory: "watched-root", confidence: .unknown))
        do {
            _ = try client.call(tool: "get_provenance", arguments: ["path_query": .string("same.bin"), "limit": .integer(1), "cursor": .string(oldCursor)], isCancelled: { false })
            XCTFail("Changed evidence must invalidate the combined cursor")
        } catch DiskStewardIPCError.remote(let code, _, let retryable) {
            XCTAssertEqual(code, "cursor_expired")
            XCTAssertFalse(retryable)
        }
        await store.close()
    }

    /// Structural privacy: in basename/hashed detail no string field anywhere in
    /// the response may carry an absolute filesystem path. Fixture-specific
    /// hidden strings only prove the fields a test happened to seed; this walks
    /// diagnostics, gap reasons, claim support, snapshot and limitation text too.
    private func assertNoAbsolutePaths(_ value: JSONValue, label: String, key: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        // Volume mount points are public system identifiers, not user paths.
        let allowedKeys: Set<String> = ["mount_path"]
        switch value {
        case .object(let object):
            for (child, childValue) in object { assertNoAbsolutePaths(childValue, label: label, key: child, file: file, line: line) }
        case .array(let children):
            for child in children { assertNoAbsolutePaths(child, label: label, key: key, file: file, line: line) }
        case .string(let text):
            if let key, allowedKeys.contains(key) { return }
            let leaks = text.hasPrefix("/") || ["/Users/", "/tmp/", "/private/", "/Volumes/"].contains { text.contains($0) }
            XCTAssertFalse(leaks, "\(label): field \(key ?? "?") carries an absolute path: \(text.prefix(120))", file: file, line: line)
        default:
            return
        }
    }

    private func assertPrivate(_ value: JSONValue, hidden: [String], label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        XCTAssertLessThan(data.count, 256 * 1_024, label, file: file, line: line)
        let text = String(decoding: data, as: UTF8.self)
        for path in hidden { XCTAssertFalse(text.contains(path), "\(label) disclosed a private path", file: file, line: line) }
    }
}
