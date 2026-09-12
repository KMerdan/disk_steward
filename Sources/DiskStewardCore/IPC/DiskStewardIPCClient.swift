import Darwin
import Foundation

public protocol DiskStewardIPCClient: Sendable {
    func call(
        tool: String,
        arguments: [String: JSONValue],
        isCancelled: @Sendable () -> Bool
    ) throws -> JSONValue

    func readResource(uri: String, isCancelled: @Sendable () -> Bool) throws -> JSONValue
}

public enum DiskStewardIPCError: Error, Equatable, LocalizedError {
    case appUnavailable
    case insecureSocket(String)
    case connectionFailed(Int32)
    case malformedResponse
    case remote(code: String, message: String, retryable: Bool)
    case responseTooLarge
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .appUnavailable: return "Disk Steward is not running or its local evidence service is unavailable."
        case let .insecureSocket(reason): return "Disk Steward refused an insecure local socket: \(reason)"
        case let .connectionFailed(code): return "Disk Steward local connection failed with errno \(code)."
        case .malformedResponse: return "Disk Steward returned a malformed local response."
        case let .remote(_, message, _): return message
        case .responseTooLarge: return "The local response exceeded the bounded IPC size."
        case .cancelled: return "The local evidence request was cancelled."
        }
    }
}

public struct UnixSocketDiskStewardIPCClient: DiskStewardIPCClient, Sendable {
    public let socketPath: String
    public let maximumResponseBytes: Int

    public init(socketPath: String, maximumResponseBytes: Int = 4 * 1_024 * 1_024) {
        self.socketPath = socketPath
        self.maximumResponseBytes = min(max(1_024, maximumResponseBytes), 4 * 1_024 * 1_024)
    }

    public static func defaultSocketPath() -> String {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appending(path: "DiskSteward/disk-steward.sock").path
    }

    public func call(
        tool: String,
        arguments: [String: JSONValue],
        isCancelled: @Sendable () -> Bool
    ) throws -> JSONValue {
        try send(method: "tools/call", payload: .object(["name": .string(tool), "arguments": .object(arguments)]), isCancelled: isCancelled)
    }

    public func readResource(uri: String, isCancelled: @Sendable () -> Bool) throws -> JSONValue {
        try send(method: "resources/read", payload: .object(["uri": .string(uri)]), isCancelled: isCancelled)
    }

    public func send(
        method: String,
        payload: JSONValue,
        isCancelled: @Sendable () -> Bool
    ) throws -> JSONValue {
        if isCancelled() { throw DiskStewardIPCError.cancelled }
        try verifySocket()

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw DiskStewardIPCError.insecureSocket("path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buffer in
                for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        guard connected == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }

        let requestID = UUID().uuidString.lowercased()
        let envelope = JSONValue.object([
            "schema": .string("ipc-request-v1"),
            "id": .string(requestID),
            "method": .string(method),
            "payload": payload,
            "client": .object([
                "pid": .integer(Int64(getpid())),
                "uid": .integer(Int64(getuid())),
            ]),
        ])
        var encoded = try JSONEncoder.diskSteward.encode(envelope)
        encoded.append(0x0A)
        try writeAll(encoded, to: descriptor, isCancelled: isCancelled)
        let responseData = try readLine(from: descriptor, isCancelled: isCancelled)
        let response = try JSONDecoder().decode(JSONValue.self, from: responseData)
        guard let object = response.objectValue,
              object["schema"] == .string("ipc-response-v1"),
              object["id"] == .string(requestID)
        else { throw DiskStewardIPCError.malformedResponse }
        if let result = object["result"] { return result }
        if let error = object["error"]?.objectValue,
           let code = error["code"]?.stringValue,
           let message = error["message"]?.stringValue {
            let retryable = error["retryable"] == .bool(true)
            throw DiskStewardIPCError.remote(code: code, message: message, retryable: retryable)
        }
        throw DiskStewardIPCError.malformedResponse
    }

    private func verifySocket() throws {
        var status = stat()
        guard lstat(socketPath, &status) == 0 else {
            if errno == ENOENT { throw DiskStewardIPCError.appUnavailable }
            throw DiskStewardIPCError.connectionFailed(errno)
        }
        guard status.st_mode & S_IFMT == S_IFSOCK else {
            throw DiskStewardIPCError.insecureSocket("path is not a Unix-domain socket")
        }
        guard status.st_uid == getuid() else {
            throw DiskStewardIPCError.insecureSocket("socket owner does not match the current user")
        }
        guard status.st_mode & 0o077 == 0 else {
            throw DiskStewardIPCError.insecureSocket("socket permits group or other access")
        }
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32,
        isCancelled: @Sendable () -> Bool
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                if isCancelled() { throw DiskStewardIPCError.cancelled }
                let count = Darwin.write(descriptor, base.advanced(by: sent), rawBuffer.count - sent)
                guard count > 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
                sent += count
            }
        }
    }

    private func readLine(
        from descriptor: Int32,
        isCancelled: @Sendable () -> Bool
    ) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= maximumResponseBytes {
            if isCancelled() { throw DiskStewardIPCError.cancelled }
            let count = Darwin.read(descriptor, &byte, 1)
            guard count > 0 else { throw DiskStewardIPCError.malformedResponse }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        throw DiskStewardIPCError.responseTooLarge
    }
}

public extension JSONEncoder {
    static var diskSteward: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
