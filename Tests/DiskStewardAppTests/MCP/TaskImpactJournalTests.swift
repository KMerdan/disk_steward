import CoreServices
@testable import DiskStewardApp
@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-672: get_task_impact and list_active_agent_sessions answer from
/// sessions and the change journal's dirty sets, at directory and object
/// granularity, with journal gaps stated, no per-file rows and no absolute
/// paths. Sessions survive a relaunch in the steward file.
final class TaskImpactJournalTests: XCTestCase {
    private var support: URL!
    /// The watched root: code/web/{api,site} and code/engine.
    private var root: String!

    override func setUpWithError() throws {
        support = URL(fileURLWithPath: "/private/tmp/ds-impact-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        root = support.path + "/code"
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: support) }

    private var steward: URL { support.appending(path: "steward.sqlite") }

    private func backend() throws -> AppEvidenceQueryBackend {
        try AppEvidenceQueryBackend(databaseURL: support.appending(path: "evidence.sqlite"), capacityRingURL: support.appending(path: "capacity.sqlite"),
                                    changeJournalURL: steward, fileDetail: .retired(supportDirectory: support),
                                    sessionStore: try SessionStore(url: steward), reviewIndex: try ReviewIndex(url: steward),
                                    watchedRoots: { [root] in [root!] })
    }

    private func serve(_ backend: AppEvidenceQueryBackend) throws -> (UnixSocketEvidenceServer, UnixSocketDiskStewardIPCClient) {
        let socket = support.appending(path: "s-\(UUID().uuidString.prefix(4)).sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        return (server, UnixSocketDiskStewardIPCClient(socketPath: socket))
    }

    /// One process may hold one active session, so a second concurrent
    /// session registers under this test's parent process.
    private func register(_ client: UnixSocketDiskStewardIPCClient, _ sessionID: String, roots: [String], parent: Bool = false) throws -> String {
        let result = try client.send(method: "sessions/register", payload: .object([
            "client": .string("codex"), "session_id": .string(sessionID),
            "workspace_roots": .array(roots.map(JSONValue.string)), "lease_seconds": .integer(600),
            "process_pid": .integer(Int64(parent ? getppid() : getpid())),
        ]), isCancelled: { false })
        return try XCTUnwrap(result.objectValue?["registration_id"]?.stringValue)
    }

    private func journal(_ directories: [String], gap: Bool = false) async throws {
        let journal = try ChangeJournal(url: steward)
        let modified = UInt32(kFSEventStreamEventFlagItemModified)
        try await journal.record(DirectoryChangeBatch.interpret(directories.enumerated().map { (root + $0.element, modified, UInt64(100 + $0.offset)) }),
                                 roots: [root], at: Date())
        if gap { try await journal.recordGap(reason: "MustScanSubDirs", path: root, at: Date()) }
        await journal.close()
    }

    private func impact(_ client: UnixSocketDiskStewardIPCClient, _ sessionID: String, limit: Int? = nil) throws -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let limit { arguments["limit"] = .integer(Int64(limit)) }
        return try XCTUnwrap(try client.call(tool: "get_task_impact", arguments: arguments, isCancelled: { false }).objectValue)
    }

    private func items(_ object: [String: JSONValue]) -> [[String: JSONValue]] {
        guard case let .array(values)? = object["directories"]?.objectValue?["items"] else { return [] }
        return values.compactMap(\.objectValue)
    }

    /// Every string in the answer, so no absolute path can hide in it.
    private func strings(_ value: JSONValue) -> [String] {
        switch value {
        case let .string(text): return [text]
        case let .array(values): return values.flatMap(strings)
        case let .object(fields): return fields.values.flatMap(strings)
        default: return []
        }
    }

    func testSharedOwnAndOverflowDirectoriesWithObjectsAndGaps() async throws {
        let backend = try backend()
        let (server, client) = try serve(backend)
        defer { server.stop() }
        _ = try register(client, "task-api", roots: [root + "/web/api"])
        _ = try register(client, "task-site", roots: [root + "/web/site"], parent: true)
        let index = try ReviewIndex(url: steward)
        try await index.updateMeasurements([ReviewObject(path: root + "/web/api/node_modules", kind: .artifact, rule: .content, reason: "packages",
                                                         projectPath: root + "/web/api", recreateClass: .redownload, allocatedBytes: 4_096, fileCount: 2,
                                                         lastActivity: Date().timeIntervalSince1970)], gone: [], at: Date())
        await index.close()
        // api/src and api/node_modules collapse to the api folder; a change in
        // web itself is above both workspaces; one row lands on the root.
        try await journal(["/web/api/src/z", "/web/api/node_modules/q", "/web", "/engine/target/debug", ""], gap: true)

        let answer = try impact(client, "task-api")
        XCTAssertEqual(answer["schema"], .string("task-impact-v2"))
        let rows = items(answer)
        XCTAssertEqual(rows.map { $0["relative_path"] }, [.string("."), .string("..")], "own folder first (most changes), then the coarser one")
        XCTAssertEqual(rows.map { $0["relation"] }, [.string("at"), .string("contains-workspace")])
        XCTAssertEqual(rows.map { $0["shared"] }, [.bool(false), .bool(true)], "the web folder also covers the site session")
        XCTAssertEqual(rows.last?["precision"], .string("coarser-than-workspace"))
        XCTAssertEqual(rows.first?["changes"], .integer(2))
        guard case let .array(objects)? = rows.first?["objects"] else { return XCTFail("no objects") }
        XCTAssertEqual(objects.first?.objectValue?["name"], .string("node_modules"))
        guard case let .array(overflow)? = answer["overflow"] else { return XCTFail("no overflow") }
        XCTAssertEqual(overflow.count, 1, "the row at the watched root is reported apart, not as the session's")
        guard case let .array(gaps)? = answer["journal_gaps"] else { return XCTFail("no gaps") }
        XCTAssertEqual(gaps.first?.objectValue?["reason"], .string("MustScanSubDirs"))
        XCTAssertEqual(answer["coverage"], .string("partial"), "a gap in the window")
        XCTAssertEqual(answer["confidence"], .string("inferred"))
        XCTAssertFalse(rows.contains { $0["relative_path"] == .string("engine/target") }, "another project is not this session's")
        let paths = strings(.object(answer)).filter { $0.hasPrefix("/") }
        XCTAssertEqual(paths, [], "no absolute paths")
        XCTAssertFalse(strings(.object(answer)).contains { $0.contains(support.path) })

        let site = items(try impact(client, "task-site"))
        XCTAssertEqual(site.map { $0["relative_path"] }, [.string("..")], "the site sees only the shared folder")
    }

