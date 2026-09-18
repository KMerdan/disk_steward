import CSQLite
import Darwin
import Foundation
import XCTest
@testable import DiskStewardCore

final class BoundedTraversalPrototypeTests: XCTestCase {
    func testFailedEnumerationBatchCannotContinueWithAnAdvancedNativeCursor() throws {
        for mode in [BoundedTraversalPrototype.Mode.stream, .spool] {
            let fixture = try PrototypeFixture()
            defer { fixture.remove() }
            try fixture.files(5)
            var prototype = try BoundedTraversalPrototype(database: fixture.database, mode: mode)
            try prototype.begin(root: fixture.root)
            let table = mode == .stream ? "entries" : "names"
            try prototype.connection.execute("CREATE TRIGGER fail_batch BEFORE INSERT ON \(table) BEGIN SELECT RAISE(ABORT,'injected batch failure'); END")
            XCTAssertThrowsError(try prototype.step(limit: 2))
            try prototype.connection.execute("DROP TRIGGER fail_batch")
            var rejectedRetry = false
            do { _ = try prototype.step(limit: 2) } catch { rejectedRetry = true }
            if rejectedRetry {
                XCTAssertThrowsError(try prototype.publish())
            } else {
                // On the defective implementation this publishes only the names
                // after the failed read, proving loss rather than just a missing error.
                try complete(prototype, limit: 2)
                try prototype.publish()
                try assertVisibleMetadata(prototype, files: (0..<5).map { fixture.root.appending(path: "f\($0)") })
                XCTFail("A failed native read/persistence pass must require reopening")
            }
            prototype.close()
            prototype = try BoundedTraversalPrototype(database: fixture.database, mode: mode)
            defer { prototype.close() }
            if prototype.generation != 0 {
                try complete(prototype, limit: 2)
                try prototype.publish()
            }
            try assertVisibleMetadata(prototype, files: (0..<5).map { fixture.root.appending(path: "f\($0)") })
        }
    }

    func testFailedBeginCanRetryWithoutLosingOldVisibleEvidence() throws {
        for mode in [BoundedTraversalPrototype.Mode.stream, .spool] {
            let fixture = try PrototypeFixture()
            defer { fixture.remove() }
            try fixture.files(3)
            let prototype = try BoundedTraversalPrototype(database: fixture.database, mode: mode)
            defer { prototype.close() }
            try prototype.begin(root: fixture.root)
            try complete(prototype, limit: 2)
            try prototype.publish()
            try Data([42]).write(to: fixture.root.appending(path: "new"))
            try prototype.connection.execute("CREATE TRIGGER fail_begin BEFORE INSERT ON directories BEGIN SELECT RAISE(ABORT,'injected begin failure'); END")
            XCTAssertThrowsError(try prototype.begin(root: fixture.root))
            XCTAssertEqual(prototype.generation, 0)
            XCTAssertEqual(try prototype.visibleCount(), 3)
            try prototype.connection.execute("DROP TRIGGER fail_begin")
            try prototype.begin(root: fixture.root)
            try complete(prototype, limit: 2)
            XCTAssertEqual(try prototype.visibleCount(), 3)
            try prototype.publish()
            try assertVisibleMetadata(prototype, files: (0..<3).map { fixture.root.appending(path: "f\($0)") } + [fixture.root.appending(path: "new")])
            XCTAssertEqual(try prototype.connection.scalarInt("SELECT COUNT(*) FROM generations WHERE status='published'"), 2)
        }
    }

