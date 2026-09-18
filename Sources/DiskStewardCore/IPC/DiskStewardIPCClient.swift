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
    case agentAccessDisabled
    case insecureSocket(String)
    case connectionFailed(Int32)
    case malformedResponse
    case remote(code: String, message: String, retryable: Bool)
    case responseTooLarge
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .appUnavailable: return "Disk Steward is not running or its local evidence service is unavailable."
        case .agentAccessDisabled: return "Disk Steward Agent Access is disabled by the user."
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
    public let accessStateURL: URL?
    public let timeoutSeconds: TimeInterval

    public init(
        socketPath: String,
        maximumResponseBytes: Int = 4 * 1_024 * 1_024,
        accessStateURL: URL? = nil,
        timeoutSeconds: TimeInterval = 10
    ) {
        self.socketPath = socketPath
        self.maximumResponseBytes = min(max(1_024, maximumResponseBytes), 4 * 1_024 * 1_024)
        self.accessStateURL = accessStateURL
        self.timeoutSeconds = min(60, max(0.05, timeoutSeconds))
    }

    public static func defaultSocketPath() -> String {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appending(path: "Disk Steward/disk-steward.sock").path
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
        try BoundedSocketIO.configure(descriptor)
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds

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
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw DiskStewardIPCError.connectionFailed(errno) }
            try BoundedSocketIO.wait(descriptor, events: Int16(POLLOUT), deadline: deadline, isCancelled: isCancelled)
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0, failure == 0 else {
                throw DiskStewardIPCError.connectionFailed(failure)
            }
        }

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
        guard encoded.count <= 1_024 * 1_024 else { throw DiskStewardIPCError.responseTooLarge }
        try BoundedSocketIO.write(encoded, to: descriptor, deadline: deadline, isCancelled: isCancelled)
        let responseData = try BoundedSocketIO.readLine(from: descriptor, maximumBytes: maximumResponseBytes, deadline: deadline, isCancelled: isCancelled)
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
            if errno == ENOENT {
                if let accessStateURL,
                   (try? AgentAccessStateFile(url: accessStateURL).readEnabled()) == false {
                    throw DiskStewardIPCError.agentAccessDisabled
                }
                throw DiskStewardIPCError.appUnavailable
            }
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

}

enum BoundedSocketIO {
    static func configure(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
    }

    static func wait(_ descriptor: Int32, events: Int16, deadline: TimeInterval, isCancelled: () -> Bool) throws {
        while true {
            if isCancelled() { throw DiskStewardIPCError.cancelled }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw DiskStewardIPCError.remote(code: "deadline_exceeded", message: "The local evidence request timed out.", retryable: true) }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(100, max(1, remaining * 1_000))))
            if result > 0 {
                guard item.revents & Int16(POLLNVAL) == 0 else { throw DiskStewardIPCError.connectionFailed(EBADF) }
                return // read/write reports EOF and other socket errors.
            }
            if result < 0, errno != EINTR { throw DiskStewardIPCError.connectionFailed(errno) }
        }
    }

    static func write(
        _ data: Data,
        to descriptor: Int32,
        deadline: TimeInterval,
        isCancelled: () -> Bool
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline, isCancelled: isCancelled)
                let count = Darwin.write(descriptor, base.advanced(by: sent), rawBuffer.count - sent)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
                sent += count
            }
        }
    }

    static func readLine(
        from descriptor: Int32,
        maximumBytes: Int,
        deadline: TimeInterval,
        isCancelled: () -> Bool
    ) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= maximumBytes {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline, isCancelled: isCancelled)
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes - data.count + 1))
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw DiskStewardIPCError.malformedResponse }
            let chunk = buffer.prefix(count)
            if let newline = chunk.firstIndex(of: 0x0A) {
                data.append(contentsOf: chunk.prefix(newline))
                guard data.count <= maximumBytes else { throw DiskStewardIPCError.responseTooLarge }
                return data
            }
            data.append(contentsOf: chunk)
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
