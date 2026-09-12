import Compression
import Foundation

enum ZlibCodec {
    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        return try transform(data, operation: compression_encode_buffer)
    }

    static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        return try transform(data, initialCapacity: max(1_024, data.count * 4), operation: compression_decode_buffer)
    }

    private static func transform(
        _ data: Data,
        initialCapacity: Int? = nil,
        operation: (UnsafeMutablePointer<UInt8>, Int, UnsafePointer<UInt8>, Int, UnsafeMutableRawPointer?, compression_algorithm) -> Int
    ) throws -> Data {
        var capacity = initialCapacity ?? max(1_024, data.count + data.count / 4 + 64)
        for _ in 0 ..< 12 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    operation(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0, written < capacity {
                output.count = written
                return output
            }
            capacity *= 2
        }
        throw EvidenceBundleExportError.compressionFailed
    }
}
