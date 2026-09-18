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

/// A persistent lock inode with an OS-released lifetime lease. Never unlink a
/// lock file: a waiter could otherwise acquire a different inode for the same path.
public final class LocalServiceLease {
    private let descriptor: Int32

    public init(url: URL) throws {
        let candidate = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard candidate >= 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
        // Assign the stored descriptor only after every throwing check. Swift
        // runs deinit when a fully initialized class initializer throws.
        var acquired = false
        defer { if !acquired { Darwin.close(candidate) } }
        var metadata = stat()
        guard fstat(candidate, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              metadata.st_mode & 0o077 == 0
        else {
            throw DiskStewardIPCError.insecureSocket("invalid lifetime lock")
        }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            throw DiskStewardIPCError.remote(code: "service_already_running", message: "Another Disk Steward instance owns this service. Quit it before starting another copy.", retryable: false)
        }
        descriptor = candidate
        acquired = true
    }

    deinit { Darwin.close(descriptor) }

    fileprivate func previousEndpoint() -> EndpointIdentity? {
        if let record = previousRecord() { return record.endpoint }
        // Read the earlier single-record format conservatively for upgrade.
        var bytes = [UInt8](repeating: 0, count: 1_024)
        let count = pread(descriptor, &bytes, bytes.count, 0)
        guard count > 0, count < bytes.count else { return nil }
        return try? JSONDecoder().decode(EndpointIdentity.self, from: Data(bytes.prefix(count)))
    }

    fileprivate func previousRecord() -> LeaseRecord? {
        validSlots().max(by: { $0.record.sequence < $1.record.sequence })?.record
    }

    private func validSlots() -> [(slot: Int, record: LeaseRecord)] {
        (0..<2).compactMap { slot in
            var bytes = [UInt8](repeating: 0, count: 2_048)
            let count = pread(descriptor, &bytes, bytes.count, off_t(slot * 2_048))
            guard count > 0,
                  let envelope = try? JSONDecoder().decode(LeaseEnvelope.self, from: Data(bytes.prefix(count).prefix(while: { $0 != 0 }))),
                  SHA256Digest.hex(for: envelope.payload) == envelope.checksum,
                  let record = try? JSONDecoder().decode(LeaseRecord.self, from: envelope.payload)
            else { return nil }
            return (slot, record)
        }
    }

    fileprivate func record(directory: DirectoryIdentity, endpoint: EndpointIdentity?, checkpoint: () throws -> Void = {}) throws {
        let latest = validSlots().max(by: { $0.record.sequence < $1.record.sequence })
        guard latest?.record.sequence != UInt64.max else {
            throw DiskStewardIPCError.insecureSocket("lifetime journal sequence exhausted")
        }
        let record = LeaseRecord(sequence: (latest?.record.sequence ?? 0) + 1, directory: directory, endpoint: endpoint)
        let payload = try JSONEncoder().encode(record)
        var bytes = try JSONEncoder().encode(LeaseEnvelope(payload: payload, checksum: SHA256Digest.hex(for: payload)))
        guard bytes.count < 2_048 else { throw DiskStewardIPCError.responseTooLarge }
        let split = bytes.count / 2
        bytes.append(Data(repeating: 0, count: 2_048 - bytes.count))
        let offset = off_t((latest.map { 1 - $0.slot } ?? 0) * 2_048)
        // Never truncate the previous complete slot. If this write is torn,
        // its checksum rejects it and recovery uses the older directory proof.
        try writeRecord(bytes.prefix(split), at: offset)
        try checkpoint()
        try writeRecord(bytes.dropFirst(split), at: offset + off_t(split))
        guard fsync(descriptor) == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
    }

    private func writeRecord(_ data: Data, at offset: off_t) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = pwrite(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written, offset + off_t(written))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
                written += count
            }
        }
    }
}

fileprivate struct LeaseEnvelope: Codable {
    let payload: Data
    let checksum: String
}

