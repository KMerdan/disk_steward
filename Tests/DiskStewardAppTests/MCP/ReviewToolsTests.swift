@testable import DiskStewardApp
@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-671: the review tools on the retired build. measure_path stays inside
/// the configured scopes and its budget, stores nothing and joins a running
/// review; get_health never opens the retired detail store.
final class ReviewToolsTests: XCTestCase {
    private var root: URL!
    private var scope: String!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/ds-tools-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scope = DirectoryChangeStream.canonicalPath(root.path + "/code")
        for (path, bytes) in [("code/web/package.json", 100), ("code/web/pnpm-lock.yaml", 100), ("code/web/node_modules/.modules.yaml", 100),
                              ("code/web/node_modules/a/index.js", 200_000), ("code/engine/Cargo.toml", 100), ("code/engine/target/debug/app", 400_000),
                              ("outside/secret/file", 100)] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 2, count: bytes).write(to: url)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var steward: URL { root.appending(path: "steward.sqlite") }
    private var stateURL: URL { root.appending(path: "review-state.json") }

    private func service(index: ReviewIndex, slowReader: Bool = false, measureEntries: Int = 500_000) -> ReviewService {
        let decider = ClassifierObjectDecider(oracle: SilentRepositoryOracle())
        return ReviewService(index: index, stateURL: stateURL, makeWalker: { previous, cancelled in
            ReviewWalker(reader: slowReader ? SlowReader() : BulkDirectoryReader(), decider: decider, previousCompleteEntries: previous, isCancelled: cancelled)
        }, makeMeasureWalker: { budget, cancelled in
            ReviewWalker(decider: decider, budget: ReviewBudget(wallSeconds: budget.wallSeconds, maximumEntries: min(budget.maximumEntries, measureEntries)), isCancelled: cancelled)
        })
    }

    private func serve(index: ReviewIndex, service: ReviewService) throws -> (UnixSocketEvidenceServer, UnixSocketDiskStewardIPCClient) {
        let backend = try AppEvidenceQueryBackend(databaseURL: root.appending(path: "evidence.sqlite"), capacityRingURL: root.appending(path: "capacity.sqlite"),
                                                  changeJournalURL: steward, fileDetail: .retired(supportDirectory: root),
                                                  sessionStore: try SessionStore(url: steward), reviewIndex: index,
                                                  reviewService: service, reviewRoots: { [scope] in [scope!] })
        let socket = root.appending(path: "s-\(UUID().uuidString.prefix(4)).sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend, timeoutSeconds: AppEvidenceQueryBackend.socketTimeoutSeconds)
        try server.start()
        return (server, UnixSocketDiskStewardIPCClient(socketPath: socket, timeoutSeconds: UnixSocketDiskStewardIPCClient.measurementTimeoutSeconds))
    }

    private func du(_ path: String) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (Int64(String(decoding: data, as: UTF8.self).split(separator: "\t").first ?? "") ?? -1) * 1_024
    }

    func testMeasurePathMeasuresInsideTheScopeAndStoresNothing() async throws {
        let index = try ReviewIndex(url: steward)
        let (server, client) = try serve(index: index, service: service(index: index))
        defer { server.stop() }
        let before = try await index.count("object_index")
        let answer = try XCTUnwrap(try client.call(tool: "measure_path", arguments: ["path": .string(scope + "/web"), "path_detail": .string("full")], isCancelled: { false }).objectValue)
        XCTAssertEqual(answer["schema"], .string("measure-path-v1"))
        XCTAssertEqual(answer["status"], .string("complete"))
        XCTAssertEqual(answer["allocated_bytes"], .integer(try du(scope + "/web")), "the folder's size, as du counts it")
        guard case let .array(objects)? = answer["objects"] else { return XCTFail("no objects") }
        XCTAssertEqual(objects.first?.objectValue?["name"], .string("node_modules"))
        XCTAssertEqual(answer["budget"]?.objectValue?["wall_seconds"], .integer(15), "invariant 7: 15 s")
        XCTAssertEqual(answer["budget"]?.objectValue?["maximum_entries"], .integer(500_000), "and 500,000 entries")
        let after = try await index.count("object_index")
        XCTAssertEqual(after, before, "a measurement stores no object")
        let reports = try await index.latestReports()
        XCTAssertTrue(reports.isEmpty, "and no report")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path), "and writes no cooldown")

        for outside in [root.path + "/outside/secret", "/"] {
            do {
                _ = try client.call(tool: "measure_path", arguments: ["path": .string(outside)], isCancelled: { false })
                XCTFail("measured outside the configured scopes: \(outside)")
            } catch DiskStewardIPCError.remote(let code, _, let retryable) {
                XCTAssertEqual(code, "outside_scope")
                XCTAssertFalse(retryable)
            }
        }
    }

    func testABudgetStopIsAPartialLowerBound() async throws {
        let index = try ReviewIndex(url: steward)
        let (server, client) = try serve(index: index, service: service(index: index, measureEntries: 2))
        defer { server.stop() }
        let answer = try XCTUnwrap(try client.call(tool: "measure_path", arguments: ["path": .string(scope)], isCancelled: { false }).objectValue)
        XCTAssertEqual(answer["status"], .string("partial"))
        XCTAssertEqual(answer["stop_reason"], .string("entries"))
        guard case let .array(limitations)? = answer["limitations"] else { return XCTFail("no limitations") }
        XCTAssertTrue(limitations.contains { $0.stringValue?.contains("lower bound") == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path), "a stopped measurement writes no cooldown either")
    }

    /// A review in flight is joined, never run beside: the measurement waits
    /// for it within its budget, then measures.
    func testMeasurePathJoinsARunningReview() async throws {
        let index = try ReviewIndex(url: steward)
        let service = service(index: index, slowReader: true)
        let (server, client) = try serve(index: index, service: service)
        defer { server.stop() }
        let target: String = scope
        let review = Task { try await service.review(scope: target) }
        var waited = 0
        while !(await service.isRunning), waited < 100 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        let running = await service.isRunning
        XCTAssertTrue(running, "the review is in flight")
        let answer = try await Task.detached { [client] in
            try client.call(tool: "measure_path", arguments: ["path": .string(target + "/engine")], isCancelled: { false })
        }.value.objectValue
        _ = try await review.value
        let joined = try XCTUnwrap(answer?["joined_review"]?.objectValue, "the measurement says it joined the review")
        XCTAssertEqual(joined["kind"], .string("review"))
        XCTAssertEqual(joined["finished"], .bool(true))
        XCTAssertEqual(answer?["status"], .string("complete"), "then it measured")
    }

    func testHealthAndTheReviewToolsNeverOpenTheRetiredStore() async throws {
        let index = try ReviewIndex(url: steward)
        let service = service(index: index)
        _ = try await service.review(scope: scope)
        let (server, client) = try serve(index: index, service: service)
        defer { server.stop() }
        let health = try XCTUnwrap(try client.call(tool: "get_health", arguments: [:], isCancelled: { false }).objectValue)
        XCTAssertEqual(health["schema"], .string("health-v1"))
        XCTAssertEqual(health["detail_store"], .string("retired"))
        guard case let .array(tables)? = health["stores"]?.objectValue?["tables"] else { return XCTFail("no tables") }
        XCTAssertEqual(tables.count, BoundedStoreContract.tables[.steward]?.count, "every table with its cap")
        guard case let .array(reviews)? = health["reviews"] else { return XCTFail("no reviews") }
        XCTAssertEqual(reviews.first?.objectValue?["state"], .string("complete-with-items"))
        let status = try XCTUnwrap(try client.readResource(uri: "disk-steward://status", isCancelled: { false }).objectValue)
        XCTAssertEqual(status["schema"], .string("health-v1"), "the status resource is the health answer on the retired build")

        let largest = try XCTUnwrap(try client.call(tool: "list_largest_objects", arguments: ["scope": .string(scope)], isCancelled: { false }).objectValue)
        guard case let .array(objects)? = largest["items"] else { return XCTFail("no objects") }
        XCTAssertEqual(objects.compactMap { $0.objectValue?["name"]?.stringValue }, ["target", "node_modules"], "largest first")
        do {
            _ = try client.call(tool: "get_review_item_evidence", arguments: ["item_id": .string("gone:1")], isCancelled: { false })
            XCTFail("an unknown item answered")
        } catch DiskStewardIPCError.remote(let code, _, _) {
            XCTAssertEqual(code, "item_unavailable")
        }
        // A reviewed folder that is gone reads Unknown, as the window shows it.
        try FileManager.default.removeItem(atPath: scope + "/engine/target")
        let listed = try XCTUnwrap(try client.call(tool: "list_review_items", arguments: ["scope": .string(scope)], isCancelled: { false }).objectValue)
        guard case let .array(items)? = listed["items"] else { return XCTFail("no items") }
        let states = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let name = item.objectValue?["name"]?.stringValue, let state = item.objectValue?["evidence"]?.stringValue else { return nil }
            return (name, state)
        })
        XCTAssertEqual(states, ["target": "Unknown", "node_modules": "Verified now"])
        let empty = try XCTUnwrap(try client.call(tool: "list_review_items", arguments: ["scope": .string("caches")], isCancelled: { false }).objectValue)
        XCTAssertEqual(empty["report"], .null, "no cache review is stored, and the answer says so")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/evidence.sqlite"), "the retired store is never created")
    }
}

/// Lists like the real reader, slowly, so a review stays in flight.
private struct SlowReader: DirectoryReader, @unchecked Sendable {
    private let base = BulkDirectoryReader()
    func identity(of path: String) -> FileIdentity? { base.identity(of: path) }
    func list(_ path: String) throws -> DirectoryListing {
        Thread.sleep(forTimeInterval: 0.15)
        return try base.list(path)
    }
}
