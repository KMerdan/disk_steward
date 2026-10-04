import CoreServices
@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-652: directory changes from the FSEvents journal, collapsed, capped,
/// windowed, replayed across restarts, with gaps stated.
final class ChangeJournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp/ds-journal-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func journal() throws -> ChangeJournal { try ChangeJournal(url: directory.appending(path: "steward.sqlite")) }

    private func batch(_ paths: [String], flags: UInt32 = UInt32(kFSEventStreamEventFlagItemModified), from id: UInt64 = 100) -> DirectoryChangeBatch {
        DirectoryChangeBatch.interpret(paths.enumerated().map { ($0.element, flags, id + UInt64($0.offset)) })
    }

    func testChangesCollapseToObjectsOrTwoLevelsBelowTheRoot() {
        let roots = ["/Users/u/localGit", "/Users/u/Downloads"]
        XCTAssertEqual(ChangeJournal.attributionPath(for: "/Users/u/localGit/pyfta/web/.next/cache/x", roots: roots), "/Users/u/localGit/pyfta/web")
        XCTAssertEqual(ChangeJournal.attributionPath(for: "/Users/u/localGit/app/node_modules/dep/lib", roots: roots), "/Users/u/localGit/app/node_modules")
        XCTAssertEqual(ChangeJournal.attributionPath(for: "/Users/u/localGit/bipbox/Sources/Foo", roots: roots), "/Users/u/localGit/bipbox/Sources")
        XCTAssertEqual(ChangeJournal.attributionPath(for: "/Users/u/localGit", roots: roots), "/Users/u/localGit")
        XCTAssertEqual(ChangeJournal.attributionPath(for: "/Users/u/Downloads/a.zip", roots: roots), "/Users/u/Downloads/a.zip")
        XCTAssertNil(ChangeJournal.attributionPath(for: "/Users/u/Library/Caches/x", roots: roots), "outside every root")
        // Paths are compared as reported, without file-system lookups that
        // would rewrite /private/tmp as /tmp.
        XCTAssertEqual(ChangeJournal.attributionPath(for: "/private/tmp/w/a/b/c/", roots: ["/private/tmp/w"]), "/private/tmp/w/a/b")
        XCTAssertEqual(ChangeJournal.attributionPath(for: "/r/a/../b/./c/d", roots: ["/r/"]), "/r/b/c")
    }

    func testDirectoriesAreCappedPerIntervalWithOverflowToAPresentAncestor() async throws {
        let journal = try journal()
        let root = "/r"
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let distinct = (0..<ChangeJournal.directoriesPerInterval).map { "\(root)/a\($0)/b" }
        try await journal.record(batch(distinct), roots: [root], at: at)
        try await journal.record(batch(["\(root)/a5/c", "\(root)/new/dir"]), roots: [root], at: at)
        let window = try await journal.changes(from: at, through: at.addingTimeInterval(60), limit: 5_000)
        XCTAssertLessThanOrEqual(window.changes.total, ChangeJournal.directoriesPerInterval + 1, "overflow does not add directories")
        XCTAssertTrue(window.changes.items.contains { $0.path == root }, "overflow collapsed to the root")
        XCTAssertFalse(window.changes.items.contains { $0.path == "\(root)/a5/c" || $0.path == "\(root)/new/dir" })
        // A later interval starts a fresh set.
        try await journal.record(batch(["\(root)/a5/c"]), roots: [root], at: at.addingTimeInterval(ChangeJournal.intervalSeconds))
        let later = try await journal.changes(from: at.addingTimeInterval(ChangeJournal.intervalSeconds), through: at.addingTimeInterval(2 * ChangeJournal.intervalSeconds), limit: 10)
        XCTAssertEqual(later.changes.items.map(\.path), ["\(root)/a5/c"])
    }

    func testWindowsAggregateAcrossIntervalsReportGapsAndTruncate() async throws {
        let journal = try journal()
        let root = "/r"
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for step in 0..<3 {
            try await journal.record(batch(["\(root)/p/x", "\(root)/q/y"]), roots: [root], at: start.addingTimeInterval(Double(step) * ChangeJournal.intervalSeconds))
        }
        try await journal.record(batch(["\(root)/p/x"]), roots: [root], at: start)
        try await journal.record(batch(["\(root)/s/z"], flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)), roots: [root], at: start)
        let window = try await journal.changes(from: start, through: start.addingTimeInterval(3 * ChangeJournal.intervalSeconds), limit: 1)
        XCTAssertEqual(window.changes.total, 3)
        XCTAssertTrue(window.changes.truncated)
        XCTAssertEqual(window.changes.items.first?.path, "\(root)/p/x")
        XCTAssertEqual(window.changes.items.first?.changes, 4)
        XCTAssertEqual(window.gaps.map(\.reason), ["must-scan-subdirectories"])
        let coverage = try await journal.coverageStart()
        XCTAssertEqual(coverage, ChangeJournal.intervalStart(start))
    }

    func testEntriesOlderThanSevenDaysArePruned() async throws {
        let journal = try journal()
        let old = Date(timeIntervalSince1970: 1_790_000_000)
        try await journal.record(batch(["/r/old/a"]), roots: ["/r"], at: old)
        try await journal.record(batch(["/r/new/b"]), roots: ["/r"], at: old.addingTimeInterval(ChangeJournal.retention + 600))
        let all = try await journal.changes(from: old, through: old.addingTimeInterval(ChangeJournal.retention + 3_600), limit: 10)
        XCTAssertEqual(all.changes.items.map(\.path), ["/r/new/b"])
    }

    func testCursorIsPerJournalAndNeverMovesBackwards() async throws {
        let journal = try journal()
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        try await journal.checkpoint(journalUUID: "J-1", eventID: 500, at: at)
        try await journal.checkpoint(journalUUID: "J-1", eventID: 400, at: at.addingTimeInterval(1))
        let kept = try await journal.cursor(journalUUID: "J-1")
        XCTAssertEqual(kept, 500)
        try await journal.checkpoint(journalUUID: "J-1", eventID: 900, at: at.addingTimeInterval(2))
        let advanced = try await journal.cursor(journalUUID: "J-1")
        XCTAssertEqual(advanced, 900)
        let other = try await journal.cursor(journalUUID: "J-2")
        XCTAssertNil(other, "a different journal identity has no cursor: its history is a gap")
    }

    /// Real FSEvents: changes made while the stream is stopped are replayed
    /// from the stored event ID on restart, and the replay is marked done.
    func testRealStreamReplaysChangesMadeWhileStopped() async throws {
        let requested = "/tmp/\(directory.lastPathComponent)/watched"
        try FileManager.default.createDirectory(atPath: requested, withIntermediateDirectories: true)
        let root = DirectoryChangeStream.canonicalPath(requested)
        XCTAssertEqual(root, directory.path + "/watched", "FSEvents reports /tmp as /private/tmp")
        let journal = try journal()
        let stream = DirectoryChangeStream()
        let seen = Seen()
        let record: DirectoryChangeStream.Handler = { batch in
            seen.add(batch)
            Task { try? await journal.record(batch, roots: [root], at: Date()) }
        }
        try stream.start(paths: [root], since: nil, latency: 0.1, handler: record)
        try FileManager.default.createDirectory(atPath: root + "/live/one", withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: root + "/live/one/file.txt"))
        try await eventually { try await journal.changes(from: .distantPast, through: .distantFuture, limit: 100).changes.items.contains { $0.path == root + "/live/one" } }
        let cursor = try XCTUnwrap(stream.latestEventID())
        stream.stop()

        try FileManager.default.createDirectory(atPath: root + "/offline/two", withIntermediateDirectories: true)
        try Data([2]).write(to: URL(fileURLWithPath: root + "/offline/two/file.txt"))
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let replay = DirectoryChangeStream()
        try replay.start(paths: [root], since: cursor, latency: 0.1, handler: record)
        defer { replay.stop() }
        try await eventually(seconds: 20) {
            try await journal.changes(from: .distantPast, through: .distantFuture, limit: 100).changes.items.contains { $0.path == root + "/offline/two" }
        }
        try await eventually(seconds: 20) { seen.historyDone }
        XCTAssertFalse(seen.paths.isEmpty)
        XCTAssertFalse(seen.paths.contains { $0.hasSuffix("file.txt") }, "directory-level stream: no per-file events")
    }

    /// Real FSEvents: a burst of more distinct directories than one interval
    /// may hold keeps the dirty set at its cap and collapses the rest.
    func testRealStreamBurstStaysWithinTheIntervalCap() async throws {
        let root = DirectoryChangeStream.canonicalPath(directory.path) + "/burst"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let journal = try journal()
        let at = Date(timeIntervalSince1970: 1_790_000_000)  // every batch lands in one interval
        let stream = DirectoryChangeStream()
        try stream.start(paths: [root], since: nil, latency: 0.1) { batch in
            Task { try? await journal.record(batch, roots: [root], at: at) }
        }
        defer { stream.stop() }
        let extra = 50
        for index in 0..<(ChangeJournal.directoriesPerInterval + extra) {
            try FileManager.default.createDirectory(atPath: root + "/d\(index)", withIntermediateDirectories: true)
            try Data([1]).write(to: URL(fileURLWithPath: root + "/d\(index)/f"))
        }
        try await eventually(seconds: 60) {
            let window = try await journal.changes(from: at, through: at, limit: 10)
            return window.changes.total >= ChangeJournal.directoriesPerInterval
                && (window.changes.items.first { $0.path == root }?.changes ?? 0) >= Int64(extra)
        }
        let window = try await journal.changes(from: at, through: at, limit: 10)
        XCTAssertLessThanOrEqual(window.changes.total, ChangeJournal.directoriesPerInterval + 1)
        XCTAssertEqual(window.changes.items.first?.path, root, "overflow is attributed to the root, the most-changed entry")
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [DirectoryChangeBatch] = []
        func add(_ batch: DirectoryChangeBatch) { lock.withLock { batches.append(batch) } }
        var historyDone: Bool { lock.withLock { batches.contains(where: \.historyDone) } }
        var paths: [String] { lock.withLock { batches.flatMap { $0.events.map(\.path) } } }
    }

    private func eventually(seconds: TimeInterval = 10, _ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("condition not reached within \(seconds) s")
    }
}
