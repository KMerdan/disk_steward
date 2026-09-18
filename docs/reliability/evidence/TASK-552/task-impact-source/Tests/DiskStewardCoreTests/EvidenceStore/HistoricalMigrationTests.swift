import Foundation
import XCTest
@testable import DiskStewardCore

final class HistoricalMigrationTests: XCTestCase, @unchecked Sendable {
    func testFirstNewChangeAfterUpgradeDoesNotPromoteLegacyCurrentTimeToMeasuredLowerBound() async throws {
        for version in [5, 6] {
            let fixture = try HistoricalDatabaseFixture(version: version, progress: .traversing)
            var store = try EvidenceStore(url: fixture.url, availableCapacitySource: { _ in Int64.max })
            for index in 1...2 {
                let sample = Date(timeIntervalSince1970: Double(2000 + index * 100))
                let publication = sample.addingTimeInterval(50)
                let path = "/historical/watch/kept"
                let file = FileMetadata(objectID: "legacy-kept", rootPath: "/historical/watch", path: path,
                    logicalBytes: Int64(42 + index), allocatedBytes: 4096, modifiedAt: nil, observedAt: sample)
                let commit = try await store.recordObservation(
                    snapshot: .init(snapshotID: "new-\(index)", observedAt: EvidenceTimestamp.format(publication),
                        volumes: [.init(mountPath: "/", totalBytes: 1000, availableBytes: 500, isInternal: true, isReadOnly: false)]),
                    metadata: .init(observationID: "new-\(index)", scopeVersionID: fixture.scope.scopeVersionID,
                        observedAt: publication, entries: [path: file], rootCoverage: [.init(rootPath: "/historical/watch", coverage: .complete)], limitations: []),
                    scope: fixture.scope, trigger: .scheduled)
                let timing = try XCTUnwrap(commit.events.first?.timing)
                XCTAssertEqual(commit.events.first?.operation, .modify)
                XCTAssertEqual(timing.occurredStart, index == 1 ? nil : Date(timeIntervalSince1970: 2100))
                XCTAssertEqual(timing.occurredEnd, sample)
                XCTAssertEqual(timing.detectedAt, publication)
            }
            await store.close()
            store = try EvidenceStore(url: fixture.url)
            let events = try await store.events(from: Date(timeIntervalSince1970: 2000), through: Date(timeIntervalSince1970: 2500))
            XCTAssertEqual(events.count, 2)
            XCTAssertNil(events.first?.timing?.occurredStart)
            XCTAssertEqual(events.last?.timing?.occurredStart, Date(timeIntervalSince1970: 2100))
            let exported = try await EvidenceBundleExporter(identifierSource: { "migration-timing" }).export(
                store: store, options: .init(from: Date(timeIntervalSince1970: 2000), through: Date(timeIntervalSince1970: 2500), pathDetail: .basename),
                to: fixture.directory.appending(path: "exports"))
            let data = try ZlibCodec.decompress(Data(contentsOf: exported.bundleURL.appending(path: "events.jsonl.zlib")))
            let rows = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            XCTAssertEqual(rows.count, 2)
            let timing = try XCTUnwrap(rows.first?["timing"] as? [String: Any])
            XCTAssertTrue(timing["occurred_start"] is NSNull)
            XCTAssertEqual(timing["occurred_end"] as? String, EvidenceTimestamp.format(Date(timeIntervalSince1970: 2100)))
            await store.close()
        }
    }

