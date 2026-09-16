import CryptoKit
import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardCore

final class EvidenceBundleExporterTests: XCTestCase, @unchecked Sendable {
    func testGoldenBundleIsDeterministicSchemaValidAndIntegrityVerifiable() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        try await seedGolden(store)
        let exporter = EvidenceBundleExporter(
            productVersion: "test",
            identifierSource: { "golden-001" },
            dateSource: { Self.base.addingTimeInterval(300) }
        )

        let result = try await exporter.export(
            store: store,
            options: .init(from: Self.base, through: Self.base.addingTimeInterval(120), pathDetail: .basename),
            to: fixture.exports
        )

        XCTAssertEqual(result.manifest.files.map(\.path), [
            "codex-brief.md", "summary.json", "rollups.json", "events.jsonl.zlib", "snapshots.json",
            "current-state.json", "provenance.json", "sessions.json", "coverage.json", "lifecycle.json", "integrity.json",
        ])
        XCTAssertEqual(try schemaErrors(file: "manifest.json", schema: "export-manifest-v1", in: result.bundleURL), [])
        try verifyHashes(result)
        let events = try decodedEventObjects(in: result.bundleURL)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.flatMap { SnapshotJSONSchemaValidator().validate(instance: $0, schema: try! SnapshotJSONSchemaValidator.loadSchema(named: "evidence-event-v1")) }, [])
        let brief = try String(contentsOf: result.bundleURL.appending(path: "codex-brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("## Scope and evidence age"))
        XCTAssertTrue(brief.contains("## Current consumers"))
        XCTAssertTrue(brief.contains("## Recent growth"))
        XCTAssertTrue(brief.contains("## Cleanup-review leads"))
        XCTAssertTrue(brief.contains("Whole-volume capacity does not imply whole-disk file"))
        XCTAssertFalse(result.manifest.privacy.containsFileContents)
        XCTAssertFalse(result.manifest.privacy.containsEnvironment)
        await store.close()
    }

    func testActionableBundleDisclosesRootsPartialCoverageCurrentConsumersAndUnavailableGrowth() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = EvidenceScopeVersion(
            scopeVersionID: "scope-actionable",
            effectiveAt: Self.base,
            rootPaths: ["/watched"],
            excludedPaths: ["/watched/private"],
            maximumEntries: 2,
            maximumDepth: 10
        )
        let metadata = MetadataSnapshot(
            observationID: "partial-actionable",
            scopeVersionID: scope.scopeVersionID,
            observedAt: Self.base,
            entries: [
                "/watched/cache/large.bin": .init(
                    objectID: "large",
                    identityMethod: .volumeFileGeneration,
                    rootPath: "/watched",
                    path: "/watched/cache/large.bin",
                    logicalBytes: 4_000,
                    allocatedBytes: 4_096,
                    modifiedAt: Self.base
                ),
                "/watched/cache/other.bin": .init(
                    objectID: "other",
                    identityMethod: .volumeFileGeneration,
                    rootPath: "/watched",
                    path: "/watched/cache/other.bin",
                    logicalBytes: 2_000,
                    allocatedBytes: 2_048,
                    modifiedAt: Self.base
                ),
            ],
            rootCoverage: [.init(
                rootPath: "/watched",
                coverage: .partial,
                limitations: ["Detailed scan stopped at the configured 2-entry limit."]
            )],
            limitations: ["Detailed scan stopped at the configured 2-entry limit."]
        )
        _ = try await store.recordObservation(
            snapshot: StorageSnapshot(
                snapshotID: "capacity-actionable",
                observedAt: "2033-05-18T03:33:20.000Z",
                volumes: [.init(mountPath: "/", totalBytes: 10_000, availableBytes: 4_000, isInternal: true, isReadOnly: false)]
            ),
            metadata: metadata,
            scope: scope,
            trigger: .manual
        )

        let result = try await EvidenceBundleExporter(identifierSource: { "actionable" }, dateSource: { Self.base })
            .export(
                store: store,
                options: .init(from: Self.base.addingTimeInterval(-1), through: Self.base.addingTimeInterval(1)),
                to: fixture.exports
            )

        let summary = try jsonObject(at: result.bundleURL.appending(path: "summary.json"))
        XCTAssertEqual(summary["volume_capacity_scope"] as? String, "whole-volume-capacity")
        XCTAssertEqual(summary["file_detail_roots"] as? [String], ["/watched"])
        XCTAssertEqual(summary["exclusions"] as? [String], ["/watched/private"])
        XCTAssertEqual(summary["detail_coverage"] as? String, "partial")
        XCTAssertEqual(summary["growth_assessment"] as? String, "unavailable")
        XCTAssertEqual(summary["current_state_count"] as? Int, 2)
        XCTAssertEqual((summary["largest_current_files"] as? [[String: Any]])?.first?["path"] as? String, "/watched/cache/large.bin")
        XCTAssertEqual((summary["largest_current_directories"] as? [[String: Any]])?.first?["path"] as? String, "/watched/cache")

        let coverage = try jsonObject(at: result.bundleURL.appending(path: "coverage.json"))
        XCTAssertEqual(coverage["file_detail_roots"] as? [String], ["/watched"])
        XCTAssertEqual(coverage["detail_coverage"] as? String, "partial")
        XCTAssertEqual(coverage["open_gap_count"] as? Int, 1)
        XCTAssertNotNil(coverage["state_as_of"])

        let roles = Set(result.manifest.files.map(\.role))
        XCTAssertTrue(["codex-brief", "summary", "events", "snapshot", "current-state", "provenance", "agent-sessions", "coverage", "lifecycle", "integrity"].allSatisfy(roles.contains))
        XCTAssertTrue(result.manifest.limitations.contains { $0.contains("File-detail coverage is partial") })
        XCTAssertTrue(result.manifest.limitations.contains { $0.contains("growth is unavailable") })

        let brief = try String(contentsOf: result.bundleURL.appending(path: "codex-brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("`/watched`"))
        XCTAssertTrue(brief.contains("`/watched/cache`"))
        XCTAssertTrue(brief.contains("`/watched/cache/large.bin`"))
        XCTAssertTrue(brief.contains("File-detail growth is unavailable"))
        try verifyHashes(result)
        await store.close()
    }

    func testExportDuringActiveGenerationDisclosesProgressAndKeepsPriorStateStale() async throws {
        let fixture = try Fixture()
        let watched = fixture.directory.appending(path: "watched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: watched.appending(path: "A"))
        try Data(repeating: 2, count: 20).write(to: watched.appending(path: "B"))
        let policy = MonitoringPolicy(watchedRoots: [watched], maximumEntries: 1, maximumDepth: 8)
        let scope = policy.scopeVersion(at: Self.base)
        let store = try EvidenceStore(url: fixture.databaseURL)
        let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: Self.base)
        let slice = DirectoryMetadataScanner().scanSlice(
            policy: policy,
            generation: generation,
            at: Self.base.addingTimeInterval(1)
        )
        let staged = try await store.recordScanSlice(
            snapshot: StorageSnapshot(
                snapshotID: "active-generation-capacity",
                observedAt: "2033-05-18T03:33:21.000Z",
                volumes: [.init(mountPath: "/", totalBytes: 10_000, availableBytes: 5_000, isInternal: true, isReadOnly: false)]
            ),
            slice: slice,
            scope: scope,
            trigger: .startup
        )
        XCTAssertNil(staged.observation)

        let result = try await EvidenceBundleExporter(
            identifierSource: { "active-generation" },
            dateSource: { Self.base.addingTimeInterval(2) }
        ).export(
            store: store,
            options: .init(from: Self.base.addingTimeInterval(-1), through: Self.base.addingTimeInterval(3)),
            to: fixture.exports
        )

        let coverage = try jsonObject(at: result.bundleURL.appending(path: "coverage.json"))
        XCTAssertEqual(coverage["detail_coverage"] as? String, "partial")
        XCTAssertEqual(coverage["file_detail_roots"] as? [String], [watched.path])
        let active = try XCTUnwrap(coverage["active_generation"] as? [String: Any])
        XCTAssertEqual(active["generation_id"] as? String, generation.generationID)
        XCTAssertEqual(active["processed_entry_count"] as? Int, 1)
        XCTAssertEqual(active["staged_file_count"] as? Int, 1)
        XCTAssertEqual(active["completed_root_count"] as? Int, 0)
        XCTAssertEqual(active["root_count"] as? Int, 1)

        let summary = try jsonObject(at: result.bundleURL.appending(path: "summary.json"))
        XCTAssertEqual(summary["active_generation_id"] as? String, generation.generationID)
        XCTAssertEqual(summary["scan_processed_entry_count"] as? Int, 1)
        XCTAssertEqual(summary["current_state_count"] as? Int, 0)
        XCTAssertTrue(result.manifest.limitations.contains { $0.contains("still active") && $0.contains("absence is not reconciled") })
        let brief = try String(contentsOf: result.bundleURL.appending(path: "codex-brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("Active scan generation: \(generation.generationID)"))
        XCTAssertTrue(brief.contains("Root progress: 0/1"))
        XCTAssertTrue(brief.contains("File-detail coverage: partial"))
        try verifyHashes(result)
        await store.close()
    }

    func testRequestedPeriodAndEventLimitAreExplicit() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        try await store.insert((0 ..< 4).map { index in
            Self.event(id: "bounded-\(index)", at: Self.base.addingTimeInterval(Double(index * 10)), path: "/tmp/\(index)")
        } + [Self.event(id: "outside", at: Self.base.addingTimeInterval(-10), path: "/tmp/outside")])

        let result = try await EvidenceBundleExporter(identifierSource: { "bounded" }, dateSource: { Self.base })
            .export(
                store: store,
                options: .init(from: Self.base, through: Self.base.addingTimeInterval(40), maximumEvents: 2),
                to: fixture.exports
            )

        XCTAssertEqual(try decodedEventObjects(in: result.bundleURL).count, 2)
        XCTAssertTrue(result.manifest.limitations.contains { $0.contains("truncated") && $0.contains("2-event") })
        let summary = try jsonObject(at: result.bundleURL.appending(path: "summary.json"))
        XCTAssertEqual(summary["raw_event_count"] as? Int, 2)
        await store.close()
    }

    func testLargeEventPayloadUsesStreamingCompressionAndRemainsVerifiable() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let eventCount = 10_000
        try await store.insert((0 ..< eventCount).map { index in
            Self.event(
                id: "streamed-\(index)",
                at: Self.base.addingTimeInterval(Double(index)),
                path: "/tmp/streamed/\(String(repeating: "segment-", count: 8))\(index)"
            )
        })

        let result = try await EvidenceBundleExporter(
            identifierSource: { "streamed-large" },
            dateSource: { Self.base.addingTimeInterval(Double(eventCount + 1)) }
        ).export(
            store: store,
            options: .init(
                from: Self.base,
                through: Self.base.addingTimeInterval(Double(eventCount)),
                maximumEvents: eventCount
            ),
            to: fixture.exports
        )

        XCTAssertEqual(try decodedEventObjects(in: result.bundleURL).count, eventCount)
        XCTAssertFalse(result.manifest.limitations.contains { $0.contains("Raw event detail was truncated") })
        try verifyHashes(result)
        await store.close()
    }

    func testConcurrentWritesProduceOneInternallyConsistentBackupView() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let exporter = EvidenceBundleExporter(identifierSource: { "concurrent" }, dateSource: { Self.base })
        let exportDirectory = fixture.exports

        let result = try await withThrowingTaskGroup(of: EvidenceBundleExportResult?.self) { group in
            group.addTask {
                for index in 0 ..< 200 {
                    try await store.insert(Self.event(
                        id: "concurrent-\(index)",
                        at: Self.base.addingTimeInterval(Double(index)),
                        path: "/tmp/concurrent-\(index)"
                    ))
                }
                return nil
            }
            group.addTask {
                try await exporter.export(
                    store: store,
                    options: .init(from: Self.base, through: Self.base.addingTimeInterval(500)),
                    to: exportDirectory
                )
            }
            var export: EvidenceBundleExportResult?
            for try await value in group where value != nil { export = value }
            return try XCTUnwrap(export)
        }

        let eventCount = try decodedEventObjects(in: result.bundleURL).count
        let summary = try jsonObject(at: result.bundleURL.appending(path: "summary.json"))
        XCTAssertEqual(summary["raw_event_count"] as? Int, eventCount)
        XCTAssertLessThanOrEqual(eventCount, 200)
        try verifyHashes(result)
        await store.close()
    }

    func testSecretLikePathFragmentsAreRedactedAndHashedModeIsOpaque() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let secret = "sk-supersecret123456"
        try await store.insert(Self.event(id: "secret", at: Self.base, path: "/tmp/\(secret)/token=visible/cache.bin"))

        let redacted = try await EvidenceBundleExporter(identifierSource: { "redacted" }, dateSource: { Self.base })
            .export(store: store, options: .init(from: Self.base, through: Self.base, pathDetail: .full), to: fixture.exports)
        let redactedText = String(decoding: try ZlibCodec.decompress(Data(contentsOf: redacted.bundleURL.appending(path: "events.jsonl.zlib"))), as: UTF8.self)
        XCTAssertFalse(redactedText.contains(secret))
        XCTAssertFalse(redactedText.contains("token=visible"))
        XCTAssertTrue(redactedText.contains("[REDACTED]"))

        let hashed = try await EvidenceBundleExporter(identifierSource: { "hashed" }, dateSource: { Self.base })
            .export(store: store, options: .init(from: Self.base, through: Self.base, pathDetail: .hashed), to: fixture.exports)
        let hashedObjects = try decodedEventObjects(in: hashed.bundleURL)
        XCTAssertTrue((hashedObjects.first?["path"] as? String)?.hasPrefix("sha256:") == true)
        XCTAssertFalse(String(describing: hashedObjects).contains("/tmp/"))
        await store.close()
    }

    func testRetainedRollupsRemainExportableAfterRawEventsExpire() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL, dateSource: { Self.base.addingTimeInterval(2 * 86_400) })
        try await store.insert(Self.event(id: "rollup", at: Self.base, path: "/tmp/old-cache", delta: 512))
        _ = try await store.applyRetention(try .init(
            rawEventDays: 1,
            hourlySummaryDays: 7,
            dailySummaryDays: 30,
            maxDatabaseBytes: 10 * 1_024 * 1_024,
            writeCoalesceSeconds: 15,
            preserveUnreviewedAnomalies: true
        ))

        let result = try await EvidenceBundleExporter(identifierSource: { "rollup" }, dateSource: { Self.base })
            .export(
                store: store,
                options: .init(from: Self.base, through: Self.base.addingTimeInterval(3_600), pathDetail: .basename),
                to: fixture.exports
            )
        let summary = try jsonObject(at: result.bundleURL.appending(path: "summary.json"))
        let rollups = try jsonObject(at: result.bundleURL.appending(path: "rollups.json"))

        XCTAssertEqual(summary["raw_event_count"] as? Int, 0)
        XCTAssertEqual(summary["hourly_summary_count"] as? Int, 1)
        XCTAssertEqual(summary["allocated_delta"] as? Int, 512)
        XCTAssertEqual((rollups["hourly"] as? [[String: Any]])?.first?["path"] as? String, "old-cache")
        XCTAssertTrue(result.manifest.limitations.contains { $0.contains("complete hour or day buckets") })
        await store.close()
    }

    func testManualExportInventoryRetainsOwnershipHashRangePrecisionAndMissingState() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL, dateSource: { Self.base.addingTimeInterval(600) })
        try await store.insert(Self.event(id: "inventory", at: Self.base, path: "/tmp/inventory.bin", delta: 128))
        let result = try await EvidenceBundleExporter(identifierSource: { "inventory" }, dateSource: { Self.base.addingTimeInterval(300) })
            .export(
                store: store,
                options: .init(from: Self.base.addingTimeInterval(-1), through: Self.base.addingTimeInterval(1), pathDetail: .hashed),
                to: fixture.exports
            )

        let availableRecords = try await store.exportRecords()
        let available = try XCTUnwrap(availableRecords.first)
        XCTAssertEqual(available.exportID, result.exportID)
        XCTAssertEqual(available.kind, .manual)
        XCTAssertEqual(available.status, .available)
        XCTAssertEqual(available.path, result.bundleURL.path)
        XCTAssertEqual(available.pathDetail, .hashed)
        XCTAssertEqual(available.precision, "event")
        XCTAssertEqual(available.actualFrom, Self.base)
        XCTAssertEqual(available.actualThrough, Self.base)
        XCTAssertNotNil(available.manifestSHA256)
        XCTAssertGreaterThan(available.bytes, 0)

        _ = try await store.applyRetention(try .init(), trigger: .manual)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.path), "Retention must never delete a user-owned export")
        try FileManager.default.removeItem(at: result.bundleURL)
        let missingRecords = try await store.exportRecords(refreshManualInventory: true)
        let missing = try XCTUnwrap(missingRecords.first)
        XCTAssertEqual(missing.status, .missing)
        XCTAssertEqual(missing.path, result.bundleURL.path)
        await store.close()
    }

    func testInvalidRangeAndExistingDestinationFailClosed() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let exporter = EvidenceBundleExporter(identifierSource: { "duplicate" }, dateSource: { Self.base })
        do {
            _ = try await exporter.export(
                store: store,
                options: .init(from: Self.base, through: Self.base.addingTimeInterval(-1)),
                to: fixture.exports
            )
            XCTFail("Expected invalid range")
        } catch {
            XCTAssertEqual(error as? EvidenceBundleExportError, .invalidRange)
        }
        _ = try await exporter.export(store: store, options: .init(from: Self.base, through: Self.base), to: fixture.exports)
        do {
            _ = try await exporter.export(store: store, options: .init(from: Self.base, through: Self.base), to: fixture.exports)
            XCTFail("Expected existing destination")
        } catch {
            XCTAssertEqual(error as? EvidenceBundleExportError, .destinationAlreadyExists)
        }
        await store.close()
    }

    private func seedGolden(_ store: EvidenceStore) async throws {
        try await store.insert([
            Self.event(id: "golden", at: Self.base.addingTimeInterval(60), path: "/fixture/cache.bin", delta: 4_096),
            Self.event(id: "outside", at: Self.base.addingTimeInterval(-60), path: "/fixture/outside.bin", delta: 9_999),
        ])
        try await store.recordSnapshot(
            StorageSnapshot(
                snapshotID: "golden-snapshot",
                observedAt: "2033-05-18T03:34:20.000Z",
                volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 400, isInternal: true, isReadOnly: false)],
                limitations: ["Fixture snapshot limitation."]
            ),
            observedAt: Self.base.addingTimeInterval(60)
        )
    }

    private func verifyHashes(_ result: EvidenceBundleExportResult) throws {
        for entry in result.manifest.files {
            let data = try Data(contentsOf: result.bundleURL.appending(path: entry.path))
            XCTAssertEqual(data.count, entry.bytes)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), entry.sha256)
        }
        let integrity = try jsonObject(at: result.bundleURL.appending(path: "integrity.json"))
        XCTAssertEqual(integrity["algorithm"] as? String, "sha256")
        XCTAssertEqual((integrity["files"] as? [[String: Any]])?.count, 10)
    }

    private func decodedEventObjects(in bundle: URL) throws -> [[String: Any]] {
        let compressed = try Data(contentsOf: bundle.appending(path: "events.jsonl.zlib"))
        let data = try ZlibCodec.decompress(compressed)
        return try String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    private func schemaErrors(file: String, schema: String, in bundle: URL) throws -> [String] {
        let object = try jsonObject(at: bundle.appending(path: file))
        return SnapshotJSONSchemaValidator().validate(instance: object, schema: try SnapshotJSONSchemaValidator.loadSchema(named: schema))
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private static let base = Date(timeIntervalSince1970: 2_000_000_000)

    private static func event(id: String, at date: Date, path: String, delta: Int64 = 1) -> EvidenceStoreEvent {
        EvidenceStoreEvent(
            eventID: id,
            observedAt: date,
            operation: .create,
            path: path,
            logicalDelta: delta,
            allocatedDelta: delta,
            consumerCategory: "developer-cache",
            confidence: .inferred
        )
    }
}

private final class Fixture {
    let directory: URL
    let databaseURL: URL
    let exports: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "evidence.sqlite")
        exports = directory.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
