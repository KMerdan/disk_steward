import Foundation
import XCTest
@testable import DiskStewardCore

final class ZlibRegressionTests: XCTestCase {
    func testEmptyFinalizedStreamAndBoundedDecode() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        let compressed = root.appending(path: "compressed")
        try Data().write(to: source)
        try ZlibCodec.compressFile(at: source, to: compressed)
        let emptyStream = try Data(contentsOf: compressed)
        XCTAssertFalse(emptyStream.isEmpty)
        XCTAssertEqual(try ZlibCodec.decompress(emptyStream, maximumOutputBytes: 0), Data())
        let payload = Data(repeating: 65, count: 128 * 1_024)
        try payload.write(to: source)
        try FileManager.default.removeItem(at: compressed)
        try ZlibCodec.compressFile(at: source, to: compressed)
        let encoded = try Data(contentsOf: compressed)
        XCTAssertEqual(try ZlibCodec.decompress(encoded, maximumOutputBytes: payload.count), payload)
        XCTAssertThrowsError(try ZlibCodec.decompress(encoded, maximumOutputBytes: payload.count - 1))
        XCTAssertThrowsError(try ZlibCodec.decompress(Data(encoded.dropLast())))
        // Apple's raw-deflate decoder accepts trailing padding; bundle checksums
        // detect file tampering. Decoding must still be bounded and terminate.
        XCTAssertEqual(try ZlibCodec.decompress(encoded + Data([0, 1, 2])), payload)
        XCTAssertThrowsError(try ZlibCodec.decompress(Data([0xff, 0xff, 0xff])))
    }
}
