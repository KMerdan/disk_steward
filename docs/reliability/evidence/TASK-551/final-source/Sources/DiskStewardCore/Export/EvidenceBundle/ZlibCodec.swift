import Compression
import Darwin
import Foundation

public enum ZlibCodec {
    static func compress(_ data: Data, maximumOutputBytes: Int = 64 * 1_024 * 1_024) throws -> Data {
        try transformData(data, operation: COMPRESSION_STREAM_ENCODE, maximumOutputBytes: maximumOutputBytes)
    }

    public static func decompress(_ data: Data, maximumOutputBytes: Int = 8 * 1_024 * 1_024) throws -> Data {
        // No bytes is a missing/truncated stream, not an encoded empty payload.
        guard !data.isEmpty else { throw EvidenceBundleExportError.compressionFailed }
        return try transformData(data, operation: COMPRESSION_STREAM_DECODE, maximumOutputBytes: maximumOutputBytes)
    }

    private static func transformData(_ data: Data, operation: compression_stream_operation, maximumOutputBytes: Int) throws -> Data {
        var offset = 0
        var output = Data()
        try transform(operation: operation, maximumInputBytes: 64 * 1_024 * 1_024,
                      maximumOutputBytes: maximumOutputBytes, chunkSize: 64 * 1_024,
                      checkCancellation: { try Task.checkCancellation() }, read: {
            let end = offset + min(64 * 1_024, data.count - offset)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }, write: { output.append($0) })
        return output
    }

    /// Creates a new file exclusively. Failure never leaves a partial stream or
    /// overwrites a prior export; the caller owns publication of this payload.
    static func compressFile(
        at sourceURL: URL, to destinationURL: URL, chunkSize: Int = 64 * 1_024,
        maximumInputBytes: Int = 64 * 1_024 * 1_024,
        maximumOutputBytes: Int = 64 * 1_024 * 1_024,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        let descriptor = open(destinationURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let destination = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var identity = stat()
        let hasIdentity = fstat(descriptor, &identity) == 0
        var succeeded = false
        defer {
            try? destination.close()
            var current = stat()
            if !succeeded, hasIdentity, lstat(destinationURL.path, &current) == 0,
               current.st_dev == identity.st_dev, current.st_ino == identity.st_ino {
                _ = unlink(destinationURL.path)
            }
        }
        guard hasIdentity else { throw CocoaError(.fileWriteUnknown) }
        try transform(operation: COMPRESSION_STREAM_ENCODE, maximumInputBytes: maximumInputBytes,
                      maximumOutputBytes: maximumOutputBytes, chunkSize: chunkSize,
                      checkCancellation: checkCancellation,
                      read: { try source.read(upToCount: chunkSize) ?? Data() },
                      write: { try destination.write(contentsOf: $0) })
        try checkCancellation()
        try destination.close()
        succeeded = true
    }

    /// A single fixed-buffer driver for memory and file operations. END (not a
    /// short output buffer) is the only successful completion condition.
    private static func transform(
        operation: compression_stream_operation, maximumInputBytes: Int, maximumOutputBytes: Int,
        chunkSize: Int, checkCancellation: () throws -> Void,
        read: () throws -> Data, write: (Data) throws -> Void
    ) throws {
        guard chunkSize > 0, chunkSize <= 1_024 * 1_024,
              maximumInputBytes >= 0, maximumOutputBytes >= 0 else {
            throw EvidenceBundleExportError.compressionFailed
        }
        try checkCancellation()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw EvidenceBundleExportError.compressionFailed
        }
        defer { compression_stream_destroy(&stream) }
        var remainingInput = maximumInputBytes
        var remainingOutput = maximumOutputBytes
        while true {
            try checkCancellation()
            let input = try read()
            guard input.count <= remainingInput else { throw EvidenceBundleExportError.budgetExceeded }
            remainingInput -= input.count
            let finished = try input.withUnsafeBytes { rawInput in
                stream.src_ptr = rawInput.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
                stream.src_size = input.count
                repeat {
                    try checkCancellation()
                    let before = stream.src_size
                    stream.dst_ptr = buffer
                    stream.dst_size = chunkSize
                    let status = compression_stream_process(&stream, input.isEmpty ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = chunkSize - stream.dst_size
                    guard status != COMPRESSION_STATUS_ERROR else { throw EvidenceBundleExportError.compressionFailed }
                    guard produced <= remainingOutput else { throw EvidenceBundleExportError.budgetExceeded }
                    remainingOutput -= produced
                    if produced > 0 { try write(Data(bytes: buffer, count: produced)) }
                    if status == COMPRESSION_STATUS_END {
                        guard stream.src_size == 0 else { throw EvidenceBundleExportError.compressionFailed }
                        return true
                    }
                    if !input.isEmpty, stream.src_size == 0 { return false }
                    guard produced > 0 || stream.src_size < before else { throw EvidenceBundleExportError.compressionFailed }
                } while true
            }
            if finished {
                try checkCancellation()
                guard try read().isEmpty else { throw EvidenceBundleExportError.compressionFailed }
                return
            }
        }
    }
}
