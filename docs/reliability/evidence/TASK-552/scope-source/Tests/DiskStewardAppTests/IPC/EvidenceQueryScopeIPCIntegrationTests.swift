@testable import DiskStewardCore
@testable import DiskStewardApp
import Foundation
import XCTest

/// A policy the test changes between calls; no rescan happens in between.
private final class ScopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EvidenceQueryScope?
    init(_ value: EvidenceQueryScope?) { self.value = value }
    func get() -> EvidenceQueryScope? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ scope: EvidenceQueryScope?) { lock.lock(); value = scope; lock.unlock() }
}

final class EvidenceQueryScopeIPCIntegrationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let store: EvidenceStore
        let client: UnixSocketDiskStewardIPCClient
        let server: UnixSocketEvidenceServer
        let scope: ScopeBox
    }

    private func makeFixture(_ name: String, scope: EvidenceQueryScope?, responseByteCeiling: Int = 1_024 * 1_024) throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp/ds-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        let box = ScopeBox(scope)
        let backend = try AppEvidenceQueryBackend(databaseURL: database, queryScopeProvider: { box.get() }, responseByteCeiling: responseByteCeiling)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        return Fixture(root: root, store: store, client: UnixSocketDiskStewardIPCClient(socketPath: socket), server: server, scope: box)
    }

    private func observe(_ store: EvidenceStore, policy: MonitoringPolicy, id: String, at date: Date) async throws {
        _ = try await store.recordObservation(
            snapshot: .init(snapshotID: id, observedAt: EvidenceTimestamp.format(date), volumes: []),
            metadata: DirectoryMetadataScanner().scan(policy: policy, at: date),
            scope: policy.scopeVersion(at: date), trigger: .scheduled)
    }

    private func items(_ response: JSONValue) throws -> [[String: JSONValue]] {
        guard case let .array(values)? = response.objectValue?["items"] else { throw XCTSkip("no items") }
        return values.compactMap(\.objectValue)
    }

    private func paths(_ response: JSONValue) throws -> Set<String> {
        Set(try items(response).compactMap { $0["path"]?.stringValue })
    }

    private func limitations(_ response: JSONValue) -> [String] {
        guard case let .array(values)? = response.objectValue?["limitations"] else { return [] }
        return values.compactMap(\.stringValue)
    }

    func testChangingRootsAndExclusionsIsImmediatelyVisibleWithoutRescan() async throws {
        let now = Date()
        let alphaRoot = URL(fileURLWithPath: "/tmp/ds-scope-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let alpha = alphaRoot.appending(path: "alpha", directoryHint: .isDirectory)
        let beta = alphaRoot.appending(path: "beta", directoryHint: .isDirectory)
        for directory in [alpha, beta] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: alphaRoot) }
        try Data(repeating: 1, count: 2_048).write(to: alpha.appending(path: "alpha.bin"))
        try Data(repeating: 2, count: 2_048).write(to: beta.appending(path: "beta.bin"))
        let both = MonitoringPolicy(watchedRoots: [alpha, beta])
        let fixture = try makeFixture("scope-change", scope: EvidenceQueryScope(both.scopeVersion(at: now)))
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        try await observe(fixture.store, policy: both, id: "scope-baseline", at: now)
        let interval: [String: JSONValue] = [
            "from": .string(EvidenceTimestamp.format(now.addingTimeInterval(-60))),
            "through": .string(EvidenceTimestamp.format(now.addingTimeInterval(60))),
        ]
        func current() throws -> JSONValue { try fixture.client.call(tool: "list_current_consumers", arguments: ["limit": .integer(10)], isCancelled: { false }) }
        func cleanup() throws -> JSONValue { try fixture.client.call(tool: "find_cleanup_candidates", arguments: ["minimum_bytes": .integer(1), "limit": .integer(10)], isCancelled: { false }) }
        func growth() throws -> JSONValue { try fixture.client.call(tool: "explain_growth", arguments: interval.merging(["limit": .integer(10)]) { _, new in new }, isCancelled: { false }) }
        func provenance(_ query: String) throws -> JSONValue { try fixture.client.call(tool: "get_provenance", arguments: ["path_query": .string(query), "limit": .integer(10)], isCancelled: { false }) }
        func exportPaths() throws -> Set<String> {
            let bundle = try fixture.client.call(tool: "export_evidence", arguments: interval.merging(["path_detail": .string("full"), "max_events": .integer(50)]) { _, new in new }, isCancelled: { false })
            guard case let .array(records)? = bundle.objectValue?["current_state"]?.objectValue?["items"] else { return [] }
            return Set(records.compactMap { $0.objectValue?["path"]?.stringValue })
        }
        func lifecycleScope() throws -> [String: JSONValue] {
            let lifecycle = try fixture.client.call(tool: "get_evidence_lifecycle", arguments: [:], isCancelled: { false })
            return try XCTUnwrap(lifecycle.objectValue?["effective_scope"]?.objectValue)
        }

        XCTAssertEqual(try paths(current()), ["alpha.bin", "beta.bin"])
        XCTAssertEqual(try paths(cleanup()), ["alpha.bin", "beta.bin"])
        XCTAssertTrue(try paths(growth()).isSuperset(of: ["alpha.bin", "beta.bin"]))
        XCTAssertGreaterThan(try items(provenance("beta.bin")).count, 0)
        XCTAssertTrue(try exportPaths().contains(beta.appending(path: "beta.bin").path))
        XCTAssertEqual(try lifecycleScope()["matches_latest_scan"], .bool(true))
        XCTAssertEqual(try current().objectValue?["scope"]?.objectValue?["hidden_by_scope_count"], .integer(0))

        // Exclude beta without any rescan: every tool must hide it immediately.
        fixture.scope.set(EvidenceQueryScope(MonitoringPolicy(watchedRoots: [alpha, beta], excludedRoots: [beta]).scopeVersion(at: Date())))
        let excludedPage = try current()
        XCTAssertEqual(try paths(excludedPage), ["alpha.bin"])
        XCTAssertEqual(excludedPage.objectValue?["matched_count"], .integer(1))
        XCTAssertEqual(excludedPage.objectValue?["scope"]?.objectValue?["applied"], .bool(true))
        XCTAssertEqual(excludedPage.objectValue?["scope"]?.objectValue?["hidden_by_scope_count"], .integer(1))
        XCTAssertTrue(limitations(excludedPage).contains { $0.contains("hidden by the current watched roots") }, "\(limitations(excludedPage))")
        let excludedCleanup = try cleanup()
        XCTAssertEqual(try paths(excludedCleanup), ["alpha.bin"])
        XCTAssertEqual(excludedCleanup.objectValue?["scope"]?.objectValue?["hidden_by_scope_count"], .integer(1))
        XCTAssertFalse(try paths(growth()).contains("beta.bin"))
        let hiddenProvenance = try provenance("beta.bin")
        XCTAssertEqual(hiddenProvenance.objectValue?["returned_count"], .integer(0))
        XCTAssertEqual(hiddenProvenance.objectValue?["matched_count"], .integer(0))
        XCTAssertEqual(hiddenProvenance.objectValue?["scope"]?.objectValue?["applied"], .bool(true))
        XCTAssertFalse(try exportPaths().contains(beta.appending(path: "beta.bin").path))
        XCTAssertTrue(try exportPaths().contains(alpha.appending(path: "alpha.bin").path))
        let excludedScope = try lifecycleScope()
        XCTAssertEqual(excludedScope["matches_latest_scan"], .bool(false))
        XCTAssertEqual(excludedScope["excluded"], .array([.string("beta")]))

        // Removing the root entirely behaves the same way.
        fixture.scope.set(EvidenceQueryScope(MonitoringPolicy(watchedRoots: [alpha]).scopeVersion(at: Date())))
        XCTAssertEqual(try paths(current()), ["alpha.bin"])
        XCTAssertEqual(try current().objectValue?["scope"]?.objectValue?["active_root_count"], .integer(1))

        // Restoring the policy restores visibility: nothing was reinterpreted as deleted.
        fixture.scope.set(EvidenceQueryScope(both.scopeVersion(at: Date())))
        XCTAssertEqual(try paths(current()), ["alpha.bin", "beta.bin"])
        let restored = try items(provenance("beta.bin"))
        XCTAssertTrue(restored.contains { $0["kind"] == .string("current-state") && $0["presence"] == .string("present") })
        XCTAssertFalse(restored.contains { $0["operation"] == .string("delete") })
        XCTAssertEqual(try lifecycleScope()["matches_latest_scan"], .bool(true))
        await fixture.store.close()
    }

    /// The production wiring: the backend reads the user's live settings on the
    /// main actor for every request, exactly as StatusItemController wires it.
    func testExclusionAddedInTheSettingsStoreIsVisibleOnTheNextQuery() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-scope-settings-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let alpha = root.appending(path: "alpha", directoryHint: .isDirectory)
        let beta = root.appending(path: "beta", directoryHint: .isDirectory)
        for directory in [alpha, beta] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 2_048).write(to: alpha.appending(path: "alpha.bin"))
        try Data(repeating: 2, count: 2_048).write(to: beta.appending(path: "beta.bin"))
        let settingsStore = await MainActor.run { () -> MonitoringSettingsStore in
            let store = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence(), key: "scope-test")
            store.update { $0.watchedRoots = [alpha.path, beta.path]; $0.excludedRoots = [] }
            return store
        }
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        let backend = try AppEvidenceQueryBackend(
            databaseURL: database,
            queryScopeProvider: { await MainActor.run { EvidenceQueryScope(settingsStore.settings.monitoringPolicy(at: Date()).scopeVersion(at: Date())) } })
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)
        let policy = await MainActor.run { settingsStore.settings.monitoringPolicy(at: Date()) }
        try await observe(store, policy: policy, id: "settings-baseline", at: Date())
        func current() throws -> JSONValue { try client.call(tool: "list_current_consumers", arguments: ["limit": .integer(10)], isCancelled: { false }) }
        XCTAssertEqual(try paths(current()), ["alpha.bin", "beta.bin"])
        await MainActor.run { settingsStore.addExcludedRoot(beta) }
        let excluded = try current()
        XCTAssertEqual(try paths(excluded), ["alpha.bin"])
        XCTAssertEqual(excluded.objectValue?["scope"]?.objectValue?["hidden_by_scope_count"], .integer(1))
        await MainActor.run { settingsStore.removeExcludedRoot(beta.path) }
        XCTAssertEqual(try paths(current()), ["alpha.bin", "beta.bin"])
        await MainActor.run { settingsStore.removeWatchedRoot(beta.path) }
        XCTAssertEqual(try paths(current()), ["alpha.bin"])
        let lifecycle = try client.call(tool: "get_evidence_lifecycle", arguments: [:], isCancelled: { false })
        XCTAssertEqual(lifecycle.objectValue?["effective_scope"]?.objectValue?["matches_latest_scan"], .bool(false))
        await store.close()
    }

    func testEmptyStoreReportsMissingEvidenceExplicitlyAcrossAllToolsAndResources() async throws {
        let fixture = try makeFixture("scope-empty", scope: nil)
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date()
        let interval: [String: JSONValue] = [
            "from": .string(EvidenceTimestamp.format(now.addingTimeInterval(-60))),
            "through": .string(EvidenceTimestamp.format(now.addingTimeInterval(60))),
        ]
        let pageTools: [(String, [String: JSONValue])] = [
            ("list_current_consumers", ["limit": .integer(5)]),
            ("explain_growth", interval.merging(["limit": .integer(5)]) { _, new in new }),
            ("get_provenance", ["path_query": .string("missing.bin"), "limit": .integer(5)]),
        ]
        for (tool, arguments) in pageTools {
            let page = try fixture.client.call(tool: tool, arguments: arguments, isCancelled: { false })
            XCTAssertEqual(page.objectValue?["coverage"], .string("none"), tool)
            XCTAssertEqual(page.objectValue?["state_as_of"], .null, tool)
            XCTAssertEqual(page.objectValue?["state_age_seconds"], .null, tool)
            XCTAssertEqual(page.objectValue?["matched_count"], .integer(0), tool)
            XCTAssertEqual(page.objectValue?["returned_count"], .integer(0), tool)
            XCTAssertEqual(page.objectValue?["scope"]?.objectValue?["applied"], .bool(false), tool)
            XCTAssertNotNil(page.objectValue?["budget"]?.objectValue?["row_limit_applied"], tool)
            XCTAssertTrue(limitations(page).contains { $0.contains("No completed observation exists") }, "\(tool): \(limitations(page))")
        }
        let cleanup = try fixture.client.call(tool: "find_cleanup_candidates", arguments: ["minimum_bytes": .integer(1), "limit": .integer(5)], isCancelled: { false })
        XCTAssertEqual(cleanup.objectValue?["coverage"], .string("none"))
        XCTAssertEqual(cleanup.objectValue?["state_as_of"], .null)
        XCTAssertEqual(cleanup.objectValue?["returned_count"], .integer(0))
        let lifecycle = try fixture.client.call(tool: "get_evidence_lifecycle", arguments: [:], isCancelled: { false })
        XCTAssertNotEqual(lifecycle.objectValue?["coverage"], .string("complete"))
        XCTAssertEqual(lifecycle.objectValue?["effective_scope"], .null)
        let storage = try fixture.client.call(tool: "get_storage_summary", arguments: [:], isCancelled: { false })
        XCTAssertEqual(storage.objectValue?["persisted_state_as_of"], .null)
        XCTAssertNotEqual(storage.objectValue?["coverage"], .string("complete"))
        XCTAssertEqual(storage.objectValue?["current_consumer_count"], .integer(0))
        for tool in ["list_active_agent_sessions", "list_active_writers"] {
            let sessions = try fixture.client.call(tool: tool, arguments: ["limit": .integer(5)], isCancelled: { false })
            XCTAssertEqual(sessions.objectValue?["matched_count"], .integer(0), tool)
            XCTAssertEqual(sessions.objectValue?["truncated"], .bool(false), tool)
            XCTAssertNotNil(sessions.objectValue?["budget"]?.objectValue?["response_byte_ceiling"], tool)
        }
        do {
            _ = try fixture.client.call(tool: "get_task_impact", arguments: ["session_id": .string("absent")], isCancelled: { false })
            XCTFail("Missing session evidence must be a typed error, not zero impact")
        } catch DiskStewardIPCError.remote(let code, _, let retryable) {
            XCTAssertEqual(code, "session_unavailable")
            XCTAssertFalse(retryable)
        }
        let export = try fixture.client.call(tool: "export_evidence", arguments: interval.merging(["max_events": .integer(5)]) { _, new in new }, isCancelled: { false })
        XCTAssertEqual(export.objectValue?["events"], .array([]))
        XCTAssertEqual(export.objectValue?["scope"]?.objectValue?["applied"], .bool(false))
        let status = try fixture.client.readResource(uri: "disk-steward://status", isCancelled: { false })
        XCTAssertEqual(status.objectValue?["schema"], .string("service-status-v1"))
        XCTAssertTrue(status.objectValue?["detail"]?.stringValue?.contains("0 retained raw events") == true)
        let guide = try fixture.client.readResource(uri: "disk-steward://evidence-guide", isCancelled: { false })
        XCTAssertEqual(guide.objectValue?["schema"], .string("evidence-guide-v1"))
        await fixture.store.close()
    }

    func testActiveSessionCursorExpiresWhenSessionMembershipChanges() async throws {
        let fixture = try makeFixture("scope-sessions", scope: nil)
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        // One process identity may hold one active session, so each session
        // registers a distinct ancestor of the test process.
        let ancestry = LocalProcessInspector().snapshot(startingAt: getpid())
        var pids: [Int32] = []
        var identity = LocalProcessInspector().identity(pid: getpid())
        while let current = identity, pids.count < 3 {
            pids.append(current.pid)
            identity = ancestry.records[current]?.parent
        }
        guard pids.count == 3 else { throw XCTSkip("Fewer than three ancestor processes are visible") }
        func register(_ id: String, pid: Int32) throws {
            _ = try fixture.client.send(method: "sessions/register", payload: .object([
                "client": .string("codex"), "session_id": .string(id), "process_pid": .integer(Int64(pid)),
                "workspace_roots": .array([.string(fixture.root.path)]), "lease_seconds": .integer(600),
            ]), isCancelled: { false })
        }
        try register("one", pid: pids[0]); try register("two", pid: pids[1])
        do {
            try register("duplicate", pid: pids[0])
            XCTFail("A second active session for one process must be a typed conflict")
        } catch DiskStewardIPCError.remote(let code, _, let retryable) {
            XCTAssertEqual(code, "session_conflict")
            XCTAssertFalse(retryable)
        }
        let first = try fixture.client.call(tool: "list_active_agent_sessions", arguments: ["limit": .integer(1)], isCancelled: { false })
        XCTAssertEqual(first.objectValue?["returned_count"], .integer(1))
        let cursor = try XCTUnwrap(first.objectValue?["next_cursor"]?.stringValue)
        try register("three", pid: pids[2])
        do {
            _ = try fixture.client.call(tool: "list_active_agent_sessions", arguments: ["limit": .integer(1), "cursor": .string(cursor)], isCancelled: { false })
            XCTFail("A membership change must expire the session page")
        } catch DiskStewardIPCError.remote(let code, _, let retryable) {
            XCTAssertEqual(code, "cursor_expired")
            XCTAssertFalse(retryable)
        }
        var seen: [String] = []
        var next: String?
        var requests = 0
        repeat {
            requests += 1
            guard requests <= 5 else { return XCTFail("Pagination did not converge") }
            var arguments: [String: JSONValue] = ["limit": .integer(1)]
            if let next { arguments["cursor"] = .string(next) }
            let page = try fixture.client.call(tool: "list_active_agent_sessions", arguments: arguments, isCancelled: { false })
            XCTAssertEqual(page.objectValue?["matched_count"], .integer(3))
            guard case let .array(sessions)? = page.objectValue?["sessions"] else { return XCTFail("Missing sessions") }
            seen += sessions.compactMap { $0.objectValue?["session_id"]?.stringValue }
            next = page.objectValue?["next_cursor"]?.stringValue
        } while next != nil
        XCTAssertEqual(Set(seen), ["one", "two", "three"])
        XCTAssertEqual(seen.count, 3, "Each session appears exactly once")
        await fixture.store.close()
    }

    func testProvenanceIdentityBoundIsReportedHonestly() async throws {
        let watched = URL(fileURLWithPath: "/tmp/ds-scope-ident-\(UUID().uuidString.prefix(8))", isDirectory: true)
        for index in 0..<(EvidenceStore.provenanceIdentityLimit + 1) {
            let directory = watched.appending(path: String(format: "d%03d", index), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([UInt8(index & 0xff)]).write(to: directory.appending(path: "same.bin"))
        }
        defer { try? FileManager.default.removeItem(at: watched) }
        let policy = MonitoringPolicy(watchedRoots: [watched])
        let fixture = try makeFixture("scope-ident", scope: EvidenceQueryScope(policy.scopeVersion(at: Date())))
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        try await observe(fixture.store, policy: policy, id: "identities", at: Date())
        let page = try fixture.client.call(tool: "get_provenance", arguments: ["path_query": .string("same.bin"), "limit": .integer(500), "path_detail": .string("hashed")], isCancelled: { false })
        guard case let .array(objectIDs)? = page.objectValue?["object_ids"] else { return XCTFail("Missing object_ids") }
        XCTAssertEqual(objectIDs.count, EvidenceStore.provenanceIdentityLimit)
        XCTAssertEqual(page.objectValue?["identity_limit_reached"], .bool(true))
        XCTAssertTrue(limitations(page).contains { $0.contains("More than \(EvidenceStore.provenanceIdentityLimit) file identities matched") }, "\(limitations(page))")
        await fixture.store.close()
    }

    func testResponseByteCeilingClampsRowsBeforeReadAndRejectsOversizedResponses() async throws {
        let watched = URL(fileURLWithPath: "/tmp/ds-scope-budget-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        for index in 0..<40 { try Data(repeating: UInt8(index), count: 512).write(to: watched.appending(path: "file-\(index).bin")) }
        defer { try? FileManager.default.removeItem(at: watched) }
        let policy = MonitoringPolicy(watchedRoots: [watched])
        let ceiling = 16 * 1_024
        let fixture = try makeFixture("scope-budget", scope: EvidenceQueryScope(policy.scopeVersion(at: Date())), responseByteCeiling: ceiling)
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        try await observe(fixture.store, policy: policy, id: "budget", at: Date())
        let page = try fixture.client.call(tool: "list_current_consumers", arguments: ["limit": .integer(100)], isCancelled: { false })
        let budget = try XCTUnwrap(page.objectValue?["budget"]?.objectValue)
        XCTAssertEqual(budget["row_limit_requested"], .integer(100))
        XCTAssertEqual(budget["response_byte_ceiling"], .integer(Int64(ceiling)))
        let applied = try XCTUnwrap(budget["row_limit_applied"]?.integerValue)
        XCTAssertLessThan(applied, 100, "Rows are clamped before the store read")
        XCTAssertEqual(page.objectValue?["returned_count"], .integer(applied))
        XCTAssertEqual(page.objectValue?["truncated"], .bool(true))
        XCTAssertTrue(limitations(page).contains { $0.contains("reduced to \(applied)") }, "\(limitations(page))")
        let encoder = JSONEncoder()
        XCTAssertLessThanOrEqual(try encoder.encode(page).count, ceiling)
        let interval: [String: JSONValue] = [
            "from": .string(EvidenceTimestamp.format(Date().addingTimeInterval(-60))),
            "through": .string(EvidenceTimestamp.format(Date().addingTimeInterval(60))),
        ]
        let tiny = try makeFixture("scope-tiny", scope: nil, responseByteCeiling: 4 * 1_024)
        defer { tiny.server.stop(); try? FileManager.default.removeItem(at: tiny.root) }
        do {
            _ = try tiny.client.call(tool: "export_evidence", arguments: interval.merging(["max_events": .integer(5)]) { _, new in new }, isCancelled: { false })
            XCTFail("A response above the ceiling must fail with a typed error, not a partial page")
        } catch DiskStewardIPCError.remote(let code, _, let retryable) {
            XCTAssertEqual(code, "response_too_large")
            XCTAssertFalse(retryable)
        }
        await tiny.store.close()
        await fixture.store.close()
    }
}
