import Darwin
import Foundation

public struct IPCPeerIdentity: Equatable, Sendable {
    public let uid: uid_t
    public let gid: gid_t
    public let pid: Int32

    public init(uid: uid_t, gid: gid_t, pid: Int32) {
        self.uid = uid
        self.gid = gid
        self.pid = pid
    }
}

public protocol DiskStewardIPCRequestHandling: Sendable {
    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue
}

public final class UnixSocketEvidenceServer: @unchecked Sendable {
    public let socketPath: String
    private let handler: any DiskStewardIPCRequestHandling
    private let maximumRequestBytes: Int
    private let stateLock = NSLock()
    private var listeningDescriptor: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "DiskSteward.IPC.Accept", qos: .utility)

    public init(
        socketPath: String,
        handler: any DiskStewardIPCRequestHandling,
        maximumRequestBytes: Int = 1 * 1_024 * 1_024
    ) {
        self.socketPath = socketPath
        self.handler = handler
        self.maximumRequestBytes = min(max(1_024, maximumRequestBytes), 1 * 1_024 * 1_024)
    }

    deinit { stop() }

    public func start() throws {
        try stateLock.withLock {
            guard !running else { return }
            let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try secureDirectory(parent.path)
            try removeStaleSocketIfOwned()

            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
            do {
                var address = try socketAddress()
                let length = socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8CString.count)
                let bound = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, length)
                    }
                }
                guard bound == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
                guard chmod(socketPath, 0o600) == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
                guard Darwin.listen(descriptor, 16) == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
            } catch {
                Darwin.close(descriptor)
                unlink(socketPath)
                throw error
            }
            listeningDescriptor = descriptor
            running = true
            queue.async { [weak self] in self?.acceptLoop(descriptor: descriptor) }
        }
    }

    public func stop() {
        stateLock.withLock {
            guard running else { return }
            running = false
            if listeningDescriptor >= 0 {
                Darwin.shutdown(listeningDescriptor, SHUT_RDWR)
                Darwin.close(listeningDescriptor)
                listeningDescriptor = -1
            }
            var status = stat()
            if lstat(socketPath, &status) == 0,
               status.st_uid == getuid(),
               status.st_mode & S_IFMT == S_IFSOCK {
                unlink(socketPath)
            }
        }
    }

    private func acceptLoop(descriptor: Int32) {
        while stateLock.withLock({ running && listeningDescriptor == descriptor }) {
            let connection = Darwin.accept(descriptor, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                break
            }
            Task { [weak self] in await self?.serve(connection) }
        }
    }

    private func serve(_ descriptor: Int32) async {
        defer { Darwin.close(descriptor) }
        var requestID = "unknown"
        do {
            let peer = try peerIdentity(descriptor)
            guard peer.uid == getuid() else {
                throw DiskStewardIPCError.insecureSocket("peer UID does not match the app user")
            }
            let requestData = try readLine(from: descriptor)
            let request = try JSONDecoder().decode(JSONValue.self, from: requestData)
            guard let object = request.objectValue,
                  object["schema"] == .string("ipc-request-v1"),
                  let id = object["id"]?.stringValue,
                  let method = object["method"]?.stringValue,
                  let payload = object["payload"]
            else { throw DiskStewardIPCError.malformedResponse }
            requestID = id
            let result = try await handler.handleIPC(method: method, payload: payload, peer: peer)
            try send(.object([
                "schema": .string("ipc-response-v1"),
                "id": .string(id),
                "result": result,
            ]), to: descriptor)
        } catch {
            let code: String
            let retryable: Bool
            switch error {
            case DiskStewardIPCError.insecureSocket:
                code = "permission_denied"; retryable = false
            case DiskStewardIPCError.responseTooLarge:
                code = "request_too_large"; retryable = true
            case DiskStewardIPCError.cancelled:
                code = "cancelled"; retryable = true
            default:
                code = "request_failed"; retryable = true
            }
            try? send(.object([
                "schema": .string("ipc-response-v1"),
                "id": .string(requestID),
                "error": .object([
                    "code": .string(code),
                    "message": .string(error.localizedDescription),
                    "retryable": .bool(retryable),
                ]),
            ]), to: descriptor)
        }
    }

    private func peerIdentity(_ descriptor: Int32) throws -> IPCPeerIdentity {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else {
            throw DiskStewardIPCError.insecureSocket("peer credentials are unavailable")
        }
        var pid: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
            throw DiskStewardIPCError.insecureSocket("peer PID is unavailable")
        }
        return IPCPeerIdentity(uid: uid, gid: gid, pid: pid)
    }

    private func readLine(from descriptor: Int32) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= maximumRequestBytes {
            let count = Darwin.read(descriptor, &byte, 1)
            guard count > 0 else { throw DiskStewardIPCError.malformedResponse }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        throw DiskStewardIPCError.responseTooLarge
    }

    private func send(_ value: JSONValue, to descriptor: Int32) throws {
        var data = try JSONEncoder.diskSteward.encode(value)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: sent), raw.count - sent)
                guard count > 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
                sent += count
            }
        }
    }

    private func socketAddress() throws -> sockaddr_un {
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
        return address
    }

    private func secureDirectory(_ path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFDIR
        else { throw DiskStewardIPCError.insecureSocket("socket directory is not owned by the current user") }
        guard chmod(path, 0o700) == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
    }

    private func removeStaleSocketIfOwned() throws {
        var status = stat()
        guard lstat(socketPath, &status) == 0 else {
            if errno == ENOENT { return }
            throw DiskStewardIPCError.connectionFailed(errno)
        }
        guard status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFSOCK else {
            throw DiskStewardIPCError.insecureSocket("an unowned or non-socket entry occupies the socket path")
        }
        guard unlink(socketPath) == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