    /// A session ended before a relaunch is still answered after it, from the
    /// steward file; once the journal forgets, its kept impact answers.
    func testASessionOutlivesARelaunchAndTheJournal() async throws {
        var registration = ""
        do {
            let backend = try backend()
            let (server, client) = try serve(backend)
            // The journal's first interval starts before the session, so the
            // whole window is covered and the impact is kept at the end.
            try await journal(["/web/api/src/z", "/web/api/build/x"])
            registration = try register(client, "task-api", roots: [root + "/web/api"])
            _ = try client.send(method: "sessions/end", payload: .object(["registration_id": .string(registration)]), isCancelled: { false })
            server.stop()
        }
        let relaunched = try backend()
        let (server, client) = try serve(relaunched)
        defer { server.stop() }
        let answer = try impact(client, "task-api")
        guard case let .array(sessions)? = answer["sessions"] else { return XCTFail("no sessions") }
        XCTAssertEqual(sessions.first?.objectValue?["source"], .string("kept"), "read back from the steward file")
        XCTAssertEqual(sessions.first?.objectValue?["state"], .string("closed"))
        XCTAssertEqual(items(answer).map { $0["relative_path"] }, [.string(".")])

        // The journal forgets (retention); the kept impact still answers.
        let connection = try SQLiteConnection(url: steward)
        try connection.execute("DELETE FROM journal_dirty")
        connection.close()
        let kept = try impact(client, "task-api")
        XCTAssertEqual(kept["source"], .string("kept"))
        XCTAssertEqual(items(kept).map { $0["relative_path"] }, [.string(".")])
        XCTAssertEqual(items(kept).first?["first_interval"], .null, "a kept directory has counts, not intervals")
        XCTAssertNotEqual(kept["coverage"], .string("complete"))

        do {
            _ = try client.call(tool: "get_task_impact", arguments: ["session_id": .string("never-registered")], isCancelled: { false })
            XCTFail("an unknown session answered")
        } catch DiskStewardIPCError.remote(let code, _, let retryable) {
            XCTAssertEqual(code, "session_unavailable")
            XCTAssertFalse(retryable)
        }
    }

    /// 250 changed folders: 200 are returned under the response ceiling, with
    /// the total and truncation stated.
    func testTwoHundredDirectoriesFitTheCeiling() async throws {
        let backend = try backend()
        let (server, client) = try serve(backend)
        defer { server.stop() }
        _ = try register(client, "task-wide", roots: [root])
        let long = String(repeating: "n", count: 200)
        try await journal((0..<250).map { "/\(long)-\($0)/sub/leaf" })
        let answer = try impact(client, "task-wide", limit: 500)
        let directories = try XCTUnwrap(answer["directories"]?.objectValue)
        XCTAssertEqual(directories["returned_count"], .integer(200))
        XCTAssertEqual(directories["total"], .integer(250))
        XCTAssertEqual(directories["truncated"], .bool(true))
        XCTAssertLessThan(try JSONEncoder.diskSteward.encode(JSONValue.object(answer)).count, 1_024 * 1_024)
    }

    func testActiveSessionsListTheirChangedDirectories() async throws {
        let backend = try backend()
        let (server, client) = try serve(backend)
        defer { server.stop() }
        _ = try register(client, "task-api", roots: [root + "/web/api"])
        try await journal(["/web/api/src/z", "/web/api/node_modules/q", "/web"])
        let listed = try XCTUnwrap(try client.call(tool: "list_active_agent_sessions", arguments: [:], isCancelled: { false }).objectValue)
        XCTAssertEqual(listed["schema"], .string("active-agent-sessions-v1"))
        guard case let .array(sessions)? = listed["sessions"], let summary = sessions.first?.objectValue?["changed_directories"]?.objectValue else {
            return XCTFail("no summary")
        }
        XCTAssertEqual(summary["total"], .integer(2))
        guard case let .array(top)? = summary["items"] else { return XCTFail("no items") }
        XCTAssertEqual(top.compactMap { $0.objectValue?["relative_path"] }, [.string("."), .string("..")])
        XCTAssertEqual(strings(.object(listed)).filter { $0.hasPrefix("/") }, [], "no absolute paths")
    }
}
