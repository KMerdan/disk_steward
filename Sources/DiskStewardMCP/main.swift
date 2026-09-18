import DiskStewardCore
import Foundation
import Darwin

let environment = ProcessInfo.processInfo.environment
let overriddenSocketPath = environment["DISK_STEWARD_SOCKET_PATH"]
let socketPath = overriddenSocketPath ?? UnixSocketDiskStewardIPCClient.defaultSocketPath()
let stateURL = environment["DISK_STEWARD_AGENT_ACCESS_STATE_PATH"].map(URL.init(fileURLWithPath:))
    ?? (overriddenSocketPath == nil ? AgentAccessStateFile.defaultURL() : nil)
let server = MCPServer(client: UnixSocketDiskStewardIPCClient(socketPath: socketPath, accessStateURL: stateURL))
signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.contains("--self-check") {
    // The self-check answers with a report the app can bind to this exact
    // binary: the helper's own executable identity, the socket it resolved and
    // what it found there. No session is registered and no task is inferred.
    let output = StdioDispatcher(server: server)
    let response = server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"self-check","version":"1"}}}"#)
    output.write(response)
    guard response != nil else { exit(1) }
    let identity = SelfCheckReport.executableIdentity()
    var report = SelfCheckReport(helper: .init(path: identity.path, identity: identity.identity), socket: socketPath, app: "error", evidence: nil, error: nil)
    var connected = false
    do {
        let result = try UnixSocketDiskStewardIPCClient(socketPath: socketPath, accessStateURL: stateURL)
            .call(tool: "get_storage_summary", arguments: [:], isCancelled: { false })
        let encoded = try JSONEncoder.diskSteward.encode(result)
        output.write(String(decoding: encoded, as: UTF8.self))
        report.app = "connected"
        report.evidence = SelfCheckReport.evidence(from: encoded)
        connected = true
    } catch let error as DiskStewardIPCError {
        switch error {
        case .agentAccessDisabled: report.app = "access-off"
        case .appUnavailable: report.app = "app-off"
        case .insecureSocket: report.app = "insecure-socket"
        default: report.app = "error"
        }
        report.error = error.localizedDescription
    } catch {
        report.error = error.localizedDescription
    }
    output.write(report.encoded())
    if !connected {
        let diagnostics = StdioDispatcher(server: server, output: STDERR_FILENO)
        diagnostics.write(report.error ?? report.app)
        _ = diagnostics.finish()
    }
    exit(output.finish() && connected ? 0 : 1)
}

struct SelfCheckReport: Encodable {
    struct Helper: Encodable { let path: String; let identity: String? }
    struct Evidence: Encodable { let observedAt: String?; let ageSeconds: Double?; let persisted: Bool }
    let schema = "disk-steward-self-check-v1"
    let helper: Helper
    let socket: String
    var app: String
    var evidence: Evidence?
    var error: String?

    static func executableIdentity() -> (path: String, identity: String?) {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var value = stat()
        guard stat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return (path, nil) }
        return (path, "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)")
    }

    /// Freshness is the newest persisted observation the app reports under
    /// `StorageSummaryContract.persistedStateAsOf`, never the moment the live
    /// volume figures were sampled. A null value means nothing has been
    /// persisted yet, and the report says so instead of claiming freshness.
    static func evidence(from encoded: Data) -> Evidence? {
        guard let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return nil }
        guard let text = object[StorageSummaryContract.persistedStateAsOf] as? String else {
            return Evidence(observedAt: nil, ageSeconds: nil, persisted: false)
        }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        return Evidence(observedAt: text, ageSeconds: date.map { max(0, Date().timeIntervalSince($0)) }, persisted: true)
    }

    func encoded() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"schema\":\"disk-steward-self-check-v1\",\"app\":\"error\"}"
    }
}

// The input thread never writes stdout or waits for an evidence request. One
// writer owns framing; a failed partial frame terminates the entire transport.
final class StdioDispatcher: @unchecked Sendable {
    private let server: MCPServer
    private let outputLock = NSLock()
    private struct Frame { let data: Data; let deadline: TimeInterval }
    private var frames: [Frame] = []
    private var pendingBytes = 0
    private var pendingFrames = 0
    private var writing = false
    private var failed = false
    private var activeWorkers = 0
    private let output: Int32
    private let outputTimeout: TimeInterval
    private let eofGrace: TimeInterval
    private let writerQueue = DispatchQueue(label: "DiskSteward.MCP.Stdout", qos: .utility)
    private let writerGroup = DispatchGroup()
    static let maximumQueuedBytes = 8 * 1_024 * 1_024
    // MCPServer limits JSON payload bytes; the wire frame adds exactly one LF.
    static let maximumFrameBytes = 4 * 1_024 * 1_024 + 1

    init(server: MCPServer, output: Int32 = STDOUT_FILENO, outputTimeout: TimeInterval = 2, eofGrace: TimeInterval = 1) {
        self.server = server
        self.output = output
        self.outputTimeout = min(10, max(0.05, outputTimeout))
        self.eofGrace = min(10, max(0.05, eofGrace))
        if fcntl(output, F_SETFL, fcntl(output, F_GETFL) | O_NONBLOCK) < 0 { failTransport() }
    }

