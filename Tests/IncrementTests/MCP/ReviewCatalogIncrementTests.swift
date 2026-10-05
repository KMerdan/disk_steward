import CoreServices
@testable import DiskStewardApp
@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-671 through the real helper: every listed tool answers under the
/// backend's 1 MiB ceiling with every steward and capacity table at its cap and
/// the per-file detail store unavailable; and an agent asked what can be
/// cleaned quotes the review window's numbers and states.
@MainActor
final class ReviewCatalogIncrementTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/ds-catalog-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var steward: URL { root.appending(path: "steward.sqlite") }
    private var scope: String { DirectoryChangeStream.canonicalPath(root.path + "/code") }

    static let tools = ["get_storage_summary", "get_health", "explain_growth", "list_review_items", "list_largest_objects",
                        "get_review_item_evidence", "measure_path", "list_active_agent_sessions", "get_task_impact", "export_evidence"]

    private func write(_ relative: String, bytes: Int) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 5, count: bytes).write(to: url)
    }

    /// A small real project, reviewed and stored, so the window and the tools
    /// have something real to agree on.
    private func reviewedProject(index: ReviewIndex) async throws -> ReviewService {
        try write("code/web/package.json", bytes: 100)
        try write("code/web/pnpm-lock.yaml", bytes: 100)
        try write("code/web/node_modules/.modules.yaml", bytes: 100)
        try write("code/web/node_modules/a/index.js", bytes: 300_000)
        try write("code/engine/Cargo.toml", bytes: 100)
        try write("code/engine/target/debug/app", bytes: 700_000)
        let service = ReviewService(index: index, stateURL: root.appending(path: "review-state.json"), makeWalker: { previous, cancelled in
            ReviewWalker(decider: ClassifierObjectDecider(oracle: SilentRepositoryOracle()), previousCompleteEntries: previous, isCancelled: cancelled)
        }, makeMeasureWalker: { budget, cancelled in
            ReviewWalker(decider: ClassifierObjectDecider(oracle: SilentRepositoryOracle()), budget: budget, isCancelled: cancelled)
        })
        _ = try await service.review(scope: scope)
        return service
    }

    private func backend(index: ReviewIndex, service: ReviewService, growth: GrowthAttributionService?) throws -> AppEvidenceQueryBackend {
        try AppEvidenceQueryBackend(databaseURL: root.appending(path: "evidence.sqlite"), capacityRingURL: root.appending(path: "capacity.sqlite"),
                                    changeJournalURL: steward, fileDetail: .retired(supportDirectory: root), growthAttribution: growth,
                                    sessionStore: try SessionStore(url: steward), reviewIndex: index, watchedRoots: { [scope] in [scope] },
                                    reviewService: service, reviewRoots: { [scope] in [scope] })
    }

    // MARK: Filling every table to its cap

    private func fillToCaps(now: Date) async throws {
        let long = String(repeating: "deep-folder-name/", count: 12)
        let connection = try SQLiteConnection(url: steward)
        try connection.prepareBoundedStore(.steward)
        let tables = Dictionary(uniqueKeysWithValues: (BoundedStoreContract.tables[.steward] ?? []).map { ($0.name, $0) })
        func fill(_ name: String, _ count: Int, chunk: Int = 2_000, _ row: (Int) -> [String: BoundedValue]) throws {
            let table = try XCTUnwrap(tables[name])
            var start = 0
            while start < count {
                _ = try connection.insertBounded(table, rows: (start..<min(count, start + chunk)).map(row))
                start += chunk
            }
        }
        let hourAgo = ChangeJournal.intervalStart(now.addingTimeInterval(-3_600)).timeIntervalSince1970
        try fill("journal_dirty", 14_000) { index in
            let path = "\(self.scope)/web/\(long)d\(index)"
            return ["interval_start": .real(hourAgo - Double(index % 6) * 300), "path_key": .text(ReviewIndex.key(path)), "path": .text(path),
                    "kind": .text("changed"), "changes": .integer(Int64(index % 50 + 1))]
        }
        try fill("projects", 2_000) { index in
            ["project_id": .text(ReviewIndex.key("p\(index)")), "path": .text("\(self.scope)/\(long)p\(index)"), "kind": .text("package.json"),
             "last_source_activity": .real(now.timeIntervalSince1970 - Double(index))]
        }
        try fill("object_index", 20_000) { index in
            let path = "\(self.scope)/\(long)o\(index)/node_modules"
            return ["object_id": .text(ReviewIndex.key("o\(index)")), "project_id": .text(""), "path_key": .text(ReviewIndex.key(path)), "path": .text(path),
                    "kind": .text("artifact"), "recreate_class": .text("redownload"), "allocated_bytes": .integer(Int64(index) * 4_096),
                    "file_count": .integer(10), "measured_at": .real(now.timeIntervalSince1970 - 60), "last_activity": .real(now.timeIntervalSince1970 - 600)]
        }
        let detail = String(decoding: try JSONEncoder().encode(StoredReviewItem.Detail(
            command: "pnpm install --frozen-lockfile", known: true,
            reasons: Array(repeating: "Its project last changed 120 days ago and it can be downloaded again from the registry.", count: 6))), as: UTF8.self)
        let limitations = String(decoding: try JSONEncoder().encode(Array(repeating: "A limitation sentence that a stopped review states about what it did not cover.", count: 40)), as: UTF8.self)
        for report in 0..<20 {
            let started = now.addingTimeInterval(-Double(20 - report) * 86_400)
            try fill("review_reports", 1) { _ in
                ["report_id": .text("caps-\(report)"), "scope": .text("\(self.scope)/scope-\(report)"), "started_at": .real(started.timeIntervalSince1970),
                 "completed_at": .real(started.timeIntervalSince1970 + 60), "coverage": .text("partial"), "status": .text("stopped:wall-time"),
                 "total_items": .integer(2_000), "truncated": .integer(1), "limitations": .text(String(limitations.prefix(4_096)))]
            }
            try fill("review_items", 2_000) { rank in
                ["report_id": .text("caps-\(report)"), "report_started_at": .real(started.timeIntervalSince1970), "rank": .integer(Int64(rank + 1)),
                 "object_id": .text(ReviewIndex.key("o\(rank)")), "project_id": .text(""), "path": .text("\(self.scope)/\(long)o\(rank)/node_modules"),
                 "kind": .text("artifact"), "recreate_class": .text("redownload"), "allocated_bytes": .integer(Int64(2_000 - rank) * 4_096),
                 "reclaimable_bytes": .integer(Int64(2_000 - rank) * 4_096), "state": .text("review-required"),
                 "verified_at": .real(started.timeIntervalSince1970 + 60), "reasons": .text(String(detail.prefix(1_024)))]
            }
        }
        try fill("sessions", 500) { index in
            ["session_id": .text("s-\(index)"), "cwd": .text("{\"r\":[\"\(self.scope)/web\"],\"t\":false}"), "client": .text("codex"),
             "started_at": .real(now.timeIntervalSince1970 - 7_200 + Double(index)), "ended_at": .real(now.timeIntervalSince1970 - 600)]
        }
        for session in 0..<50 {
            try fill("session_impacts", 200) { index in
                let path = "\(self.scope)/web/\(long)d\(index)"
                return ["session_id": .text("s-\(session)"), "session_started_at": .real(now.timeIntervalSince1970 - 7_200 + Double(session)),
                        "path_key": .text(ReviewIndex.key(path)), "path": .text(path), "changes": .integer(3)]
            }
        }
        connection.close()
        // The capacity ring at its caps.
        let ring = try SQLiteConnection(url: root.appending(path: "capacity.sqlite"))
        try ring.prepareBoundedStore(.capacityRing)
        let ringTables = Dictionary(uniqueKeysWithValues: (BoundedStoreContract.tables[.capacityRing] ?? []).map { ($0.name, $0) })
        let volumes = try XCTUnwrap(ringTables["capacity_volumes"])
        _ = try ring.insertBounded(volumes, rows: (0..<16).map { ["volume_id": .integer(Int64($0)), "volume_uuid": .text("UUID-\($0)"),
                                                                  "mount_path": .text("/Volumes/v\($0)"), "first_seen_at": .real(now.timeIntervalSince1970 - 86_400)] })
        for name in ["capacity_fine", "capacity_hourly"] {
            let table = try XCTUnwrap(ringTables[name])
            var start = 0
            while start < table.rowCap {
                _ = try ring.insertBounded(table, rows: (start..<min(table.rowCap, start + 2_000)).map { index in
                    ["volume_id": .integer(Int64(index % 4)), "observed_at": .real(now.timeIntervalSince1970 - Double(table.rowCap - index) * 300),
                     "total_bytes": .integer(1_000_000_000_000), "available_bytes": .integer(400_000_000_000 - Int64(index) * 1_000),
                     "important_available_bytes": .integer(410_000_000_000)]
                })
                start += 2_000
            }
        }
        ring.close()
    }

    /// Eight stored growth attributions with 100 long-path objects each.
    private func fullAttributions(now: Date) throws -> GrowthAttributionService {
        let long = String(repeating: "deep-folder-name/", count: 12)
        let attributions = (0..<8).map { index in
            GrowthAttribution(attributionID: "a-\(index)", trigger: .threshold, from: now.addingTimeInterval(-Double(index + 1) * 900),
                              through: now.addingTimeInterval(-Double(index) * 900 - 900),
                              volume: .init(deltaBytes: 9_000_000, firstSampleAt: now.addingTimeInterval(-7_200), lastSampleAt: now.addingTimeInterval(-900)),
                              attributedBytes: 4_000_000, unexplainedBytes: 5_000_000,
                              objects: (0..<100).map { ObjectGrowth(path: "\(self.scope)/\(long)o\($0)/node_modules", basis: .measured, changes: 4,
                                                                    previousBytes: 1_000, previousMeasuredAt: now.addingTimeInterval(-86_400),
                                                                    currentBytes: 41_000, deltaBytes: 40_000, unreadableDirectories: 0) },
                              objectsOmitted: 400, unmeasuredDirectories: (0..<24).map { "\(self.scope)/\(long)u\($0)" }, unmeasuredDirectoryCount: 900,
                              gaps: [], stopReason: .wallTime, limitations: Array(repeating: "A limitation of this attribution.", count: 8))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let file = GrowthAttributionService.defaultFileURL(beside: steward)
        try encoder.encode(attributions).write(to: file)
        return GrowthAttributionService(journal: try ChangeJournal(url: steward), index: try ReviewIndex(url: steward),
                                        ringURL: root.appending(path: "capacity.sqlite"), fileURL: file)
    }

    func testEveryToolAnswersUnderTheCeilingAtCapsThroughTheRealHelper() async throws {
        let now = Date()
        let index = try ReviewIndex(url: steward)
        let service = try await reviewedProject(index: index)
        try await fillToCaps(now: now)
        try Data(repeating: 0x5A, count: 8_192).write(to: root.appending(path: "evidence.sqlite"))  // the detail store is corrupt
        let growth = try fullAttributions(now: now)
        let backend = try backend(index: index, service: service, growth: growth)
        let socket = root.appending(path: "s.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend, timeoutSeconds: AppEvidenceQueryBackend.socketTimeoutSeconds)
        try server.start()
        defer { server.stop() }

        let helper = try InteractiveHelper(socket: socket)
        defer { helper.close() }
        _ = try helper.request(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"caps","version":"1"}}}"#, id: 1)
        helper.send(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#)
        let listed = try XCTUnwrap((try helper.request(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#, id: 2)["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(listed.compactMap { $0["name"] as? String }, Self.tools)
        // TASK-713: every answer conforms to the outputSchema its tool lists.
        let outputSchemas = Dictionary(uniqueKeysWithValues: try listed.map { tool in
            (try XCTUnwrap(tool["name"] as? String), try XCTUnwrap(tool["outputSchema"] as? [String: Any], "\(tool["name"] ?? "?") lists an outputSchema"))
        })
        let validator = OutputSchemaValidator()

        let formatter = ISO8601DateFormatter()
        // A window that ends before the present: answered from what is stored, nothing measured.
        let past: [String: Any] = ["from": formatter.string(from: now.addingTimeInterval(-3 * 3_600)), "through": formatter.string(from: now.addingTimeInterval(-15 * 60))]
        let items = try call(helper, id: 10, "list_review_items", ["limit": 500])
        let firstItem = try XCTUnwrap((items["items"] as? [[String: Any]])?.first?["item_id"] as? String)
        var calls: [(String, [String: Any])] = [
            ("get_storage_summary", [:]), ("get_health", [:]), ("explain_growth", past.merging(["limit": 500]) { $1 }),
            ("list_largest_objects", ["limit": 500]), ("get_review_item_evidence", ["item_id": firstItem, "path_detail": "full"]),
            ("measure_path", ["path": scope + "/web"]), ("list_active_agent_sessions", [:]),
            ("get_task_impact", ["session_id": "s-499", "limit": 500]), ("export_evidence", past.merging(["path_detail": "full", "max_events": 10_000]) { $1 }),
        ]
        calls.append(("list_review_items", ["limit": 500, "path_detail": "full"]))
        // The newest stored review is the small real one; a full 2,000-item report is asked by scope.
        calls.append(("list_review_items", ["scope": scope + "/scope-19", "limit": 500, "path_detail": "full"]))
        var sizes: [String: Int] = [:]
        for (offset, (tool, arguments)) in calls.enumerated() {
            let answer = try call(helper, id: 20 + offset, tool, arguments)
            XCTAssertEqual(validator.validate(instance: answer, schema: try XCTUnwrap(outputSchemas[tool])), [], "\(tool) conforms to its outputSchema")
            let bytes = try JSONSerialization.data(withJSONObject: answer).count
            sizes[tool] = max(sizes[tool] ?? 0, bytes)
            XCTAssertLessThan(bytes, 1_024 * 1_024, "\(tool) answers under the backend's 1 MiB ceiling at caps")
        }
        for (offset, uri) in ["disk-steward://status", "disk-steward://evidence-guide"].enumerated() {
            let response = try helper.request(#"{"jsonrpc":"2.0","id":\#(60 + offset),"method":"resources/read","params":{"uri":"\#(uri)"}}"#, id: 60 + offset)
            XCTAssertNotNil(response["result"], "\(uri) answers with the detail store unavailable")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/legacy"), "nothing created a legacy set")
        let report = root.appending(path: "caps-sizes.json")
        try JSONSerialization.data(withJSONObject: sizes, options: [.sortedKeys, .prettyPrinted]).write(to: report)
        if let temporary = ProcessInfo.processInfo.environment["TMPDIR"] {
            try? FileManager.default.copyItem(at: report, to: URL(fileURLWithPath: temporary).appending(path: "catalog-caps-sizes.json"))
        }
        print("CATALOG-CAPS \(String(decoding: try JSONSerialization.data(withJSONObject: sizes, options: [.sortedKeys]), as: UTF8.self))")
    }

    /// AC-02: an agent asked what can be cleaned in a folder quotes the same
    /// numbers and states as the review window.
    func testAnAgentQuotesTheReviewWindowsNumbersAndStates() async throws {
        let index = try ReviewIndex(url: steward)
        let service = try await reviewedProject(index: index)
        let backend = try backend(index: index, service: service, growth: nil)
        let socket = root.appending(path: "s.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let helper = try InteractiveHelper(socket: socket)
        defer { helper.close() }
        _ = try helper.request(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"agent","version":"1"}}}"#, id: 1)
        helper.send(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#)
        let agent = try call(helper, id: 2, "list_review_items", ["scope": scope, "path_detail": "full"])
        let evidence = try call(helper, id: 3, "get_review_item_evidence", ["item_id": try XCTUnwrap((agent["items"] as? [[String: Any]])?.first?["item_id"] as? String)])

        let window = ReviewWindowModel(service: service, index: index, scopes: [.folder(scope)], capacity: { .unavailable })
        await window.loadLatest()
        let display = try XCTUnwrap(window.display)
        let report = try XCTUnwrap(agent["report"] as? [String: Any])
        XCTAssertEqual(window.reviewState, .completeWithItems)
        XCTAssertEqual(report["state"] as? String, "complete-with-items")
        XCTAssertEqual((report["worth_reviewing_bytes"] as? NSNumber)?.int64Value, window.worthReviewingBytes, "the same total")
        XCTAssertEqual((report["item_count"] as? NSNumber)?.intValue, display.items.count, "the same count")
        let agentItems = try XCTUnwrap(agent["items"] as? [[String: Any]])
        XCTAssertEqual(agentItems.map { $0["path"] as? String }, display.items.map(\.path), "the same items in the same order")
        XCTAssertEqual(agentItems.map { ($0["allocated_bytes"] as? NSNumber)?.int64Value }, display.items.map(\.allocatedBytes))
        XCTAssertEqual(agentItems.map { $0["evidence"] as? String }, display.items.map(\.evidence.rawValue), "the same evidence states")
        let item = try XCTUnwrap(evidence["item"] as? [String: Any])
        XCTAssertEqual(item["reasons_to_keep"] as? [String], display.items.first?.reasonsToKeep)
        XCTAssertEqual(item["rebuild_command"] as? String, display.items.first?.rebuildCommand)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(fractional.date(from: report["completed_at"] as? String ?? "")?.timeIntervalSince1970 ?? 0,
                       display.completedAt.timeIntervalSince1970, accuracy: 1, "the same review time")
        // The transcript and the window's view of the same report, for the evidence archive.
        if let temporary = ProcessInfo.processInfo.environment["TMPDIR"] {
            let side: [String: Any] = [
                "agent": agent, "agent_item_evidence": evidence,
                "window": ["state": "\(window.reviewState)", "state_line": window.stateLine, "worth_reviewing_bytes": window.worthReviewingBytes,
                           "items": display.items.map { ["path": $0.path, "allocated_bytes": $0.allocatedBytes, "evidence": $0.evidence.rawValue,
                                                         "reasons_to_keep": $0.reasonsToKeep, "rebuild_command": $0.rebuildCommand] }],
            ]
            try JSONSerialization.data(withJSONObject: side, options: [.sortedKeys, .prettyPrinted])
                .write(to: URL(fileURLWithPath: temporary).appending(path: "agent-vs-window.json"))
        }
    }

    private func call(_ helper: InteractiveHelper, id: Int, _ tool: String, _ arguments: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = try helper.request(line, id: id)
        let result = try XCTUnwrap(response["result"] as? [String: Any], "\(tool): \(response)")
        XCTAssertEqual(result["isError"] as? Bool, false, "\(tool): \(result["structuredContent"] ?? "")")
        return try XCTUnwrap(result["structuredContent"] as? [String: Any], tool)
    }
}

/// The real helper, driven one request at a time so no answer is cut by the
/// end-of-input grace or the four-request admission limit.
final class InteractiveHelper {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()

    init(socket: String) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [repository.appendingPathComponent(".build/debug/disk-witness-mcp"),
                          repository.appendingPathComponent(".build/arm64-apple-macosx/debug/disk-witness-mcp")]
        process.executableURL = try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        process.environment = ProcessInfo.processInfo.environment.merging(["DISK_STEWARD_SOCKET_PATH": socket]) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func send(_ line: String) { input.fileHandleForWriting.write(Data((line + "\n").utf8)) }

    func request(_ line: String, id: Int) throws -> [String: Any] {
        send(line)
        while true {
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], (object["id"] as? NSNumber)?.intValue == id { return object }
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw CocoaError(.fileReadUnknown) }
            buffer.append(chunk)
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}
