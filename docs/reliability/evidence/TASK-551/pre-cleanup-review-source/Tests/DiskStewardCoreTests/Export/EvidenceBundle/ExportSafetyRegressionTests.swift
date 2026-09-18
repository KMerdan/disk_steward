import Foundation
import XCTest
@testable import DiskStewardCore

final class ExportSafetyRegressionTests: XCTestCase {
    private static let date = Date(timeIntervalSince1970: 2_000_000_000.125)
    func testMemoryCodecProducesFinalizedEmptyStreamAndRejectsMissingStream() throws {
        let encoded = try ZlibCodec.compress(Data())
        XCTAssertFalse(encoded.isEmpty, "Empty evidence still needs a finalized stream")
        XCTAssertEqual(try ZlibCodec.decompress(encoded, maximumOutputBytes: 0), Data())
        XCTAssertThrowsError(try ZlibCodec.decompress(Data()))
        XCTAssertThrowsError(try ZlibCodec.decompress(Data(), maximumOutputBytes: -1))
    }

    func testCancelledCodecDoesNotReturnSuccess() async throws {
        let encoded = try ZlibCodec.compress(Data(repeating: 65, count: 131_072))
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ZlibCodec.decompress(encoded)
        }
        do {
            _ = try await work.value
            XCTFail("A cancelled decoder must not publish evidence")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCompressionDoesNotOverwriteExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ds-export-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        let destination = root.appending(path: "destination")
        try Data("input".utf8).write(to: source)
        let sentinel = Data("previous-export".utf8)
        try sentinel.write(to: destination)
        XCTAssertThrowsError(try ZlibCodec.compressFile(at: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
    }

    func testCodecExactBuffersRandomDataAndOutputCaps() throws {
        for count in [0, 1, 65_535, 65_536, 65_537, 131_072, 262_147] {
            var state: UInt64 = 12_345
            let data = Data((0..<count).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return UInt8(truncatingIfNeeded: state >> 32)
            })
            let encoded = try ZlibCodec.compress(data)
            XCTAssertEqual(try ZlibCodec.decompress(encoded, maximumOutputBytes: count), data)
            XCTAssertThrowsError(try ZlibCodec.decompress(Data(encoded.dropLast()), maximumOutputBytes: count))
            if count > 0 { XCTAssertThrowsError(try ZlibCodec.decompress(encoded, maximumOutputBytes: count - 1)) }
            XCTAssertThrowsError(try ZlibCodec.compress(data, maximumOutputBytes: encoded.count - 1))
            XCTAssertEqual(try ZlibCodec.compress(data, maximumOutputBytes: encoded.count), encoded)
        }
        let expansion = try ZlibCodec.compress(Data(repeating: 0, count: 4 * 1_024 * 1_024))
        XCTAssertThrowsError(try ZlibCodec.decompress(expansion, maximumOutputBytes: 1_024)) {
            XCTAssertEqual($0 as? EvidenceBundleExportError, .budgetExceeded)
        }
    }

    func testFileCodecCleansPartialOutputAfterCancellationAndBudgetFailure() throws {
        let fixture = try SafetyFixture()
        let source = fixture.root.appending(path: "source")
        try Data(repeating: 42, count: 131_072).write(to: source)
        let destination = fixture.root.appending(path: "destination")
        var checks = 0
        XCTAssertThrowsError(try ZlibCodec.compressFile(at: source, to: destination, chunkSize: 1_024, checkCancellation: {
            checks += 1
            if checks == 10 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(try ZlibCodec.compressFile(at: source, to: destination, maximumOutputBytes: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(try ZlibCodec.compressFile(at: source, to: destination, maximumInputBytes: 1_024))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testOwnedCleanupPreservesReplacementAndExistingDirectories() throws {
        let fixture = try SafetyFixture()
        let path = fixture.root.appending(path: "owned")
        let owner = try OwnedExportDirectory(exclusive: path)
        let original = fixture.root.appending(path: "original")
        try FileManager.default.moveItem(at: path, to: original)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let sentinel = path.appending(path: "sentinel")
        try Data("foreign".utf8).write(to: sentinel)
        owner.removeIfOwned()
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign".utf8))
        XCTAssertThrowsError(try OwnedExportDirectory(exclusive: path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign".utf8))
    }

    func testReadAndPayloadBudgetsFailWithoutLeavingScratchOrPartialBundle() async throws {
        for limits in [EvidenceExportLimits(maximumReadBytes: 10), EvidenceExportLimits(maximumPayloadBytes: 10)] {
            let fixture = try SafetyFixture()
            let store = try EvidenceStore(url: fixture.database)
            try await store.insert(Self.event(0))
            do {
                _ = try await EvidenceBundleExporter(identifierSource: { "budget" }, temporaryDirectory: fixture.root).export(
                    store: store, options: .init(from: Self.date, through: Self.date, limits: limits), to: fixture.exports)
                XCTFail("Expected a bounded export failure")
            } catch { XCTAssertEqual(error as? EvidenceBundleExportError, .budgetExceeded) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.exports.path), [])
            try fixture.assertNoScratch()
            let records = try await store.exportRecords()
            XCTAssertEqual(records.map(\.status), [.failed])
            await store.close()
        }
    }

    func testCorruptSerializedSnapshotThrowsAndRemovesWorkspace() async throws {
        let fixture = try SafetyFixture()
        let store = try EvidenceStore(url: fixture.database)
        try await store.recordSnapshot(.init(snapshotID: "broken", observedAt: EvidenceTimestamp.format(Self.date), volumes: [], limitations: []), observedAt: Self.date)
        let connection = try SQLiteConnection(url: fixture.database)
        try connection.execute("UPDATE snapshots SET payload = X'7B'")
        connection.close()
        do {
            _ = try await EvidenceBundleExporter(temporaryDirectory: fixture.root).export(store: store, options: .init(from: Self.date, through: Self.date), to: fixture.exports)
            XCTFail("Corrupt evidence must not produce a successful bundle")
        } catch { XCTAssertTrue(error is DecodingError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.exports.path), [])
        try fixture.assertNoScratch()
        let records = try await store.exportRecords()
        XCTAssertEqual(records.map(\.status), [.failed])
        await store.close()
    }

    func testCancellationAtPublicationCleansPayloadAndFinalizesFailureRecord() async throws {
        let fixture = try SafetyFixture()
        let store = try EvidenceStore(url: fixture.database)
        try await store.insert(Self.event(0))
        let clock = CancelOnSecondDate()
        let exporter = EvidenceBundleExporter(identifierSource: { "cancel" }, dateSource: { clock.next() }, temporaryDirectory: fixture.root)
        let options = EvidenceBundleExportOptions(from: Self.date, through: Self.date)
        let exports = fixture.exports
        let work = Task.detached { try await exporter.export(store: store, options: options, to: exports) }
        do { _ = try await work.value; XCTFail("Cancelled export must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.exports.path), [])
        try fixture.assertNoScratch()
        let records = try await store.exportRecords()
        XCTAssertEqual(records.map(\.status), [.failed])
        await store.close()
    }

    func testZeroOneManyRowsAndFractionalActualRange() async throws {
        for count in [0, 1, 200] {
            let fixture = try SafetyFixture()
            let store = try EvidenceStore(url: fixture.database)
            if count > 0 { try await store.insert((0..<count).map(Self.event)) }
            try await store.recordSnapshot(.init(snapshotID: "fractional", observedAt: EvidenceTimestamp.format(Self.date), volumes: [], limitations: []), observedAt: Self.date)
            let result = try await EvidenceBundleExporter().export(store: store, options: .init(from: Self.date, through: Self.date), to: fixture.exports)
            let compressed = try Data(contentsOf: result.bundleURL.appending(path: "events.jsonl.zlib"))
            let decoded = try ZlibCodec.decompress(compressed)
            XCTAssertEqual(decoded.split(separator: 10).count, count)
            let records = try await store.exportRecords()
            XCTAssertEqual(try XCTUnwrap(records.first?.actualFrom).timeIntervalSince1970, Self.date.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(records.first?.actualThrough, Self.date)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.exports.path), [result.bundleURL.lastPathComponent])
            await store.close()
        }
        XCTAssertEqual(EvidenceTimestamp.parse("2033-05-18T03:33:20Z"), Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(EvidenceTimestamp.parse("not-a-date"))
    }

    private static func event(_ index: Int) -> EvidenceStoreEvent {
        .init(eventID: "event-\(index)", observedAt: date, operation: .create, path: "/fixture/\(index)", logicalDelta: 1, allocatedDelta: 1, consumerCategory: "fixture", confidence: .inferred)
    }

    func testTemporaryResultCleanupPreservesReplacedParentAndBundle() async throws {
        let fixture = try SafetyFixture()
        let store = try EvidenceStore(url: fixture.database)
        let result = try await EvidenceBundleExporter().export(store: store, options: .init(from: Self.date, through: Self.date), to: fixture.exports, kind: .temporary)
        let moved = fixture.root.appending(path: "original-request")
        try FileManager.default.moveItem(at: fixture.exports, to: moved)
        try FileManager.default.createDirectory(at: result.bundleURL, withIntermediateDirectories: true)
        let sentinel = result.bundleURL.appending(path: "sentinel")
        try Data("foreign".utf8).write(to: sentinel)
        XCTAssertThrowsError(try result.destroyTemporaryPayload()) {
            XCTAssertEqual($0 as? EvidenceBundleExportError, .destinationOwnershipChanged)
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appending(path: result.bundleURL.lastPathComponent).path))
        await store.close()
    }

    func testOverflowInStoredDeltasThrowsInsteadOfTrapping() async throws {
        let fixture = try SafetyFixture()
        let store = try EvidenceStore(url: fixture.database)
        try await store.insert([Self.event(0), Self.event(1)])
        let connection = try SQLiteConnection(url: fixture.database)
        try connection.execute("UPDATE events SET allocated_delta = 9223372036854775807")
        connection.close()
        do {
            _ = try await EvidenceBundleExporter().export(store: store, options: .init(from: Self.date, through: Self.date), to: fixture.exports)
            XCTFail("Overflowing evidence must throw")
        } catch { XCTAssertEqual(error as? EvidenceBundleExportError, .invalidEvidence) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.exports.path), [])
        await store.close()
    }

    func testSingleOversizedSerializedRowIsRejectedBeforeDecoding() async throws {
        let fixture = try SafetyFixture()
        let store = try EvidenceStore(url: fixture.database)
        try await store.recordSnapshot(.init(snapshotID: "large", observedAt: EvidenceTimestamp.format(Self.date), volumes: [], limitations: []), observedAt: Self.date)
        let connection = try SQLiteConnection(url: fixture.database)
        try connection.execute("UPDATE snapshots SET payload = zeroblob(2097152)")
        connection.close()
        do {
            _ = try await EvidenceBundleExporter(temporaryDirectory: fixture.root).export(store: store, options: .init(from: Self.date, through: Self.date), to: fixture.exports)
            XCTFail("Oversized SQLite rows must be rejected")
        } catch { XCTAssertEqual(error as? EvidenceBundleExportError, .budgetExceeded) }
        try fixture.assertNoScratch()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.exports.path), [])
        await store.close()
    }
}

private final class CancelOnSecondDate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Date {
        let cancel = lock.withLock { count += 1; return count == 2 }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return Date(timeIntervalSince1970: 2_000_000_000)
    }
}

private final class SafetyFixture: @unchecked Sendable {
    let root: URL
    var database: URL { root.appending(path: "evidence.sqlite") }
    var exports: URL { root.appending(path: "exports") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ds-export-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func assertNoScratch(file: StaticString = #filePath, line: UInt = #line) throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(contents.contains { $0.hasPrefix("disk-steward-work-") }, file: file, line: line)
    }
}