    func testBothModesPublishCompleteMetadataWithoutFollowingSymlinks() throws {
        for mode in [BoundedTraversalPrototype.Mode.stream, .spool] {
            let fixture = try PrototypeFixture()
            defer { fixture.remove() }
            try fixture.files(5)
            let nested = fixture.root.appending(path: "nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try Data([4]).write(to: nested.appending(path: "one"))
            try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "link"), withDestinationURL: fixture.directory)
            let prototype = try BoundedTraversalPrototype(database: fixture.database, mode: mode)
            defer { prototype.close() }
            try prototype.begin(root: fixture.root)
            try complete(prototype, limit: 2)
            XCTAssertEqual(try prototype.visibleCount(), 0)
            try prototype.publish()
            XCTAssertEqual(try prototype.visibleCount(), 6)
            XCTAssertLessThanOrEqual(prototype.counters.peakNames, 2)
            XCTAssertEqual(prototype.counters.enumerated, 8) // five files + directory + link + nested file
            XCTAssertEqual(try prototype.connection.scalarText("PRAGMA quick_check"), "ok")
        }
    }

    func testStreamLossInvalidatesOnlyUnfinishedPassRowsWithoutTrustingCookie() throws {
        let fixture = try PrototypeFixture()
        defer { fixture.remove() }
        try fixture.files(5)
        var prototype = try BoundedTraversalPrototype(database: fixture.database, mode: .stream)
        try prototype.begin(root: fixture.root)
        XCTAssertFalse(try prototype.step(limit: 2))
        XCTAssertEqual(try prototype.connection.scalarInt("SELECT COUNT(*) FROM entries"), 2)
        prototype.close()
        prototype = try BoundedTraversalPrototype(database: fixture.database, mode: .stream)
        defer { prototype.close() }
        XCTAssertEqual(prototype.counters.restartedDirectories, 1)
        try complete(prototype, limit: 2)
        try prototype.publish()
        XCTAssertEqual(try prototype.visibleCount(), 5)
        XCTAssertEqual(prototype.counters.enumerated, 5)
        XCTAssertEqual(try prototype.connection.scalarInt("SELECT COUNT(*) FROM entries"), 7,
                       "Invalidated physical rows remain charged to storage until bounded GC")
    }

    func testCompletedNameSpoolResumesMetadataWithoutReenumeration() throws {
        let fixture = try PrototypeFixture()
        defer { fixture.remove() }
        try fixture.files(10)
        var prototype = try BoundedTraversalPrototype(database: fixture.database, mode: .spool)
        try prototype.begin(root: fixture.root)
        for _ in 0..<20 {
            _ = try prototype.step(limit: 2)
            if try prototype.connection.scalarInt("SELECT phase FROM directories WHERE parent IS NULL") == 2 { break }
        }
        XCTAssertEqual(try prototype.connection.scalarInt("SELECT COUNT(*) FROM names"), 10)
        let offset = try prototype.connection.scalarInt("SELECT offset FROM directories WHERE parent IS NULL")
        XCTAssertGreaterThan(offset, 0)
        prototype.close()
        prototype = try BoundedTraversalPrototype(database: fixture.database, mode: .spool)
        defer { prototype.close() }
        try complete(prototype, limit: 2)
        try prototype.publish()
        XCTAssertEqual(try prototype.visibleCount(), 10)
        XCTAssertEqual(prototype.counters.enumerated, 0)
        XCTAssertEqual(prototype.counters.processed, 10 - Int(offset))
    }

    func testChangedDirectoryCannotPublishAndOldVisibleGenerationSurvives() throws {
        for mode in [BoundedTraversalPrototype.Mode.stream, .spool] {
            let fixture = try PrototypeFixture()
            defer { fixture.remove() }
            try fixture.files(5)
            let prototype = try BoundedTraversalPrototype(database: fixture.database, mode: mode)
            defer { prototype.close() }
            try prototype.begin(root: fixture.root)
            try complete(prototype, limit: 2)
            try prototype.publish()
            try prototype.begin(root: fixture.root)
            XCTAssertFalse(try prototype.step(limit: 2))
            try FileManager.default.removeItem(at: fixture.root.appending(path: "f0"))
            XCTAssertThrowsError(try prototype.step(limit: 2))
            XCTAssertThrowsError(try prototype.publish())
            XCTAssertEqual(try prototype.visibleCount(), 5, "Old evidence remains; no false fresh absence is published")
        }
    }

    func testPointerSwitchRollsBackAndReceiptCannotBeReboundToOldPreparedEvidence() throws {
        let fixture = try PrototypeFixture()
        defer { fixture.remove() }
        try fixture.files(3)
        let prototype = try BoundedTraversalPrototype(database: fixture.database, mode: .spool)
        defer { prototype.close() }
        try prototype.begin(root: fixture.root)
        try complete(prototype, limit: 2)
        try prototype.publish()
        try Data([1]).write(to: fixture.root.appending(path: "new"))
        let fence = ScanPublicationFence()
        try prototype.begin(root: fixture.root, permit: fence.permit())
        try complete(prototype, limit: 2)
        XCTAssertThrowsError(try prototype.publish() { throw BoundedTraversalPrototype.Failure.injected })
        XCTAssertEqual(try prototype.visibleCount(), 3)
        var receipt: UUID?
        XCTAssertThrowsError(try prototype.publish() {
            try Data([42]).write(to: fixture.root.appending(path: "later"))
            receipt = fence.invalidate()
        })
        XCTAssertEqual(try prototype.visibleCount(), 3)
        XCTAssertTrue(fence.acknowledge(try XCTUnwrap(receipt)))
        try prototype.begin(root: fixture.root, permit: fence.permit())
        XCTAssertThrowsError(try prototype.publish(), "A new permit cannot bless the old generation")
        XCTAssertEqual(try prototype.visibleCount(), 3)
        prototype.close()
        let reopened = try BoundedTraversalPrototype(database: fixture.database, mode: .spool)
        defer { reopened.close() }
        XCTAssertThrowsError(try reopened.step())
        XCTAssertThrowsError(try reopened.publish())
        XCTAssertEqual(try reopened.visibleCount(), 3, "Research prototype fails closed until durable receipt recovery is implemented")
    }

    func testCancellationAfterReadingRequiresReopenAndReplaysAllNames() async throws {
        for mode in [BoundedTraversalPrototype.Mode.stream, .spool] {
            let fixture = try PrototypeFixture()
            defer { fixture.remove() }
            try fixture.files(5)
            let cancelled = try await Task.detached {
                let prototype = try BoundedTraversalPrototype(database: fixture.database, mode: mode)
                defer { prototype.close() }
                try prototype.begin(root: fixture.root)
                do {
                    _ = try prototype.step(limit: 2) {
                        withUnsafeCurrentTask { $0?.cancel() }
                        try Task.checkCancellation()
                    }
                    return false
                } catch is CancellationError { return true }
            }.value
            XCTAssertTrue(cancelled)
            let reopened = try BoundedTraversalPrototype(database: fixture.database, mode: mode)
            defer { reopened.close() }
            try complete(reopened, limit: 2)
            try reopened.publish()
            try assertVisibleMetadata(reopened, files: (0..<5).map { fixture.root.appending(path: "f\($0)") })
        }
    }

    func testFailedSpoolMetadataTransactionReplaysItsDurablePage() throws {
        let fixture = try PrototypeFixture()
        defer { fixture.remove() }
        try fixture.files(10)
        var prototype = try BoundedTraversalPrototype(database: fixture.database, mode: .spool)
        try prototype.begin(root: fixture.root)
        for _ in 0..<20 {
            _ = try prototype.step(limit: 2)
            if try prototype.connection.scalarInt("SELECT phase FROM directories WHERE parent IS NULL") == 2 { break }
        }
        let offset = try prototype.connection.scalarInt("SELECT offset FROM directories WHERE parent IS NULL")
        XCTAssertLessThan(offset, 10)
        try prototype.connection.execute("CREATE TRIGGER fail_metadata BEFORE INSERT ON entries BEGIN SELECT RAISE(ABORT,'injected metadata failure'); END")
        XCTAssertThrowsError(try prototype.step(limit: 2))
        try prototype.connection.execute("DROP TRIGGER fail_metadata")
        XCTAssertEqual(try prototype.connection.scalarInt("SELECT offset FROM directories WHERE parent IS NULL"), offset)
        XCTAssertThrowsError(try prototype.step(limit: 2))
        prototype.close()
        prototype = try BoundedTraversalPrototype(database: fixture.database, mode: .spool)
        defer { prototype.close() }
        try complete(prototype, limit: 2)
        try prototype.publish()
        XCTAssertEqual(prototype.counters.enumerated, 0)
        try assertVisibleMetadata(prototype, files: (0..<10).map { fixture.root.appending(path: "f\($0)") })
    }

    func testQueueLookupUsesOrderedIndexWithoutWholeFrontierSort() throws {
        let fixture = try PrototypeFixture()
        defer { fixture.remove() }
        let prototype = try BoundedTraversalPrototype(database: fixture.database, mode: .stream)
        defer { prototype.close() }
        try prototype.begin(root: fixture.root)
        try prototype.connection.execute("""
          WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000)
          INSERT INTO directories(generation,parent,owner_epoch,path,depth)
          SELECT 1,1,1,'synthetic-query-only-'||x,1 FROM n;
          """)
        for predicate in ["d.phase<3", "d.phase<4", "d.phase=3"] {
            let sql = prototype.directoryQuery(predicate: predicate)
            try prototype.connection.withStatement("EXPLAIN QUERY PLAN " + sql) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    XCTAssertFalse(String(cString: sqlite3_column_text(statement, 3)).contains("TEMP B-TREE"))
                }
            }
            try prototype.connection.withStatement(sql) { statement in
                _ = sqlite3_step(statement)
                XCTAssertLessThan(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0), 100,
                                  "An ordered first-row or empty-phase lookup must not visit 10k pending rows")
            }
        }
    }

    func testSameCountRenameAndHardLinkIdentityAreNotLostByCountOracle() throws {
        for mode in [BoundedTraversalPrototype.Mode.stream, .spool] {
            let fixture = try PrototypeFixture()
            defer { fixture.remove() }
            try fixture.files(3)
            let linked = fixture.root.appending(path: "linked")
            try FileManager.default.linkItem(at: fixture.root.appending(path: "f0"), to: linked)
            let prototype = try BoundedTraversalPrototype(database: fixture.database, mode: mode)
            defer { prototype.close() }
            try prototype.begin(root: fixture.root)
            try complete(prototype, limit: 2)
            try prototype.publish()
            let renamed = fixture.root.appending(path: "renamed")
            try FileManager.default.moveItem(at: fixture.root.appending(path: "f1"), to: renamed)
            try Data([1, 2, 3, 4]).write(to: fixture.root.appending(path: "f2"))
            try prototype.begin(root: fixture.root)
            try complete(prototype, limit: 2)
            try prototype.publish()
            try assertVisibleMetadata(prototype, files: [fixture.root.appending(path: "f0"), linked, renamed, fixture.root.appending(path: "f2")])
            XCTAssertEqual(try prototype.visibleCount(), 4, "This is a path count, not a unique physical-object count")
        }
    }

    func testCompletedDirectoryIsRevalidatedAfterClose() throws {
        let fixture = try PrototypeFixture()
        defer { fixture.remove() }
        try fixture.files(3)
        var prototype = try BoundedTraversalPrototype(database: fixture.database, mode: .spool)
        try prototype.begin(root: fixture.root)
        try complete(prototype, limit: 2)
        prototype.close()
        try Data([1]).write(to: fixture.root.appending(path: "late"))
        prototype = try BoundedTraversalPrototype(database: fixture.database, mode: .spool)
        defer { prototype.close() }
        XCTAssertThrowsError(try prototype.step(limit: 2))
        XCTAssertEqual(try prototype.visibleCount(), 0)
    }

    private func complete(_ prototype: BoundedTraversalPrototype, limit: Int) throws {
        for _ in 0..<100 {
            if try autoreleasepool(invoking: { try prototype.step(limit: limit) }) { return }
        }
        XCTFail("Small fixture did not finish")
        throw BoundedTraversalPrototype.Failure.incomplete
    }

    private func assertVisibleMetadata(_ prototype: BoundedTraversalPrototype, files: [URL], file: StaticString = #filePath, line: UInt = #line) throws {
        var expected: [String: stat] = [:]
        for url in files {
            var value = stat()
            guard lstat(url.path, &value) == 0 else { throw BoundedTraversalPrototype.Failure.unavailable }
            expected[url.path] = value
        }
        try prototype.connection.withStatement("""
          SELECT d.path||'/'||e.name,e.device,e.inode,e.logical,e.allocated,e.modified,e.sampled,e.links
          FROM entries e JOIN visible v ON e.generation=v.generation
          JOIN directories d ON e.directory=d.id AND e.epoch=d.epoch
          WHERE d.parent IS NULL OR EXISTS(SELECT 1 FROM directories p WHERE p.id=d.parent AND p.epoch=d.owner_epoch)
          """) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let path = String(cString: sqlite3_column_text(statement, 0))
                guard let value = expected.removeValue(forKey: path) else {
                    XCTFail("Unexpected or duplicate visible path: \(path)", file: file, line: line)
                    continue
                }
                XCTAssertEqual(sqlite3_column_int64(statement, 1), Int64(value.st_dev), file: file, line: line)
                XCTAssertEqual(sqlite3_column_int64(statement, 2), Int64(bitPattern: UInt64(value.st_ino)), file: file, line: line)
                XCTAssertEqual(sqlite3_column_int64(statement, 3), value.st_size, file: file, line: line)
                XCTAssertEqual(sqlite3_column_int64(statement, 4), value.st_blocks * 512, file: file, line: line)
                XCTAssertEqual(sqlite3_column_double(statement, 5), Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9, accuracy: 0.000001, file: file, line: line)
                XCTAssertGreaterThan(sqlite3_column_double(statement, 6), 0, file: file, line: line)
                XCTAssertLessThanOrEqual(sqlite3_column_double(statement, 6), Date().timeIntervalSince1970, file: file, line: line)
                XCTAssertEqual(sqlite3_column_int64(statement, 7), Int64(value.st_nlink), file: file, line: line)
            }
        }
        XCTAssertTrue(expected.isEmpty, "Missing visible paths: \(expected.keys.sorted())", file: file, line: line)
    }
}

private struct PrototypeFixture {
    let directory: URL
    var root: URL { directory.appending(path: "watched") }
    var database: URL { directory.appending(path: "prototype/evidence.sqlite") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "disk-steward-530-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func files(_ count: Int) throws {
        for index in 0..<count { try Data([UInt8(index % 255)]).write(to: root.appending(path: "f\(index)")) }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