    var hasFailed: Bool { outputLock.withLock { failed } }
    var queuedBytes: Int { outputLock.withLock { pendingBytes } }
    private var workersInFlight: Int { outputLock.withLock { activeWorkers } }

    private func failTransport() {
        outputLock.withLock {
            failed = true
            frames.removeAll()
            pendingBytes = 0
            pendingFrames = 0
        }
        server.cancelAll()
    }

    func write(_ response: String?) {
        guard let response else { return }
        guard response.utf8.count < Self.maximumFrameBytes else { failTransport(); return }
        let frame = Frame(data: Data((response + "\n").utf8), deadline: ProcessInfo.processInfo.systemUptime + outputTimeout)
        var launchWriter = false
        let accepted = outputLock.withLock {
            guard !failed, pendingFrames < 8, frame.data.count <= Self.maximumQueuedBytes - pendingBytes else { return false }
            frames.append(frame)
            pendingBytes += frame.data.count
            pendingFrames += 1
            if !writing { writing = true; launchWriter = true }
            return true
        }
        guard accepted else { failTransport(); return }
        if launchWriter {
            writerGroup.enter()
            writerQueue.async { defer { self.writerGroup.leave() }; self.drainOutput() }
        }
    }

    private func drainOutput() {
        while true {
            let frame = outputLock.withLock { () -> Frame? in
                guard !failed, !frames.isEmpty else { writing = false; return nil }
                return frames.removeFirst()
            }
            guard let frame else { return }
            let success = frame.data.withUnsafeBytes { buffer -> Bool in
                guard let base = buffer.baseAddress else { return true }
                var offset = 0
                while offset < buffer.count {
                    guard !hasFailed, ProcessInfo.processInfo.systemUptime < frame.deadline else { return false }
                    var descriptor = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&descriptor, 1, 25)
                    if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                    guard ready > 0, descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { return false }
                    let count = Darwin.write(output, base.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EAGAIN || errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            guard success else { failTransport(); return }
            outputLock.withLock {
                if !failed { pendingBytes -= frame.data.count; pendingFrames -= 1 }
            }
        }
    }

    func accept(_ line: String) {
        guard !hasFailed else { return }
        switch server.prepare(line: line) {
        case .response(let response): write(response)
        case .request(let request):
            outputLock.withLock { activeWorkers += 1 }
            DispatchQueue.global(qos: .utility).async {
                defer { self.outputLock.withLock { self.activeWorkers -= 1 } }
                self.write(self.server.perform(request))
            }
        }
    }

    func finish() -> Bool {
        // EOF supports ordinary batch transcripts, but cannot wait forever for
        // a hung backend or a parent that stopped reading the output pipe.
        let graceDeadline = ProcessInfo.processInfo.systemUptime + eofGrace
        while workersInFlight > 0, !hasFailed, ProcessInfo.processInfo.systemUptime < graceDeadline { usleep(5_000) }
        if workersInFlight > 0 { failTransport() }
        let drainDeadline = ProcessInfo.processInfo.systemUptime + outputTimeout
        while queuedBytes > 0, !hasFailed, ProcessInfo.processInfo.systemUptime < drainDeadline { usleep(5_000) }
        if queuedBytes > 0 { failTransport() }
        if writerGroup.wait(timeout: .now() + outputTimeout) == .timedOut { failTransport() }
        return !hasFailed
    }

    func run(input: Int32 = STDIN_FILENO) -> Int32 {
        guard fcntl(input, F_SETFL, fcntl(input, F_GETFL) | O_NONBLOCK) >= 0 else { failTransport(); return 1 }
        var pendingLine = Data()
        var droppingOversizedLine = false
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while !hasFailed {
            var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0, descriptor.revents & Int16(POLLNVAL) == 0 else { failTransport(); break }
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            if count == 0 { break }
            guard count > 0 else { failTransport(); break }
            for byte in buffer.prefix(count) {
                if hasFailed { break }
                if byte == 0x0A {
                    if !droppingOversizedLine { accept(String(decoding: pendingLine, as: UTF8.self)) }
                    pendingLine.removeAll(keepingCapacity: true)
                    droppingOversizedLine = false
                } else if !droppingOversizedLine {
                    if pendingLine.count == 1_024 * 1_024 {
                        pendingLine.removeAll(keepingCapacity: true)
                        droppingOversizedLine = true
                        write(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Request exceeds 1 MiB"}}"#)
                    } else { pendingLine.append(byte) }
                }
            }
        }
        if !pendingLine.isEmpty, !droppingOversizedLine, !hasFailed { accept(String(decoding: pendingLine, as: UTF8.self)) }
        return finish() ? 0 : 1
    }
}

let dispatcher = StdioDispatcher(server: server)
exit(dispatcher.run())