fileprivate struct LeaseRecord: Codable {
    let sequence: UInt64
    let directory: DirectoryIdentity
    let endpoint: EndpointIdentity?
}

fileprivate struct DirectoryIdentity: Codable, Equatable {
    let device: Int32
    let inode: UInt64

    init?(_ path: String) {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o077 == 0 else { return nil }
        device = metadata.st_dev
        inode = metadata.st_ino
    }
}

enum SocketStartupCheckpoint: String, Sendable {
    case directoryJournaled, bound, journalPartiallyWritten, endpointJournaled, published
}

fileprivate struct EndpointIdentity: Codable, Equatable {
    let device: Int32
    let inode: UInt64

    init?(_ path: String) {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFSOCK else { return nil }
        device = metadata.st_dev
        inode = metadata.st_ino
    }
}

public final class UnixSocketEvidenceServer: @unchecked Sendable {
    public let socketPath: String
    private let handler: any DiskStewardIPCRequestHandling
    private let maximumRequestBytes: Int
    private let stateLock = NSLock()
    private var listeningDescriptor: Int32 = -1
    private var listeningSource: DispatchSourceRead?
    private var running = false
    private var lease: LocalServiceLease?
    private var endpointIdentity: EndpointIdentity?
    private final class ConnectionWork: @unchecked Sendable {
        let deadline: TimeInterval
        var task: Task<Void, Never>?
        var cancelled = false
        init(deadline: TimeInterval) { self.deadline = deadline }
    }
    // Keep cancelled work counted until it actually exits, including across
    // stop/start. Dropping it on revoke would allow unlimited orphaned tasks.
    private var connections: [Int32: ConnectionWork] = [:]
    private var watchdog: DispatchSourceTimer?
    private var serviceEpoch: UInt64 = 0
    private let maximumConnections: Int
    private let timeoutSeconds: TimeInterval
    private let startupCheckpoint: @Sendable (SocketStartupCheckpoint) throws -> Void
    private let beforeAccept: @Sendable (Int32) -> Void
    private let queue = DispatchQueue(label: "DiskSteward.IPC.Accept", qos: .utility)
    private let watchdogQueue = DispatchQueue(label: "DiskSteward.IPC.Deadlines", qos: .utility)
    // Poll waits must not occupy Swift's cooperative workers used by monitoring.
    // There is at most one I/O operation per admitted connection, and cancelled
    // connections keep their slots until that operation and its task finish.
    private let ioQueue = DispatchQueue(label: "DiskSteward.IPC.IO", qos: .utility, attributes: .concurrent)
    var activeConnectionCount: Int { stateLock.withLock { connections.count } }

    public convenience init(
        socketPath: String,
        handler: any DiskStewardIPCRequestHandling,
        maximumRequestBytes: Int = 1 * 1_024 * 1_024,
        maximumConnections: Int = 4,
        timeoutSeconds: TimeInterval = 10
    ) {
        self.init(socketPath: socketPath, handler: handler, maximumRequestBytes: maximumRequestBytes,
                  maximumConnections: maximumConnections, timeoutSeconds: timeoutSeconds, startupCheckpoint: { _ in })
    }

    init(socketPath: String, handler: any DiskStewardIPCRequestHandling,
         maximumRequestBytes: Int = 1 * 1_024 * 1_024, maximumConnections: Int = 4,
         timeoutSeconds: TimeInterval = 10,
         beforeAccept: @escaping @Sendable (Int32) -> Void = { _ in },
         startupCheckpoint: @escaping @Sendable (SocketStartupCheckpoint) throws -> Void) {
        self.socketPath = socketPath
        self.handler = handler
        self.maximumRequestBytes = min(max(1_024, maximumRequestBytes), 1 * 1_024 * 1_024)
        self.maximumConnections = min(16, max(1, maximumConnections))
        self.timeoutSeconds = min(60, max(0.05, timeoutSeconds))
        self.startupCheckpoint = startupCheckpoint
        self.beforeAccept = beforeAccept
    }

    deinit { stop() }

