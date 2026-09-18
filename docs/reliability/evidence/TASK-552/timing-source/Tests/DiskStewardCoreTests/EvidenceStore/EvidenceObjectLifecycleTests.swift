import Foundation
import XCTest
@testable import DiskStewardCore

final class EvidenceObjectLifecycleTests: XCTestCase, @unchecked Sendable {
    func testMeasuredTimingSurvivesInlinePublicationReopenAndAllEventReaders() async throws {
        let fixture = try LifecycleFixture()
        var store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "timing-scope", roots: ["/watch"])
        func sample(_ path: String, bytes: Int64, seconds: Int) -> FileMetadata {
            .init(objectID: "timed-object", rootPath: "/watch", path: path,
                  logicalBytes: bytes, allocatedBytes: bytes, modifiedAt: nil,
                  observedAt: Self.start.addingTimeInterval(Double(seconds)))
        }
        let first = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "T1"),
            metadata: Self.metadata(id: "T1", scope: scope, files: [sample("/watch/A", bytes: 3, seconds: 100)], seconds: 200),
            scope: scope, trigger: .scheduled)
        let changed = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "T2"),
            metadata: Self.metadata(id: "T2", scope: scope, files: [sample("/watch/B", bytes: 7, seconds: 300)], seconds: 400),
            scope: scope, trigger: .scheduled)
        let deleted = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "T3"),
            metadata: Self.metadata(id: "T3", scope: scope, files: [], seconds: 500),
            scope: scope, trigger: .scheduled)
        let inline = first.events + changed.events + deleted.events
        XCTAssertEqual(Set(inline.map(\.operation)), [.baseline, .rename, .modify, .delete])
        func check(_ events: [EvidenceStoreEvent]) throws {
            XCTAssertEqual(events.count, 4)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            for event in events {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any])
                let timing = try XCTUnwrap(json["timing"] as? [String: Any], "No timing for \(event.operation)")
                let lower: Double? = event.operation == .baseline ? nil : (event.operation == .delete ? 300 : 100)
                let upper: Double = switch event.operation { case .baseline: 100; case .rename: 400; case .modify: 300; default: 500 }
                let detected: Double = event.operation == .baseline ? 200 : (event.operation == .delete ? 500 : 400)
                XCTAssertEqual(timing["occurredStart"] as? Double, lower.map { Self.start.timeIntervalSince1970 + $0 })
                if lower == nil { XCTAssertTrue(timing["occurredStart"] is NSNull) }
                XCTAssertEqual(timing["occurredEnd"] as? Double, Self.start.timeIntervalSince1970 + upper)
                XCTAssertEqual(timing["detectedAt"] as? Double, Self.start.timeIntervalSince1970 + detected)
            }
        }
        try check(inline)
        await store.close()
        store = try EvidenceStore(url: fixture.databaseURL)
        let from = Self.start, through = Self.start.addingTimeInterval(600)
        try check(try await store.events(from: from, through: through))
        try check(try await store.queryEvents(from: from, through: through).items)
        try check(try await store.provenanceChain(pathQuery: "B").events)
        await store.close()
    }

    func testScopeReentryDoesNotInventReplacementGrowthOrDelayedDeletion() async throws {
        for reentry in ["same", "replacement", "absent"] {
            let fixture = try LifecycleFixture()
            var store = try EvidenceStore(url: fixture.databaseURL)
            let watch = Self.scope(id: "scope-watch", roots: ["/watch"])
            let other = Self.scope(id: "scope-other", roots: ["/other"])
            _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
                metadata: Self.metadata(id: "O1", scope: watch, files: [Self.file("old", path: "/watch/A", bytes: 3)]),
                scope: watch, trigger: .scheduled)
            let exit = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"),
                metadata: Self.metadata(id: "O2", scope: other, files: [], seconds: 10), scope: other, trigger: .scheduled)
            XCTAssertEqual(exit.events.map(\.operation), [.scopeExit])
            await store.close()
            store = try EvidenceStore(url: fixture.databaseURL)
            let files = reentry == "absent" ? [] : [Self.file(reentry == "same" ? "old" : "new", path: "/watch/A", bytes: 7)]
            for number in 3...4 {
                let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V\(number)"),
                    metadata: Self.metadata(id: "O\(number)", scope: watch, files: files, seconds: number * 10),
                    scope: watch, trigger: .scheduled)
                XCTAssertEqual(result.events.map(\.operation), number == 3 && reentry != "absent" ? [.scopeEnter] : [], reentry)
                XCTAssertEqual(result.events.reduce(0) { $0 + $1.logicalDelta }, 0, reentry)
                XCTAssertEqual(result.currentFiles.filter { $0.presence == .present }.map(\.objectID), files.map(\.objectID), reentry)
                if reentry == "replacement" {
                    XCTAssertFalse(result.currentFiles.contains { $0.objectID == "old" }, "An old scoped-out path must not collide with its new occupant.")
                }
            }
            let db = try SQLiteConnection(url: fixture.databaseURL)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM change_events WHERE operation IN ('replace','delete','modify','truncate')"), 0)
            if reentry != "absent" {
                XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM change_events WHERE operation = 'scope-enter' AND occurred_start IS NULL"), 1)
            }
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM file_objects WHERE lifecycle_state = 'deleted'"), 0)
            db.close()
            await store.close()
        }
    }

    func testFirstObservationHasUnknownOccurrenceStartAndMeasuredUpperBound() async throws {
        for hasEarlierEmptyObservation in [false, true] {
            let fixture = try LifecycleFixture()
            let store = try EvidenceStore(url: fixture.databaseURL)
            let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
            if hasEarlierEmptyObservation {
                _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V0"),
                    metadata: Self.metadata(id: "O0", scope: scope, files: []), scope: scope, trigger: .scheduled)
            }
            let file = FileMetadata(objectID: "new", rootPath: "/watch", path: "/watch/A", logicalBytes: 3,
                allocatedBytes: 3, modifiedAt: nil, observedAt: Self.start.addingTimeInterval(20))
            let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
                metadata: Self.metadata(id: "O1", scope: scope, files: [file], seconds: 30), scope: scope, trigger: .scheduled)
            XCTAssertEqual(result.events.first?.operation, hasEarlierEmptyObservation ? .create : .baseline)
            let db = try SQLiteConnection(url: fixture.databaseURL)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM change_events WHERE occurred_start IS NULL"), 1)
            XCTAssertEqual(try db.scalarInt("SELECT occurred_end FROM change_events"), Int64(Self.start.addingTimeInterval(20).timeIntervalSince1970))
            XCTAssertEqual(try db.scalarInt("SELECT detected_at FROM change_events"), Int64(Self.start.addingTimeInterval(30).timeIntervalSince1970))
            db.close()
            await store.close()
        }
    }

    func testContradictorySampleChronologyCannotOverwriteCurrentTruth() async throws {
        for sampleSeconds in [30, 60] {
            let fixture = try LifecycleFixture()
            let store = try EvidenceStore(url: fixture.databaseURL)
            let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
            let baseline = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
                metadata: Self.metadata(id: "O1", scope: scope, files: [Self.file("same", path: "/watch/A", bytes: 3)], seconds: 40),
                scope: scope, trigger: .scheduled)
            let stale = FileMetadata(objectID: "same", rootPath: "/watch", path: "/watch/B", logicalBytes: 8,
                allocatedBytes: 8, modifiedAt: nil, observedAt: Self.start.addingTimeInterval(Double(sampleSeconds)))
            do {
                _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"),
                    metadata: Self.metadata(id: "O2", scope: scope, files: [stale], seconds: 50), scope: scope, trigger: .scheduled)
                XCTFail("A sample before the prior state or after publication must not publish.")
            } catch EvidenceStoreError.invalidObservation {}
            let current = try await store.currentFiles(includeNonActionable: true)
            XCTAssertEqual(current, baseline.currentFiles)
            let db = try SQLiteConnection(url: fixture.databaseURL)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM observation_runs WHERE observation_id = 'O2'"), 0)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM change_events WHERE occurred_start > occurred_end"), 0)
            db.close()
            await store.close()
        }
    }

    func testReplacementOfAliasUsesItsBindingEvidenceNotAnotherAliasSampleTime() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        func sample(_ object: String, _ path: String, bytes: Int64, at seconds: Int, links: Int) -> FileMetadata {
            FileMetadata(objectID: object, rootPath: "/watch", path: path, logicalBytes: bytes,
                allocatedBytes: bytes, modifiedAt: nil, linkCount: links, observedAt: Self.start.addingTimeInterval(Double(seconds)))
        }
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [
                sample("old", "/watch/B", bytes: 3, at: 10, links: 2),
                sample("old", "/watch/A", bytes: 3, at: 100, links: 2),
            ], seconds: 100), scope: scope, trigger: .scheduled)
        let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [
                sample("old", "/watch/A", bytes: 3, at: 120, links: 1),
                sample("new", "/watch/B", bytes: 7, at: 110, links: 1),
            ], seconds: 130), scope: scope, trigger: .scheduled)
        let event = try XCTUnwrap(result.events.first { $0.operation == .replace })
        let db = try SQLiteConnection(url: fixture.databaseURL)
        XCTAssertEqual(try db.scalarInt("SELECT occurred_start FROM change_events WHERE event_id = '\(event.eventID)'"), Int64(Self.start.addingTimeInterval(10).timeIntervalSince1970))
        XCTAssertEqual(try db.scalarInt("SELECT occurred_end FROM change_events WHERE event_id = '\(event.eventID)'"), Int64(Self.start.addingTimeInterval(110).timeIntervalSince1970))
        XCTAssertEqual(try db.scalarText("SELECT path_before FROM change_events WHERE event_id = '\(event.eventID)'"), "/watch/B")
        db.close()
        await store.close()
    }

    func testLegacyNewestAliasSampleWinsWithoutInventingRename() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [
                Self.file("shared", path: "/watch/A", bytes: 3, linkCount: 2),
                Self.file("shared", path: "/watch/B", bytes: 3, linkCount: 2),
            ]), scope: scope, trigger: .scheduled)
        let earlier = FileMetadata(objectID: "shared", rootPath: "/watch", path: "/watch/A", logicalBytes: 3,
            allocatedBytes: 3, modifiedAt: nil, linkCount: 2, observedAt: Self.start.addingTimeInterval(1))
        let later = FileMetadata(objectID: "shared", rootPath: "/watch", path: "/watch/B", logicalBytes: 8,
            allocatedBytes: 8, modifiedAt: nil, linkCount: 2, observedAt: Self.start.addingTimeInterval(3))
        let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [earlier, later], seconds: 10), scope: scope, trigger: .scheduled)
        XCTAssertEqual(result.currentFiles.first?.path, later.path)
        XCTAssertEqual(result.currentFiles.first?.logicalBytes, 8)
        XCTAssertEqual(result.currentFiles.first?.observedAt, later.observedAt)
        XCTAssertEqual(result.events.map(\.operation), [.modify])
        XCTAssertEqual(result.events.first?.logicalDelta, 5)
        XCTAssertEqual(result.events.first?.observedAt, later.observedAt)
        await store.close()
    }

    func testLegacyPartialReplacementKeepsUnobservedAliasUnknown() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [
                Self.file("old", path: "/watch/A", bytes: 3, linkCount: 2),
                Self.file("old", path: "/watch/B", bytes: 3, linkCount: 2),
            ]), scope: scope, trigger: .scheduled)
        let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [Self.file("new", path: "/watch/A", bytes: 7)],
                coverage: .partial, limitations: ["entry limit"], seconds: 10), scope: scope, trigger: .scheduled)
        XCTAssertEqual(result.currentFiles.count, 2)
        let old = try XCTUnwrap(result.currentFiles.first { $0.objectID == "old" })
        XCTAssertEqual(old.path, "/watch/B")
        XCTAssertEqual(old.presence, .unknown)
        XCTAssertEqual(old.stateAsOfObservationID, "O1")
        XCTAssertFalse(old.actionable)
        XCTAssertEqual(result.currentFiles.first { $0.objectID == "new" }?.presence, .present)
        XCTAssertEqual(result.events.reduce(0) { $0 + $1.logicalDelta }, 7)
        XCTAssertFalse(result.events.contains { $0.operation == .delete })
        await store.close()
    }

    func testLegacyReplacementOfNoncanonicalAliasPreservesSurvivingObjectAndBinding() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [
                Self.file("old", path: "/watch/A", bytes: 3, linkCount: 2),
                Self.file("old", path: "/watch/B", bytes: 3, linkCount: 2),
            ]), scope: scope, trigger: .scheduled)
        let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [
                Self.file("old", path: "/watch/A", bytes: 3), Self.file("new", path: "/watch/B", bytes: 7),
            ], seconds: 10), scope: scope, trigger: .scheduled)
        XCTAssertEqual(Set(result.currentFiles.map(\.objectID)), ["old", "new"])
        XCTAssertEqual(result.events.reduce(0) { $0 + $1.logicalDelta }, 7)
        let db = try SQLiteConnection(url: fixture.databaseURL)
        XCTAssertEqual(try db.scalarText("SELECT path_before FROM change_events WHERE after_observation_id = 'O2' AND object_id = 'new'"), "/watch/B")
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM path_bindings WHERE object_id = 'old' AND path = '/watch/A' AND valid_through IS NULL"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM path_bindings WHERE object_id = 'old' AND path = '/watch/B' AND valid_through IS NULL"), 0)
        db.close()
        await store.close()
    }

    func testLegacyPathSwapDoesNotDependOnCurrentRowUpdateOrder() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [Self.file("one", path: "/watch/A", bytes: 3), Self.file("two", path: "/watch/B", bytes: 7)]),
            scope: scope, trigger: .scheduled)
        let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [Self.file("one", path: "/watch/B", bytes: 3), Self.file("two", path: "/watch/A", bytes: 7)], seconds: 10),
            scope: scope, trigger: .scheduled)
        XCTAssertEqual(result.currentFiles.first { $0.objectID == "one" }?.path, "/watch/B")
        XCTAssertEqual(result.currentFiles.first { $0.objectID == "two" }?.path, "/watch/A")
        XCTAssertEqual(result.events.map(\.operation), [.rename, .rename])
        await store.close()
    }

    func testLegacyMultiObjectReplacementAccountsEachPhysicalObjectOnce() async throws {
        for merge in [false, true] {
            let fixture = try LifecycleFixture()
            let store = try EvidenceStore(url: fixture.databaseURL)
            let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
            let linked = [Self.file("linked", path: "/watch/A", bytes: 3, linkCount: 2), Self.file("linked", path: "/watch/B", bytes: 3, linkCount: 2)]
            let separate = [Self.file("one", path: "/watch/A", bytes: 5), Self.file("two", path: "/watch/B", bytes: 7)]
            _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
                metadata: Self.metadata(id: "O1", scope: scope, files: merge ? separate : linked), scope: scope, trigger: .scheduled)
            let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"),
                metadata: Self.metadata(id: "O2", scope: scope, files: merge ? linked : separate, seconds: 10), scope: scope, trigger: .scheduled)
            XCTAssertEqual(result.events.reduce(0) { $0 + $1.logicalDelta }, merge ? -9 : 9)
            XCTAssertEqual(result.events.reduce(0) { $0 + $1.allocatedDelta }, merge ? -9 : 9)
            XCTAssertEqual(result.currentFiles.reduce(0) { $0 + $1.logicalBytes }, merge ? 3 : 12)
            await store.close()
        }
    }

    func testLegacyMovePlusGrowthRecordsBothChanges() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [Self.file("same", path: "/watch/A", bytes: 3)]), scope: scope, trigger: .scheduled)
        let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [Self.file("same", path: "/watch/B", bytes: 8)], seconds: 10), scope: scope, trigger: .scheduled)
        XCTAssertEqual(Set(result.events.map(\.operation)), [.rename, .modify])
        XCTAssertEqual(result.events.reduce(0) { $0 + $1.logicalDelta }, 5)
        let db = try SQLiteConnection(url: fixture.databaseURL)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM file_state_observations WHERE observation_id = 'O2'"), 1)
        db.close()
        await store.close()
    }

    func testLegacyExplicitSampleTimeIsNotReplacedWithSnapshotTime() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        let sampled = FileMetadata(objectID: "same", rootPath: "/watch", path: "/watch/A", logicalBytes: 3,
            allocatedBytes: 3, modifiedAt: nil, observedAt: Self.start)
        let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [sampled], seconds: 100), scope: scope, trigger: .scheduled)
        XCTAssertEqual(result.currentFiles.first?.observedAt, Self.start)
        XCTAssertEqual(result.events.first?.observedAt, Self.start)
        let db = try SQLiteConnection(url: fixture.databaseURL)
        XCTAssertEqual(try db.scalarInt("SELECT observed_at FROM file_state_observations"), Int64(Self.start.timeIntervalSince1970))
        XCTAssertEqual(try db.scalarInt("SELECT valid_from FROM path_bindings"), Int64(Self.start.timeIntervalSince1970))
        XCTAssertEqual(try db.scalarInt("SELECT started_at FROM observation_runs"), Int64(Self.start.timeIntervalSince1970))
        XCTAssertEqual(try db.scalarInt("SELECT completed_at FROM observation_runs"), Int64(Self.start.addingTimeInterval(100).timeIntervalSince1970))
        db.close()
        await store.close()
    }

    func testCompleteABCObservationRecordsDeletionAndReplayIsIdempotent() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])

        _ = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [
                Self.file("A", path: "/watch/A", bytes: 10),
                Self.file("B", path: "/watch/B", bytes: 20),
                Self.file("C", path: "/watch/C", bytes: 30),
            ]),
            scope: scope,
            trigger: .scheduled
        )
        let result = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [
                Self.file("A", path: "/watch/A", bytes: 10),
                Self.file("C", path: "/watch/C", bytes: 30),
            ]),
            scope: scope,
            trigger: .scheduled
        )

        XCTAssertEqual(result.events.map(\.operation), [.delete])
        XCTAssertEqual(result.events.first?.path, "/watch/B")
        XCTAssertEqual(result.currentFiles.map(\.path).sorted(), ["/watch/A", "/watch/C"])
        let countBeforeReplay = try await store.eventCount()

        let replay = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [
                Self.file("A", path: "/watch/A", bytes: 10),
                Self.file("C", path: "/watch/C", bytes: 30),
            ]),
            scope: scope,
            trigger: .scheduled
        )
        XCTAssertTrue(replay.events.isEmpty)
        let countAfterReplay = try await store.eventCount()
        XCTAssertEqual(countAfterReplay, countBeforeReplay)
        await store.close()
    }

    func testPartialABCObservationKeepsBUnknownUntilCompleteRecovery() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        _ = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [
                Self.file("A", path: "/watch/A", bytes: 10),
                Self.file("B", path: "/watch/B", bytes: 20),
                Self.file("C", path: "/watch/C", bytes: 30),
            ]),
            scope: scope,
            trigger: .scheduled
        )

        let partial = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-2"),
            metadata: Self.metadata(
                id: "O2",
                scope: scope,
                files: [Self.file("A", path: "/watch/A", bytes: 10), Self.file("C", path: "/watch/C", bytes: 30)],
                coverage: .partial,
                limitations: ["Detailed scan stopped at the configured entry limit."]
            ),
            scope: scope,
            trigger: .scheduled
        )

        XCTAssertFalse(partial.events.contains { $0.operation == .delete })
        let unknownB = try XCTUnwrap(partial.currentFiles.first { $0.objectID == "B" })
        XCTAssertEqual(unknownB.presence, .unknown)
        XCTAssertFalse(unknownB.actionable)
        XCTAssertEqual(unknownB.stateAsOfObservationID, "O1")
        XCTAssertEqual(partial.coverageGaps.map(\.reason), ["entry-cap"])

        let recovered = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-3"),
            metadata: Self.metadata(id: "O3", scope: scope, files: [
                Self.file("A", path: "/watch/A", bytes: 10),
                Self.file("C", path: "/watch/C", bytes: 30),
            ]),
            scope: scope,
            trigger: .recovery
        )
        XCTAssertEqual(recovered.events.map(\.operation), [.delete])
        let allGaps = try await store.coverageGaps()
        XCTAssertNotNil(allGaps.first { $0.observationID == "O2" }?.endedAt)
        await store.close()
    }

    func testHardLinkedPathsRemainOnePhysicalObjectAndNeverCrashReconciliation() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])

        let first = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [
                Self.file("shared-inode", path: "/watch/a", bytes: 64, linkCount: 2),
                Self.file("shared-inode", path: "/watch/b", bytes: 64, linkCount: 2),
            ]),
            scope: scope,
            trigger: .startup
        )

        XCTAssertEqual(first.events.map(\.operation), [.baseline])
        XCTAssertEqual(first.currentFiles.count, 1)
        XCTAssertEqual(first.currentFiles.first?.path, "/watch/a")
        XCTAssertEqual(first.currentFiles.first?.allocatedBytes, 64)
        XCTAssertFalse(first.currentFiles.first?.actionable == true)
        let actionableWhileLinked = try await store.currentFiles()
        XCTAssertTrue(actionableWhileLinked.isEmpty)

        let repeated = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [
                Self.file("shared-inode", path: "/watch/b", bytes: 64, linkCount: 2),
                Self.file("shared-inode", path: "/watch/a", bytes: 64, linkCount: 2),
            ], seconds: 1),
            scope: scope,
            trigger: .scheduled
        )
        XCTAssertTrue(repeated.events.isEmpty)
        XCTAssertEqual(repeated.currentFiles.first?.path, "/watch/a")

        let oneLinkRemaining = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-3"),
            metadata: Self.metadata(id: "O3", scope: scope, files: [
                Self.file("shared-inode", path: "/watch/b", bytes: 64),
            ], seconds: 2),
            scope: scope,
            trigger: .scheduled
        )
        XCTAssertTrue(oneLinkRemaining.events.isEmpty)
        XCTAssertEqual(oneLinkRemaining.currentFiles.first?.path, "/watch/b")
        XCTAssertTrue(oneLinkRemaining.currentFiles.first?.actionable == true)

        let deleted = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-4"),
            metadata: Self.metadata(id: "O4", scope: scope, files: [], seconds: 3),
            scope: scope,
            trigger: .scheduled
        )
        XCTAssertEqual(deleted.events.map(\.operation), [.delete])
        XCTAssertTrue(deleted.currentFiles.isEmpty)
        await store.close()
    }

    func testModifyTruncateRenameAndReplacementHaveDistinctIdentityAwareEvents() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])

        let observations: [(String, FileMetadata, EvidenceStoreEvent.Operation?)] = [
            ("O1", Self.file("object-1", path: "/watch/item", bytes: 100), .baseline),
            ("O2", Self.file("object-1", path: "/watch/item", bytes: 150), .modify),
            ("O3", Self.file("object-1", path: "/watch/item", bytes: 50), .truncate),
            ("O4", Self.file("object-1", path: "/watch/renamed", bytes: 50), .rename),
            ("O5", Self.file("object-2", path: "/watch/renamed", bytes: 75), .replace),
        ]

        for (offset, item) in observations.enumerated() {
            let result = try await store.recordObservation(
                snapshot: Self.volumeSnapshot(id: "volume-\(offset + 1)"),
                metadata: Self.metadata(id: item.0, scope: scope, files: [item.1], seconds: offset),
                scope: scope,
                trigger: .scheduled
            )
            if item.2 == .replace {
                // Replacement accounts for incoming and retired physical
                // objects separately, including split/merge hard-link cases.
                XCTAssertEqual(result.events.map(\.operation), [.replace, .replace])
                XCTAssertEqual(result.events.map(\.logicalDelta).sorted(), [-50, 75])
                XCTAssertEqual(result.events.reduce(0) { $0 + $1.logicalDelta }, 25)
            } else {
                XCTAssertEqual(result.events.map(\.operation), [item.2].compactMap { $0 })
            }
        }
        let current = try await store.currentFiles(includeNonActionable: true)
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.objectID, "object-2")
        XCTAssertEqual(current.first?.path, "/watch/renamed")
        await store.close()
    }

    func testScopeChangeEmitsEnterAndExitWithoutClaimingDeletion() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let oldScope = Self.scope(id: "scope-old", roots: ["/watch"])
        let newScope = Self.scope(id: "scope-new", roots: ["/other"])
        _ = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-1"),
            metadata: Self.metadata(id: "O1", scope: oldScope, files: [Self.file("B", path: "/watch/B", bytes: 20)]),
            scope: oldScope,
            trigger: .scheduled
        )

        let result = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-2"),
            metadata: Self.metadata(id: "O2", scope: newScope, files: [Self.file("D", path: "/other/D", root: "/other", bytes: 40)]),
            scope: newScope,
            trigger: .scheduled
        )

        XCTAssertEqual(Set(result.events.map(\.operation)), Set([.scopeEnter, .scopeExit]))
        XCTAssertFalse(result.events.contains { $0.operation == .delete })
        let old = try XCTUnwrap(result.currentFiles.first { $0.objectID == "B" })
        XCTAssertEqual(old.presence, .outOfScope)
        XCTAssertFalse(old.actionable)
        await store.close()
    }

    func testRestartRecordsOfflineIntervalAndStillReconcilesCompleteDeletion() async throws {
        let fixture = try LifecycleFixture()
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        var store: EvidenceStore? = try EvidenceStore(url: fixture.databaseURL)
        _ = try await store!.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [Self.file("B", path: "/watch/B", bytes: 20)]),
            scope: scope,
            trigger: .scheduled
        )
        await store!.close()
        store = nil

        let reopened = try EvidenceStore(url: fixture.databaseURL)
        let result = try await reopened.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [], seconds: 60),
            scope: scope,
            trigger: .startup
        )
        XCTAssertEqual(result.events.map(\.operation), [.delete])
        XCTAssertTrue(result.coverageGaps.contains { $0.reason == "app-offline" && $0.endedAt != nil })
        await reopened.close()
    }

    func testObservationTransactionRollsBackOnScopeMismatch() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        let wrong = MetadataSnapshot(
            observationID: "O1",
            scopeVersionID: "different-scope",
            observedAt: Self.start,
            entries: [:],
            rootCoverage: [.init(rootPath: "/watch", coverage: .complete)],
            limitations: []
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await store.recordObservation(
                snapshot: Self.volumeSnapshot(id: "volume-1"),
                metadata: wrong,
                scope: scope,
                trigger: .manual
            )
        }
        let diagnostics = try await store.diagnostics()
        XCTAssertEqual(diagnostics.observationCount, 0)
        XCTAssertEqual(diagnostics.eventCount, 0)
        await store.close()
    }

    func testDuplicateRootCoverageIsRejectedWithoutWritingAnObservation() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        let duplicateCoverage = MetadataSnapshot(
            observationID: "O1",
            scopeVersionID: scope.scopeVersionID,
            observedAt: Self.start,
            entries: [:],
            rootCoverage: [
                .init(rootPath: "/watch", coverage: .complete),
                .init(rootPath: "/watch", coverage: .partial, limitations: ["duplicate"]),
            ],
            limitations: []
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await store.recordObservation(
                snapshot: Self.volumeSnapshot(id: "volume-1"),
                metadata: duplicateCoverage,
                scope: scope,
                trigger: .manual
            )
        }
        let diagnostics = try await store.diagnostics()
        XCTAssertEqual(diagnostics.observationCount, 0)
        XCTAssertEqual(diagnostics.eventCount, 0)
        await store.close()
    }

    func testLegacyRollbackAtEveryBoundaryPreservesPriorStateAndActiveGeneration() async throws {
        for point in ["after-observation", "after-present-objects", "after-missing-objects", "before-finalize"] {
            let fixture = try LifecycleFixture()
            let arm = LegacyCheckpointArm()
            let store = try EvidenceStore(url: fixture.databaseURL, reconciliationCheckpoint: { try arm.check($0) })
            let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
            _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
                metadata: Self.metadata(id: "O1", scope: scope, files: [Self.file("old", path: "/watch/A", bytes: 3)]),
                scope: scope, trigger: .scheduled)
            let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: Self.start.addingTimeInterval(1))
            let before = try await store.currentFiles(includeNonActionable: true)
            let next = Self.metadata(id: "O2", scope: scope, files: [Self.file("new", path: "/watch/A", bytes: 7)], seconds: 10)
            arm.set(point)
            do {
                _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"), metadata: next, scope: scope, trigger: .scheduled)
                XCTFail("Expected rollback at \(point)")
            } catch LegacyCheckpointFailure.injected {}
            let rolledBack = try await store.currentFiles(includeNonActionable: true)
            XCTAssertEqual(rolledBack, before)
            let db = try SQLiteConnection(url: fixture.databaseURL)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM observation_runs WHERE observation_id = 'O2'"), 0)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM change_events WHERE after_observation_id = 'O2'"), 0)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM snapshots WHERE snapshot_id = 'V2'"), 0)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM path_bindings WHERE valid_through IS NOT NULL"), 0)
            db.close()
            arm.set(nil)
            let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"), metadata: next, scope: scope, trigger: .scheduled)
            XCTAssertEqual(result.events.map(\.logicalDelta).sorted(), [-3, 7])
            let generations = try await store.scanGenerations()
            XCTAssertEqual(generations.count, 1)
            XCTAssertEqual(generations.first?.generationID, generation.generationID)
            XCTAssertEqual(generations.first?.reconciliationToken, generation.reconciliationToken)
            XCTAssertEqual(generations.first?.status, .active)
            await store.close()
            let reopened = try EvidenceStore(url: fixture.databaseURL)
            let replay = try await reopened.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"), metadata: next, scope: scope, trigger: .scheduled)
            XCTAssertTrue(replay.events.isEmpty)
            XCTAssertEqual(replay.currentFiles.map(\.objectID), ["new"])
            await reopened.close()
        }
    }

    func testLegacyMixedRootsPublishesHealthyChangesAndRetainsFailedRootUncertainty() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-both", roots: ["/watch", "/denied"])
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [
                Self.file("healthy", path: "/watch/A", bytes: 3),
                Self.file("unavailable", path: "/denied/B", root: "/denied", bytes: 9),
            ]), scope: scope, trigger: .scheduled)
        let next = MetadataSnapshot(observationID: "O2", scopeVersionID: scope.scopeVersionID,
            observedAt: Self.start.addingTimeInterval(10),
            entries: ["/watch/A": Self.file("healthy", path: "/watch/A", bytes: 8)],
            rootCoverage: [.init(rootPath: "/watch", coverage: .complete),
                           .init(rootPath: "/denied", coverage: .failed, limitations: ["permission denied"])],
            limitations: ["permission denied"])
        let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"), metadata: next, scope: scope, trigger: .scheduled)
        XCTAssertEqual(result.events.map(\.operation), [.modify])
        XCTAssertEqual(result.events.first?.logicalDelta, 5)
        let unavailable = try XCTUnwrap(result.currentFiles.first { $0.objectID == "unavailable" })
        XCTAssertEqual(unavailable.presence, .unknown)
        XCTAssertEqual(unavailable.stateAsOfObservationID, "O1")
        XCTAssertEqual(unavailable.observedAt, Self.start)
        XCTAssertFalse(unavailable.actionable)
        await store.close()
    }

    func testLegacyScopeMoveDoesNotInferRenameAndScopeExitDoesNotRepeat() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let firstScope = Self.scope(id: "scope-first", roots: ["/watch"])
        let nextScope = Self.scope(id: "scope-next", roots: ["/other"])
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
            metadata: Self.metadata(id: "O1", scope: firstScope, files: [
                Self.file("same", path: "/watch/A", bytes: 3), Self.file("left", path: "/watch/B", bytes: 9),
            ]), scope: firstScope, trigger: .scheduled)
        for number in 2...3 {
            let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V\(number)"),
                metadata: Self.metadata(id: "O\(number)", scope: nextScope, files: [
                    Self.file("same", path: "/other/A", root: "/other", bytes: 3),
                ], seconds: number), scope: nextScope, trigger: .scheduled)
            XCTAssertEqual(result.events.map(\.operation), number == 2 ? [.scopeExit] : [])
            XCTAssertEqual(result.currentFiles.first { $0.objectID == "left" }?.presence, .outOfScope)
        }
        await store.close()
    }

    func testLegacyResultPreservesFullArrayContractAboveGenerationInlineLimit() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        let files = (0..<2_053).map { Self.file("object-\($0)", path: "/watch/\($0)", bytes: 1) }
        let result = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: files), scope: scope, trigger: .scheduled)
        XCTAssertEqual(result.currentFiles.count, files.count)
        XCTAssertEqual(result.events.count, files.count)
        XCTAssertEqual(Set(result.currentFiles.map(\.objectID)).count, files.count)
        await store.close()
    }

    func testLegacyPartialCoverageCannotCloseAnExistingEventGap() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: []), scope: scope, trigger: .scheduled, eventGap: true)
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [], coverage: .partial, seconds: 10), scope: scope, trigger: .scheduled)
        let partialGaps = try await store.coverageGaps()
        XCTAssertNil(try XCTUnwrap(partialGaps.first { $0.reason == "event-drop" }).endedAt)
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V3"),
            metadata: Self.metadata(id: "O3", scope: scope, files: [], seconds: 20), scope: scope, trigger: .scheduled)
        let completeGaps = try await store.coverageGaps()
        XCTAssertEqual(try XCTUnwrap(completeGaps.first { $0.reason == "event-drop" }).endedAt, Self.start.addingTimeInterval(20))
        await store.close()
    }

    func testLegacyCompleteSnapshotCannotResolveDurableDirtyEvidence() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: []), scope: scope, trigger: .scheduled, eventGap: true)
        try await store.recordReconciliationInvalidation(rootPath: "/watch", at: Self.start.addingTimeInterval(1))
        _ = try await store.recordObservation(snapshot: Self.volumeSnapshot(id: "V2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [], seconds: 10), scope: scope, trigger: .scheduled)
        let gaps = try await store.coverageGaps()
        XCTAssertNil(try XCTUnwrap(gaps.first { $0.reason == "event-drop" }).endedAt)
        let pending = try await store.hasPendingReconciliation()
        XCTAssertTrue(pending)
        let db = try SQLiteConnection(url: fixture.databaseURL)
        XCTAssertEqual(try db.scalarInt("SELECT event_gap FROM observation_runs WHERE observation_id = 'O2'"), 1)
        db.close()
        await store.close()
    }

    private static let start = Date(timeIntervalSince1970: 2_000_000_000)

    private static func scope(id: String, roots: [String]) -> EvidenceScopeVersion {
        EvidenceScopeVersion(
            scopeVersionID: id,
            effectiveAt: start,
            rootPaths: roots,
            excludedPaths: [],
            maximumEntries: 10_000,
            maximumDepth: 10
        )
    }

    private static func file(
        _ id: String,
        path: String,
        root: String = "/watch",
        bytes: Int64,
        linkCount: Int = 1
    ) -> FileMetadata {
        FileMetadata(
            objectID: id,
            identityMethod: .volumeFileGeneration,
            rootPath: root,
            path: path,
            logicalBytes: bytes,
            allocatedBytes: bytes,
            modifiedAt: start.addingTimeInterval(Double(bytes)),
            linkCount: linkCount
        )
    }

    private static func metadata(
        id: String,
        scope: EvidenceScopeVersion,
        files: [FileMetadata],
        coverage: ObservationCoverage = .complete,
        limitations: [String] = [],
        seconds: Int = 0
    ) -> MetadataSnapshot {
        MetadataSnapshot(
            observationID: id,
            scopeVersionID: scope.scopeVersionID,
            observedAt: start.addingTimeInterval(Double(seconds)),
            entries: Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) }),
            rootCoverage: scope.rootPaths.map { .init(rootPath: $0, coverage: coverage, limitations: limitations) },
            limitations: limitations
        )
    }

    private static func volumeSnapshot(id: String) -> StorageSnapshot {
        StorageSnapshot(
            snapshotID: id,
            observedAt: "2033-05-18T03:33:20.000Z",
            volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)]
        )
    }
}

private enum LegacyCheckpointFailure: Error { case injected }

private final class LegacyCheckpointArm: @unchecked Sendable {
    private let lock = NSLock()
    private var point: String?

    func set(_ value: String?) { lock.withLock { point = value } }
    func check(_ value: String) throws {
        if lock.withLock({ point == value }) { throw LegacyCheckpointFailure.injected }
    }
}

private final class LifecycleFixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "evidence.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
