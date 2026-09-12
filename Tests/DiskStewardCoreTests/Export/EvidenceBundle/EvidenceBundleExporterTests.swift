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
            "codex-brief.md", "summary.json", "rollups.json", "events.jsonl.zlib", "snapshots.json", "integrity.json",
        ])
        XCTAssertEqual(try schemaErrors(file: "manifest.json", schema: "export-manifest-v1", in: result.bundleURL), [])
        try verifyHashes(result)
        let events = try decodedEventObjects(in: result.bundleURL)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.flatMap { SnapshotJSONSchemaValidator().validate(instance: $0, schema: try! SnapshotJSONSchemaValidator.loadSchema(named: "evidence-event-v1")) }, [])
        let brief = try String(contentsOf: result.bundleURL.appending(path: "codex-brief.md"), encoding: .utf8)
        XCTAssertEqual(brief, try goldenBrief())
        XCTAssertFalse(result.manifest.privacy.containsFileContents)
        XCTAssertFalse(result.manifest.privacy.containsEnvironment)
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
        XCTAssertEqual((integrity["files"] as? [[String: Any]])?.count, 5)
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

    private func goldenBrief() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "Fixtures/Exports/golden-codex-brief.md"), encoding: .utf8)
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