    public func start() throws {
        try stateLock.withLock {
            guard !running else { return }
            let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try secureDirectory(parent.path)
            let candidateLease = try LocalServiceLease(url: URL(fileURLWithPath: socketPath + ".lock"))
            try removeStaleSocketIfOwned(lease: candidateLease)
            let stagingDirectory = try stagingDirectoryPath()
            let stagingPath = stagingDirectory + "/s"
            guard mkdir(stagingDirectory, 0o700) == 0 || errno == EEXIST else {
                throw DiskStewardIPCError.connectionFailed(errno)
            }
            guard let directoryIdentity = DirectoryIdentity(stagingDirectory) else {
                throw DiskStewardIPCError.insecureSocket("invalid private socket staging directory")
            }
            try recoverStaging(path: stagingPath, directory: directoryIdentity, lease: candidateLease)
            try candidateLease.record(directory: directoryIdentity, endpoint: nil)
            try startupCheckpoint(.directoryJournaled)

            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
            var stagedIdentity: EndpointIdentity?
            do {
                var address = try socketAddress(path: stagingPath)
                let length = socklen_t(MemoryLayout<sa_family_t>.size + stagingPath.utf8CString.count)
                let bound = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, length)
                    }
                }
                guard bound == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
                guard let identity = EndpointIdentity(stagingPath) else { throw DiskStewardIPCError.insecureSocket("cannot identify bound endpoint") }
                stagedIdentity = identity
                try startupCheckpoint(.bound)
                guard chmod(stagingPath, 0o600) == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
                try BoundedSocketIO.configure(descriptor)
                guard Darwin.listen(descriptor, 16) == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
                try candidateLease.record(directory: directoryIdentity, endpoint: identity) {
                    try startupCheckpoint(.journalPartiallyWritten)
                }
                try startupCheckpoint(.endpointJournaled)
                guard renamex_np(stagingPath, socketPath, UInt32(RENAME_EXCL)) == 0 else {
                    throw DiskStewardIPCError.connectionFailed(errno)
                }
                endpointIdentity = identity
                stagedIdentity = nil
                try startupCheckpoint(.published)
            } catch {
                Darwin.close(descriptor)
                if let stagedIdentity, EndpointIdentity(stagingPath) == stagedIdentity { unlink(stagingPath) }
                removeOwnedEndpoint()
                throw error
            }
            listeningDescriptor = descriptor
            lease = candidateLease
            running = true
            serviceEpoch &+= 1
            let epoch = serviceEpoch
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAvailable(descriptor: descriptor, epoch: epoch) }
            // Only the cancelled source may close its listener. A restart
            // cannot reuse this descriptor until its old handler has drained.
            source.setCancelHandler { Darwin.close(descriptor) }
            listeningSource = source
            source.resume()
        }
    }

    public func stop() {
        let tasks = stateLock.withLock { () -> [Task<Void, Never>] in
            guard running else { return [] }
            running = false
            serviceEpoch &+= 1
            // Workers own close(); shutdown revokes I/O without descriptor-reuse races.
            for (descriptor, work) in connections {
                work.cancelled = true
                Darwin.shutdown(descriptor, SHUT_RDWR)
            }
            if listeningDescriptor >= 0 {
                Darwin.shutdown(listeningDescriptor, SHUT_RDWR)
                listeningSource?.cancel()
                listeningSource = nil
                listeningDescriptor = -1
            }
            removeOwnedEndpoint()
            lease = nil
            return connections.values.compactMap(\.task)
        }
        // Cancellation handlers can reenter us. Never invoke them under stateLock.
        for task in tasks { task.cancel() }
    }

    private func acceptAvailable(descriptor: Int32, epoch: UInt64) {
        beforeAccept(descriptor)
        // Bound each event's work. A nonblocking accept happens under the same
        // lock as stop, so no revoked epoch consumes a successor's connection.
        for _ in 0..<16 {
            let connection: Int32 = stateLock.withLock {
                guard running, serviceEpoch == epoch else { return -1 }
                let connection = Darwin.accept(descriptor, nil, nil)
                guard connection >= 0 else { return -1 }
                guard connections.count < maximumConnections else {
                    Darwin.close(connection)
                    return -2
                }
                let work = ConnectionWork(deadline: ProcessInfo.processInfo.systemUptime + timeoutSeconds)
                connections[connection] = work
                startWatchdogIfNeeded()
                work.task = Task { await self.serve(connection, work: work, epoch: epoch) }
                return connection
            }
            if connection == -2 { continue }
            guard connection >= 0 else { return }
        }
    }

    // Called only while holding stateLock. One timer covers the bounded registry
    // and stops entirely when idle; it does not rely on the blocked backend actor.
    private func startWatchdogIfNeeded() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(25), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.cancelExpiredOrDisconnectedWork() }
        watchdog = timer
        timer.resume()
    }

    private func cancelExpiredOrDisconnectedWork() {
        let tasks = stateLock.withLock { () -> [Task<Void, Never>] in
            let now = ProcessInfo.processInfo.systemUptime
            var tasks: [Task<Void, Never>] = []
            for (descriptor, work) in connections where !work.cancelled {
                // EOF alone may be SHUT_WR: a valid client can finish sending
                // and still await our response. HUP also detects full close
                // when unread trailing bytes remain in the receive buffer.
                // Darwin poll requires write interest to report write-side
                // hangup; read interest alone also wakes on SHUT_WR EOF.
                var peer = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&peer, 1, 0)
                let disconnected = ready > 0 && peer.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0
                if now >= work.deadline || disconnected {
                    work.cancelled = true
                    Darwin.shutdown(descriptor, SHUT_RDWR)
                    if let task = work.task { tasks.append(task) }
                }
            }
            return tasks
        }
        for task in tasks { task.cancel() }
    }

    private func serve(_ descriptor: Int32, work: ConnectionWork, epoch: UInt64) async {
        defer {
            stateLock.withLock {
                connections.removeValue(forKey: descriptor)
                work.task = nil
                Darwin.close(descriptor)
                if connections.isEmpty { watchdog?.cancel(); watchdog = nil }
            }
        }
        let deadline = work.deadline
        let revoked: @Sendable () -> Bool = { self.stateLock.withLock { work.cancelled || !self.running || self.serviceEpoch != epoch } }
        var requestID = "unknown"
        do {
            try BoundedSocketIO.configure(descriptor)
            let peer = try peerIdentity(descriptor)
            guard peer.uid == getuid() else {
                throw DiskStewardIPCError.insecureSocket("peer UID does not match the app user")
            }
            let requestData = try await socketIO {
                try BoundedSocketIO.readLine(from: descriptor, maximumBytes: self.maximumRequestBytes, deadline: deadline, isCancelled: revoked)
            }
            let request = try JSONDecoder().decode(JSONValue.self, from: requestData)
            guard let object = request.objectValue,
                  object["schema"] == .string("ipc-request-v1"),
                  let id = object["id"]?.stringValue,
                  let method = object["method"]?.stringValue,
                  let payload = object["payload"]
            else { throw DiskStewardIPCError.malformedResponse }
            requestID = id
            guard !revoked() else { throw DiskStewardIPCError.cancelled }
            try Task.checkCancellation()
            let result = try await handler.handleIPC(method: method, payload: payload, peer: peer)
            try Task.checkCancellation()
            try await send(.object([
                "schema": .string("ipc-response-v1"),
                "id": .string(id),
                "result": result,
            ]), to: descriptor, deadline: deadline, isCancelled: revoked)
        } catch {
            let code: String
            let retryable: Bool
            switch error {
            case let DiskStewardIPCError.remote(remoteCode, _, canRetry):
                code = remoteCode; retryable = canRetry
            case DiskStewardIPCError.insecureSocket:
                code = "permission_denied"; retryable = false
            case DiskStewardIPCError.responseTooLarge:
                code = "request_too_large"; retryable = true
            case DiskStewardIPCError.cancelled, is CancellationError:
                code = "cancelled"; retryable = true
            default:
                code = "request_failed"; retryable = true
            }
            try? await send(.object([
                "schema": .string("ipc-response-v1"),
                "id": .string(requestID),
                "error": .object([
                    "code": .string(code),
                    "message": .string(error.localizedDescription),
                    "retryable": .bool(retryable),
                ]),
            ]), to: descriptor, deadline: deadline, isCancelled: revoked)
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

    private func socketIO<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }

    private func send(_ value: JSONValue, to descriptor: Int32, deadline: TimeInterval, isCancelled: @escaping @Sendable () -> Bool) async throws {
        guard !isCancelled() else { throw DiskStewardIPCError.cancelled }
        var data = try JSONEncoder.diskSteward.encode(value)
        data.append(0x0A)
        guard data.count <= 4 * 1_024 * 1_024 else { throw DiskStewardIPCError.responseTooLarge }
        let frame = data
        try await socketIO { try BoundedSocketIO.write(frame, to: descriptor, deadline: deadline, isCancelled: isCancelled) }
    }

    private func socketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
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

    private func stagingDirectoryPath() throws -> String {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let adjacent = socketPath + ".stage"
        if (adjacent + "/s").utf8CString.count <= capacity { return adjacent }
        // A valid public name may use nearly all of sun_path. Use a short,
        // service-specific workspace in the nearest private ancestor instead
        // of reducing the public pathname limit by ".stage/s".
        let name = ".ds-" + SHA256Digest.hex(for: Data(socketPath.utf8)).prefix(16)
        var ancestor = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        while ancestor.path != "/" {
            let candidate = ancestor.appending(path: String(name)).path
            if (candidate + "/s").utf8CString.count <= capacity,
               DirectoryIdentity(ancestor.path) != nil {
                return candidate
            }
            ancestor.deleteLastPathComponent()
        }
        throw DiskStewardIPCError.insecureSocket("socket path has no private ancestor with room for staging")
    }

    private func secureDirectory(_ path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFDIR
        else { throw DiskStewardIPCError.insecureSocket("socket directory is not owned by the current user") }
        guard chmod(path, 0o700) == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
    }

    private func removeOwnedEndpoint() {
        if let endpointIdentity, EndpointIdentity(socketPath) == endpointIdentity { unlink(socketPath) }
        endpointIdentity = nil
    }

    private func recoverStaging(path: String, directory: DirectoryIdentity, lease: LocalServiceLease) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT { return }
            throw DiskStewardIPCError.connectionFailed(errno)
        }
        // The lease's durable directory identity precedes bind. Only this
        // single socket entry in that private workspace may be recovered.
        // Regular files, links, replaced directories and unknown workspaces
        // are never recursively cleaned or inferred to belong to the app.
        guard lease.previousRecord()?.directory == directory,
              status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFSOCK else {
            throw DiskStewardIPCError.insecureSocket("unowned entry in socket staging directory")
        }
        guard unlink(path) == 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
    }

    private func removeStaleSocketIfOwned(lease: LocalServiceLease) throws {
        var status = stat()
        guard lstat(socketPath, &status) == 0 else {
            if errno == ENOENT { return }
            throw DiskStewardIPCError.connectionFailed(errno)
        }
        guard status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFSOCK else {
            throw DiskStewardIPCError.insecureSocket("an unowned or non-socket entry occupies the socket path")
        }
        // Acquiring the lease proves the prior cooperative owner has exited.
        // Unknown/legacy endpoints are never probed or replaced: a probe closing
        // early could itself trigger SIGPIPE in an older running app.
        guard let previous = lease.previousEndpoint(), EndpointIdentity(socketPath) == previous else {
            throw DiskStewardIPCError.remote(code: "endpoint_ownership_unknown", message: "An existing endpoint is not owned by this instance. Quit the previous Disk Steward app or toggle its Agent Access off before retrying.", retryable: false)
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
