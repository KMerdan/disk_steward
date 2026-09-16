import DiskStewardCore
import Foundation
import XCTest

final class EvidenceQueryReadModelTests: XCTestCase, @unchecked Sendable {
    func testCurrentConsumerFilteringHappensBeforeLimitAndCursorIsStable() async throws {
        let fixture = try QueryFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let store = try EvidenceStore(url: fixture.databaseURL, dateSource: { now })
        var entries: [String: FileMetadata] = [:]
        for index in 0 ..< 520 {
            let directory = index == 519 ? "Downloads" : "ordinary"
            let path = "/fixture/\(directory)/file-\(String(format: "%04d", index)).bin"
            entries[path] = .init(
                objectID: "object-\(index)",
                rootPath: "/fixture",
                path: path,
                logicalBytes: Int64(index + 1),
                allocatedBytes: Int64(index + 1),
                modifiedAt: now
            )
        }
        try await observe(store, id: "large", at: now, entries: entries)

        let filtered = try await store.queryCurrentConsumers(category: "downloads", limit: 1)
        XCTAssertEqual(filtered.matchedCount, 1)
        XCTAssertEqual(filtered.items.first?.state.objectID, "object-519")
        XCTAssertFalse(filtered.truncated)

        var cursor: String?
        var identifiers: [String] = []
        repeat {
            let page = try await store.queryCurrentConsumers(cursor: cursor, limit: 73)
            XCTAssertEqual(page.matchedCount, 520)
            identifiers.append(contentsOf: page.items.map { $0.state.objectID })
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(identifiers.count, 520)
        XCTAssertEqual(Set(identifiers).count, 520)
    }

    func testDuplicateBasenamesRemainSeparateObjectsAndGrowthIncludesRollups() async throws {
        let fixture = try QueryFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let store = try EvidenceStore(url: fixture.databaseURL, dateSource: { now })
        let first = FileMetadata(objectID: "first", rootPath: "/fixture", path: "/fixture/one/same.bin", logicalBytes: 10, allocatedBytes: 16, modifiedAt: now)
        let second = FileMetadata(objectID: "second", rootPath: "/fixture", path: "/fixture/two/same.bin", logicalBytes: 20, allocatedBytes: 32, modifiedAt: now)
        try await observe(store, id: "duplicates", at: now, entries: [first.path: first, second.path: second])

        let chain = try await store.provenanceChain(pathQuery: "same.bin", limit: 10)
        XCTAssertEqual(Set(chain.objectIDs), ["first", "second"])
        XCTAssertEqual(chain.currentStates.count, 2)
        XCTAssertEqual(chain.events.count, 2)

        try await store.insert(.init(
            eventID: "old-growth",
            observedAt: now.addingTimeInterval(-10 * 86_400),
            operation: .modify,
            path: "/fixture/old.bin",
            logicalDelta: 100,
            allocatedDelta: 128,
            consumerCategory: "watched-root",
            confidence: .inferred
        ))
        _ = try await store.applyRetention(try .init(), trigger: .scheduled)
        let growth = try await store.queryGrowth(from: now.addingTimeInterval(-20 * 86_400), through: now, limit: 10)
        XCTAssertTrue(growth.page.items.contains { $0.precision == "hourly" && $0.allocatedDelta == 128 })
        XCTAssertGreaterThanOrEqual(growth.aggregate.growthBytes, 128)
    }

    func testPaginationCursorExpiresWhenEvidenceRevisionChanges() async throws {
        let fixture = try QueryFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 2_100_000_100)
        let store = try EvidenceStore(url: fixture.databaseURL, dateSource: { now })
        let first = FileMetadata(objectID: "first", rootPath: "/fixture", path: "/fixture/first", logicalBytes: 1, allocatedBytes: 1, modifiedAt: now)
        let second = FileMetadata(objectID: "second", rootPath: "/fixture", path: "/fixture/second", logicalBytes: 2, allocatedBytes: 2, modifiedAt: now)
        try await observe(store, id: "revision-1", at: now, entries: [first.path: first, second.path: second])

        let page = try await store.queryCurrentConsumers(limit: 1)
        let cursor = try XCTUnwrap(page.nextCursor)
        let changed = FileMetadata(objectID: "second", rootPath: "/fixture", path: "/fixture/second", logicalBytes: 3, allocatedBytes: 3, modifiedAt: now.addingTimeInterval(1))
        try await observe(store, id: "revision-2", at: now.addingTimeInterval(1), entries: [first.path: first, changed.path: changed])

        do {
            _ = try await store.queryCurrentConsumers(cursor: cursor, limit: 1)
            XCTFail("Expected a revision-pinned cursor to expire")
        } catch EvidenceStoreError.cursorExpired {
            // Expected: callers must restart and receive an internally consistent page set.
        }
    }

    private func observe(_ store: EvidenceStore, id: String, at date: Date, entries: [String: FileMetadata]) async throws {
        let snapshot = StorageSnapshot(
            snapshotID: "snapshot-\(id)",
            observedAt: ISO8601DateFormatter().string(from: date),
            volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)]
        )
        let metadata = MetadataSnapshot(
            observationID: id,
            scopeVersionID: "scope",
            observedAt: date,
            entries: entries,
            rootCoverage: [.init(rootPath: "/fixture", coverage: .complete)],
            limitations: []
        )
        _ = try await store.recordObservation(
            snapshot: snapshot,
            metadata: metadata,
            scope: .init(scopeVersionID: "scope", effectiveAt: date, rootPaths: ["/fixture"], excludedPaths: [], maximumEntries: 1_000, maximumDepth: 10),
            trigger: .scheduled
        )
    }
}

private struct QueryFixture {
    let root: URL
    let databaseURL: URL

    init() throws {
        root = URL(fileURLWithPath: "/tmp/ds-query-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        databaseURL = root.appending(path: "evidence.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