    func testLegacyAliasBindingCannotSupplyMeasuredLowerBoundAfterFreshCanonicalSample() async throws {
        let fixture = try HistoricalDatabaseFixture(version: 6, progress: .traversing)
        let old = try SQLiteConnection(url: fixture.url)
        try old.execute("INSERT INTO path_bindings VALUES ('legacy-alias', 'legacy-kept', '/historical/watch/alias', 1000, NULL, 'baseline', NULL, 'inferred')")
        old.close()
        let store = try EvidenceStore(url: fixture.url, availableCapacitySource: { _ in Int64.max })
        for index in 1...2 {
            let publication = Date(timeIntervalSince1970: Double(2000 + index * 100))
            let files: [FileMetadata] = [
                .init(objectID: "legacy-kept", rootPath: "/historical/watch", path: "/historical/watch/kept",
                    logicalBytes: 42, allocatedBytes: 4096, modifiedAt: nil, linkCount: index == 1 ? 2 : 1,
                    observedAt: publication.addingTimeInterval(-10)),
                .init(objectID: index == 1 ? "legacy-kept" : "replacement", rootPath: "/historical/watch", path: "/historical/watch/alias",
                    logicalBytes: 42, allocatedBytes: 4096, modifiedAt: nil, linkCount: index == 1 ? 2 : 1,
                    observedAt: publication.addingTimeInterval(-20)),
            ]
            let commit = try await store.recordObservation(
                snapshot: .init(snapshotID: "alias-\(index)", observedAt: EvidenceTimestamp.format(publication),
                    volumes: [.init(mountPath: "/", totalBytes: 1000, availableBytes: 500, isInternal: true, isReadOnly: false)]),
                metadata: .init(observationID: "alias-\(index)", scopeVersionID: fixture.scope.scopeVersionID,
                    observedAt: publication, entries: Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) }),
                    rootCoverage: [.init(rootPath: "/historical/watch", coverage: .complete)], limitations: []),
                scope: fixture.scope, trigger: .scheduled)
            if index == 2 {
                let replacement = try XCTUnwrap(commit.events.first { $0.operation == .replace })
                XCTAssertNil(replacement.timing?.occurredStart)
                XCTAssertEqual(replacement.timing?.occurredEnd, publication.addingTimeInterval(-20))
            }
        }
        await store.close()
    }

    func testPreviewV10WithdrawsUnsupportedTimingWithoutErasingLegacyDates() async throws {
        let fixture = try HistoricalDatabaseFixture(version: 6, progress: .traversing)
        let initial = try EvidenceStore(url: fixture.url, availableCapacitySource: { _ in Int64.max })
        await initial.close()
        // Recreate the exact preview-v10 shape and its unsupported assertion.
        let old = try SQLiteConnection(url: fixture.url)
        // Opening a current store above also installed schema 12. Restore the
        // unrelated provenance table from frozen historical DDL, not a hybrid
        // v10 fixture with a nullable lower bound and newer timing columns.
        XCTAssertEqual(try old.scalarInt("SELECT COUNT(*) FROM provenance_claims"), 0)
        let provenanceStart = try XCTUnwrap(HistoricalEvidenceSchema.v5.range(of: "CREATE TABLE provenance_claims ("))
        let provenanceEnd = try XCTUnwrap(HistoricalEvidenceSchema.v5.range(of: "CREATE TABLE agent_sessions ("))
        try old.execute("DROP TABLE provenance_claims")
        try old.execute(String(HistoricalEvidenceSchema.v5[provenanceStart.lowerBound..<provenanceEnd.lowerBound]))
        XCTAssertEqual(try old.scalarInt("SELECT COUNT(*) FROM pragma_table_info('provenance_claims')"), 11)
        XCTAssertEqual(try old.scalarInt("SELECT \"notnull\" FROM pragma_table_info('provenance_claims') WHERE name = 'occurred_start'"), 1)
        XCTAssertEqual(try old.scalarInt("SELECT COUNT(*) FROM pragma_table_info('provenance_claims') WHERE name IN ('timing_version', 'legacy_occurred_start')"), 0)
        try old.execute("""
            ALTER TABLE current_file_state DROP COLUMN timing_verified;
            ALTER TABLE path_bindings DROP COLUMN timing_verified;
            UPDATE change_events SET timing_version = 1;
            PRAGMA user_version=10;
            """)
        old.close()
        let reopened = try EvidenceStore(url: fixture.url, availableCapacitySource: { _ in Int64.max })
        let events = try await reopened.events(from: Date(timeIntervalSince1970: 0), through: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.timing)
        let db = try SQLiteConnection(url: fixture.url)
        XCTAssertEqual(try db.scalarInt("SELECT occurred_end FROM change_events"), 1000)
        XCTAssertEqual(try db.scalarInt("SELECT detected_at FROM change_events"), 1000)
        XCTAssertEqual(try db.scalarInt("SELECT timing_version FROM change_events"), 0)
        XCTAssertEqual(try db.scalarInt("SELECT timing_verified FROM current_file_state"), 0)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
        db.close()
        await reopened.close()
    }

    func testHistoricalOccurrenceBoundsMigrateWithoutInventingLowerEvidence() async throws {
        for version in [5, 6] {
            let fixture = try HistoricalDatabaseFixture(version: version, progress: .traversing)
            let original = try SQLiteConnection(url: fixture.url)
            try original.execute("""
                INSERT INTO events VALUES ('legacy-prior', 1100, 'modify', '/historical/watch/kept', 1, 1, 'watched-root', 'inferred', 0, 0);
                INSERT INTO change_events VALUES ('legacy-prior', 'modify', 'legacy-kept', 'legacy-committed', 'legacy-committed', '/historical/watch/kept', '/historical/watch/kept', 1, 1, 1200, 1000, 1100, 'complete');
                INSERT INTO events VALUES ('legacy-inverted', 900, 'modify', '/historical/watch/kept', 1, 1, 'watched-root', 'inferred', 0, 0);
                INSERT INTO change_events VALUES ('legacy-inverted', 'modify', 'legacy-kept', 'legacy-committed', 'legacy-committed', '/historical/watch/kept', '/historical/watch/kept', 1, 1, 1200, 1000, 900, 'complete');
                """)
            original.close()
            for _ in 0..<2 {
                let store = try EvidenceStore(url: fixture.url, availableCapacitySource: { _ in Int64.max })
                let db = try SQLiteConnection(url: fixture.url)
                let events = try await store.events(from: Date(timeIntervalSince1970: 0), through: Date(timeIntervalSince1970: 2000))
                XCTAssertEqual(events.count, 3)
                XCTAssertTrue(events.allSatisfy { $0.timing == nil }, "Legacy bounds are not verified sample times")
                XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM change_events WHERE timing_version = 0"), 3)
                XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM change_events"), 3)
                XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM change_events WHERE event_id IN ('legacy-event', 'legacy-inverted') AND occurred_start IS NULL"), 2)
                XCTAssertEqual(try db.scalarInt("SELECT occurred_start FROM change_events WHERE event_id = 'legacy-prior'"), 1000)
                XCTAssertEqual(try db.scalarInt("SELECT occurred_end FROM change_events WHERE event_id = 'legacy-inverted'"), 900)
                XCTAssertEqual(try db.scalarInt("SELECT detected_at FROM change_events WHERE event_id = 'legacy-inverted'"), 1200)
                XCTAssertEqual(try db.scalarInt("SELECT logical_delta FROM change_events WHERE event_id = 'legacy-inverted'"), 1)
                XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
                XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'change_events_object_time'"), 1)
                XCTAssertThrowsError(try db.execute("UPDATE change_events SET occurred_start = 2000 WHERE event_id = 'legacy-prior'"))
                db.close()
                await store.close()
            }
            let db = try SQLiteConnection(url: fixture.url)
            try db.execute("PRAGMA foreign_keys=ON")
            try db.execute("DELETE FROM events WHERE event_id = 'legacy-prior'")
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM change_events"), 2)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM current_file_state"), 1)
            db.close()
        }
    }

    func testActualV5AndV6BackfillAcrossBatchBoundaryWithoutReplayingUnprovenMembership() async throws {
        for version in [5, 6] {
            for progress in HistoricalDatabaseFixture.Progress.allCases {
                let fixture = try HistoricalDatabaseFixture(version: version, progress: progress)
                try fixture.assertHistoricalShape(version)
                let store = try EvidenceStore(url: fixture.url, availableCapacitySource: { _ in Int64.max })
                try await assertCommittedTruth(store)
                let inspection = try SQLiteConnection(url: fixture.url)
                XCTAssertEqual(try inspection.scalarInt("PRAGMA user_version"), 12)
                XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM file_state_observations WHERE observed_at IS NOT NULL"), 0,
                    "Historical sample times are unknown; migration must not backdate them to publication.")
                XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM scan_generation_entries"), 513)
                XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM scan_generation_entries WHERE object_id IS NULL OR root_path != '/historical/watch'"), 0)
                XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM scan_generation_entries WHERE pass_id IS NOT NULL OR observed_at IS NOT NULL"), 0,
                    "Migration must not invent producing passes or observation times for historical payloads.")
                XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
                inspection.close()

                let fresh = try await store.beginOrResumeScanGeneration(scope: fixture.scope, at: Date(timeIntervalSince1970: 2000))
                XCTAssertNotEqual(fresh.generationID, "legacy-active")
                let history = try await store.scanGenerations()
                XCTAssertEqual(history.first { $0.generationID == "legacy-active" }?.status, .abandoned)
                try await assertCommittedTruth(store)
                await store.close()
                let afterAbandon = try SQLiteConnection(url: fixture.url)
                XCTAssertEqual(try afterAbandon.scalarInt("SELECT COUNT(*) FROM scan_generation_entries"), 0)
                XCTAssertEqual(try afterAbandon.scalarInt("SELECT COUNT(*) FROM scan_directory_passes"), 0)
                afterAbandon.close()

                let reopened = try EvidenceStore(url: fixture.url)
                let resumed = try await reopened.beginOrResumeScanGeneration(scope: fixture.scope, at: Date(timeIntervalSince1970: 2001))
                XCTAssertEqual(resumed.generationID, fresh.generationID, "Only the new proven-format active traversal is resumable.")
                try await assertCommittedTruth(reopened)
                await reopened.close()
            }
        }
    }

    func testActualHistoricalSchemasRecoverAtEveryAtomicMigrationCheckpoint() async throws {
        for version in [5, 6] {
            for interruptedAt in ["after-consistent-copy", "after-shadow-validation", "before-atomic-switch", "after-atomic-switch"] {
                let fixture = try HistoricalDatabaseFixture(version: version, progress: .completedPayload)
                XCTAssertThrowsError(try EvidenceStore(url: fixture.url, migrationCheckpoint: { checkpoint in
                    if checkpoint == interruptedAt { throw HistoricalMigrationFailure.injected }
                }, availableCapacitySource: { _ in Int64.max })) { error in
                    XCTAssertEqual(error as? HistoricalMigrationFailure, .injected)
                }
                let inspection = try SQLiteConnection(url: fixture.url)
                XCTAssertEqual(try inspection.scalarInt("PRAGMA user_version"), interruptedAt == "after-atomic-switch" ? 12 : Int64(version))
                XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM current_file_state"), 1)
                XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM scan_generation_entries"), 513)
                inspection.close()
                for _ in 0 ..< 2 {
                    let recovered = try EvidenceStore(url: fixture.url, availableCapacitySource: { _ in Int64.max })
                    try await assertCommittedTruth(recovered)
                    let diagnostics = try await recovered.diagnostics()
                    XCTAssertEqual(diagnostics.schemaVersion, 12)
                    XCTAssertEqual(diagnostics.integrity, "ok")
                    await recovered.close()
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathExtension("migration").path))
            }
        }
    }

    func testActualHistoricalSchemasRemainIntactWhenMigrationHasNoHeadroom() throws {
        for version in [5, 6] {
            let fixture = try HistoricalDatabaseFixture(version: version, progress: .traversing)
            XCTAssertThrowsError(try EvidenceStore(url: fixture.url, availableCapacitySource: { _ in 1 })) { error in
                guard case EvidenceStoreError.migrationInsufficientSpace = error else {
                    return XCTFail("Expected capacity refusal, got \(error)")
                }
            }
            try fixture.assertHistoricalShape(version)
            let inspection = try SQLiteConnection(url: fixture.url)
            XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM scan_generation_entries"), 513)
            XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM current_file_state"), 1)
            XCTAssertEqual(try inspection.scalarText("PRAGMA quick_check"), "ok")
            inspection.close()
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathExtension("migration").path))
        }
    }

    private func assertCommittedTruth(_ store: EvidenceStore) async throws {
        let current = try await store.currentFiles(includeNonActionable: true)
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.objectID, "legacy-kept")
        XCTAssertEqual(current.first?.path, "/historical/watch/kept")
        XCTAssertEqual(current.first?.presence, .present)
        XCTAssertEqual(current.first?.logicalBytes, 42)
        XCTAssertEqual(current.first?.observedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(current.first?.stateAsOfObservationID, "legacy-committed")
        let count = try await store.eventCount()
        XCTAssertEqual(count, 1)
        let contains = try await store.containsEvent(id: "legacy-event")
        XCTAssertTrue(contains)
    }
}

