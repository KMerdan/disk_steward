import Compression
import Foundation

public enum ZlibCodec {
    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        return try transform(data, operation: compression_encode_buffer)
    }

    public static func decompress(_ data: Data, maximumOutputBytes: Int = 8 * 1_024 * 1_024) throws -> Data {
        guard !data.isEmpty else { return Data() }
        guard maximumOutputBytes >= 0 else { throw EvidenceBundleExportError.compressionFailed }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1_024)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw EvidenceBundleExportError.compressionFailed
        }
        defer { compression_stream_destroy(&stream) }
        return try data.withUnsafeBytes { input in
            stream.src_ptr = input.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = data.count
            var output = Data()
            while true {
                let remainingBefore = stream.src_size
                stream.dst_ptr = buffer
                stream.dst_size = 64 * 1_024
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = 64 * 1_024 - stream.dst_size
                guard status != COMPRESSION_STATUS_ERROR,
                      produced <= maximumOutputBytes - output.count else { throw EvidenceBundleExportError.compressionFailed }
                output.append(buffer, count: produced)
                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0 else { throw EvidenceBundleExportError.compressionFailed }
                    return output
                }
                guard produced > 0 || stream.src_size < remainingBefore else { throw EvidenceBundleExportError.compressionFailed }
            }
        }
    }

    static func compressFile(
        at sourceURL: URL,
        to destinationURL: URL,
        chunkSize: Int = 64 * 1_024
    ) throws {
        guard chunkSize > 0, chunkSize <= 1_024 * 1_024 else { throw EvidenceBundleExportError.compressionFailed }
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer { try? destination.close() }

        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw EvidenceBundleExportError.compressionFailed
        }
        defer { compression_stream_destroy(&stream) }
        var output = [UInt8](repeating: 0, count: chunkSize)

        func process(_ input: Data, finalize: Bool) throws -> Bool {
            try input.withUnsafeBytes { rawInput -> Bool in
                stream.src_ptr = rawInput.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(placeholder)
                stream.src_size = input.count
                repeat {
                    let outputCount = output.count
                    let status = output.withUnsafeMutableBytes { rawOutput -> compression_status in
                        stream.dst_ptr = rawOutput.bindMemory(to: UInt8.self).baseAddress ?? placeholder
                        stream.dst_size = outputCount
                        return compression_stream_process(
                            &stream,
                            finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                        )
                    }
                    guard status != COMPRESSION_STATUS_ERROR else {
                        throw EvidenceBundleExportError.compressionFailed
                    }
                    let produced = outputCount - stream.dst_size
                    if produced > 0 { try destination.write(contentsOf: Data(output.prefix(produced))) }
                    if status == COMPRESSION_STATUS_END { return true }
                    if !finalize, stream.src_size == 0 { return false }
                } while true
            }
        }

        while let chunk = try source.read(upToCount: chunkSize), !chunk.isEmpty {
            _ = try process(chunk, finalize: false)
        }
        guard try process(Data(), finalize: true) else {
            throw EvidenceBundleExportError.compressionFailed
        }
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
