import Foundation
import XCTest
@testable import DiskStewardCore

final class ExportSafetyRegressionTests: XCTestCase {
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
}