private enum HistoricalMigrationFailure: Error, Equatable { case injected }

private final class HistoricalDatabaseFixture {
    enum Progress: CaseIterable { case traversing, completedRoot, completedPayload }
    let directory: URL
    let url: URL
    let scope = EvidenceScopeVersion(scopeVersionID: "legacy-scope", effectiveAt: Date(timeIntervalSince1970: 1000),
        rootPaths: ["/historical/watch"], excludedPaths: [], maximumEntries: 10, maximumDepth: 8)

    init(version: Int, progress: Progress) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "historical-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        url = directory.appending(path: "evidence.sqlite")
        let connection = try SQLiteConnection(url: url)
        defer { connection.close() }
        try connection.execute("PRAGMA foreign_keys=ON")
        try connection.execute(HistoricalEvidenceSchema.v5)
        if version == 6 { try connection.execute(HistoricalEvidenceSchema.v6Additions) }
        try connection.transaction {
            try connection.execute("""
                INSERT INTO scope_versions VALUES ('legacy-scope', 1000, '["/historical/watch"]', '[]', 10, 8);
                INSERT INTO observation_runs VALUES ('legacy-committed', 'legacy-scope', 'startup', 1000, 1000, 'complete', 0);
                INSERT INTO observation_roots VALUES ('legacy-committed', '/historical/watch', 'complete', '[]');
                INSERT INTO file_objects VALUES ('legacy-kept', 'volume-file', 1000, 1000, 'present');
                INSERT INTO path_bindings VALUES ('legacy-binding', 'legacy-kept', '/historical/watch/kept', 1000, NULL, 'baseline', NULL, 'inferred');
                INSERT INTO current_file_state VALUES ('legacy-kept', 'volume-file', '/historical/watch/kept', '/historical/watch', 'legacy-scope', 42, 4096, NULL, 'present', 'legacy-committed', 1000, 1);
                INSERT INTO file_state_observations VALUES ('legacy-committed', 'legacy-kept', '/historical/watch/kept', '/historical/watch', 42, 4096, NULL, 'present', 'inferred');
                INSERT INTO events VALUES ('legacy-event', 1000, 'baseline', '/historical/watch/kept', 0, 0, 'watched-root', 'inferred', 0, 0);
                INSERT INTO change_events VALUES ('legacy-event', 'baseline', 'legacy-kept', NULL, 'legacy-committed', NULL, '/historical/watch/kept', 0, 0, 1000, 1000, 1000, 'complete');
                """)
            let date = Date(timeIntervalSince1970: 1100)
            let generation = MetadataScanGeneration(generationID: "legacy-active", scopeVersionID: scope.scopeVersionID,
                rootPaths: scope.rootPaths, excludedPaths: [], status: progress == .completedPayload ? .completed : .active,
                roots: [.init(rootPath: "/historical/watch", status: progress == .traversing ? .active : .completed,
                    frontier: progress == .traversing ? [.init(directoryPath: "/historical/watch", depth: 0, afterName: "pending-512")] : [])],
                processedEntryCount: 513, stagedFileCount: 513, startedAt: date, updatedAt: date,
                completedAt: progress == .completedPayload ? date : nil)
            var legacyProgress = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(generation)) as? [String: Any])
            legacyProgress.removeValue(forKey: "passProvenanceVersion")
            legacyProgress.removeValue(forKey: "reconciliationToken")
            try connection.withStatement("INSERT INTO scan_generations VALUES ('legacy-active', 'legacy-scope', 'active', 1100, 1100, NULL, 513, 513, ?)") { statement in
                try connection.bind(JSONSerialization.data(withJSONObject: legacyProgress), at: 1, in: statement)
                try connection.stepDone(statement)
            }
            for index in 0 ..< 513 {
                let path = "/historical/watch/pending-\(String(format: "%03d", index))"
                // Historical payload: no sampled timestamp or producing-pass ID.
                let payload: [String: Any] = ["objectID": "historical-\(index)", "identityMethod": "volume-file",
                    "rootPath": "/historical/watch", "path": path, "logicalBytes": 10, "allocatedBytes": 4096, "linkCount": 1]
                try connection.withStatement("INSERT INTO scan_generation_entries (generation_id, path, payload) VALUES ('legacy-active', ?, ?)") { statement in
                    try connection.bind(path, at: 1, in: statement)
                    try connection.bind(JSONSerialization.data(withJSONObject: payload), at: 2, in: statement)
                    try connection.stepDone(statement)
                }
            }
        }
    }

    func assertHistoricalShape(_ version: Int) throws {
        let inspection = try SQLiteConnection(url: url)
        defer { inspection.close() }
        XCTAssertEqual(try inspection.scalarInt("PRAGMA user_version"), Int64(version))
        XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM pragma_table_info('scan_generation_entries')"), version == 5 ? 3 : 10)
        XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name = 'scan_directory_passes'"), 0)
        if version == 6 {
            XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM scan_generation_entries WHERE object_id IS NULL"), 513)
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
