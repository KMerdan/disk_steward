import Darwin
@testable import DiskStewardCore
import Foundation
import XCTest

final class RequestCancellationTests: XCTestCase {
    func testSlowPeersDoNotStarveEvidenceStoreOnConstrainedExecutor() async throws {
        for mode in ["idle", "partial", "nonreading"] {
            let root = URL(fileURLWithPath: "/private/tmp/ds541-pool-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("fixture-only".utf8).write(to: root.appending(path: "sentinel"))
            let output = root.appending(path: "child.log")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let log = try FileHandle(forWritingTo: output)
            defer { try? log.close() }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", "DiskStewardAppTests.RequestCancellationTests/testConstrainedExecutorProcessFixture", Bundle(for: Self.self).bundleURL.path]
            child.environment = ["PATH": "/usr/bin:/bin", "LIBDISPATCH_COOPERATIVE_POOL_STRICT": "1",
                                 "DISK_STEWARD_POOL_FIXTURE": root.path, "DISK_STEWARD_POOL_MODE": mode]
            child.standardOutput = log
            child.standardError = log
            let ended = expectation(description: "\(mode) constrained executor fixture exits")
            child.terminationHandler = { _ in ended.fulfill() }
            try child.run()
            defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
            await fulfillment(of: [ended], timeout: 12)
            guard !child.isRunning else { return XCTFail("Constrained executor fixture timed out") }
            XCTAssertEqual(child.terminationStatus, 0, "\(mode): \((try? String(contentsOf: output, encoding: .utf8)) ?? "no fixture output")")
        }
    }

    // A synchronous child test leaves its main thread outside the cooperative
    // pool. Strict mode exposes waits that consume the pool's limited workers.
    func testConstrainedExecutorProcessFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DISK_STEWARD_POOL_FIXTURE"] else { return }
        let root = URL(fileURLWithPath: path)
        var metadata = stat()
        guard path.hasPrefix("/private/tmp/ds541-pool-"), !path.contains(".."),
              lstat(path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o077 == 0,
              try String(contentsOf: root.appending(path: "sentinel"), encoding: .utf8) == "fixture-only"
        else { return XCTFail("Refused non-private executor fixture") }
        let mode = ProcessInfo.processInfo.environment["DISK_STEWARD_POOL_MODE"] ?? "idle"
        let store = try EvidenceStore(url: root.appending(path: "fixture.sqlite"))
        let server = UnixSocketEvidenceServer(socketPath: root.appending(path: "s").path,
                                              handler: LargeEcho(), maximumConnections: 4, timeoutSeconds: 4)
        try server.start()
        var peers: [Int32] = []
        defer { server.stop(); for peer in peers { Darwin.close(peer) } }
        for _ in 0..<4 {
            let peer = try rawConnection(server.socketPath)
            peers.append(peer)
            if mode == "partial" || mode == "nonreading" {
                let data = mode == "partial" ? Data("{".utf8) : requestData()
                try BoundedSocketIO.write(data, to: peer, deadline: ProcessInfo.processInfo.systemUptime + 1, isCancelled: { false })
            }
        }
        let admittedBy = ProcessInfo.processInfo.systemUptime + 1
        while server.activeConnectionCount != 4, ProcessInfo.processInfo.systemUptime < admittedBy { usleep(5_000) }
        XCTAssertEqual(server.activeConnectionCount, 4)
        // Allow admitted tasks to enter their waits before scheduling store work.
        usleep(150_000)
        let completed = DispatchSemaphore(value: 0)
        let query = Task.detached(priority: .utility) {
            let events = try await store.events(from: .distantPast, through: .distantFuture)
            await store.close()
            if events.isEmpty { completed.signal() }
        }
        let progressed = completed.wait(timeout: .now() + 1) == .success
        XCTAssertTrue(progressed, "\(mode) socket waits must suspend, not monopolize the cooperative executor")
        if progressed { XCTAssertEqual(server.activeConnectionCount, 4, "Store work must finish while all slow peers are still admitted") }
        server.stop()
        if !progressed { XCTAssertEqual(completed.wait(timeout: .now() + 3), .success) }
        withExtendedLifetime(query) {}
    }

    func testWriteHalfCloseStillAllowsResponse() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/ds-half-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = UnixSocketEvidenceServer(socketPath: root.appending(path: "s").path, handler: DelayedEcho(), timeoutSeconds: 2)
        try server.start()
        defer { server.stop() }
        let descriptor = try rawConnection(server.socketPath)
        defer { Darwin.close(descriptor) }
        try BoundedSocketIO.write(requestData(), to: descriptor, deadline: ProcessInfo.processInfo.systemUptime + 1, isCancelled: { false })
        XCTAssertEqual(shutdown(descriptor, SHUT_WR), 0)
        let response = try BoundedSocketIO.readLine(from: descriptor, maximumBytes: 4_096, deadline: ProcessInfo.processInfo.systemUptime + 1, isCancelled: { false })
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("alive"))
    }

    func testDisconnectWithUnreadTrailingBytesStillCancelsWork() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/ds-trailer-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = CancellationHandler()
        let server = UnixSocketEvidenceServer(socketPath: root.appending(path: "s").path, handler: handler, timeoutSeconds: 3)
        try server.start()
        defer { server.stop() }
        let descriptor = try rawConnection(server.socketPath)
        try BoundedSocketIO.write(requestData(), to: descriptor, deadline: ProcessInfo.processInfo.systemUptime + 1, isCancelled: { false })
        let began = await eventually { handler.started == 1 }
        XCTAssertTrue(began)
        // Queue the trailer after the handler starts, proving these bytes were
        // not consumed in readLine's first buffer; stay below socket capacity.
        try BoundedSocketIO.write(Data(repeating: 120, count: 1_024), to: descriptor,
                                  deadline: ProcessInfo.processInfo.systemUptime + 1, isCancelled: { false })
        Darwin.close(descriptor)
        let cancelled = await eventually { handler.cancelled == 1 }
        XCTAssertTrue(cancelled)
        let drained = await eventually(timeout: 3) { handler.finished == 1 }
        XCTAssertTrue(drained)
    }

    private func requestData() -> Data {
        Data((#"{"schema":"ipc-request-v1","id":"fixture","method":"tools/call","payload":{"name":"slow","arguments":{}}}"# + "\n").utf8)
    }

    private func rawConnection(_ path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DiskStewardIPCError.connectionFailed(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { target in
                for (index, byte) in bytes.enumerated() { target[index] = byte }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)) }
        }
        guard result == 0 else { Darwin.close(descriptor); throw DiskStewardIPCError.connectionFailed(errno) }
        try BoundedSocketIO.configure(descriptor)
        return descriptor
    }

    func testRevokedUncooperativeWorkStaysCountedAcrossRestarts() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/ds-held-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = HeldHandler()
        let server = UnixSocketEvidenceServer(socketPath: root.appending(path: "s").path, handler: handler, maximumConnections: 1)
        try server.start()
        defer { server.stop(); handler.release() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: server.socketPath, timeoutSeconds: 1)
        let request = Task.detached { try? client.call(tool: "slow", arguments: [:], isCancelled: { false }) }
        let began = await eventually { handler.started }
        XCTAssertTrue(began)
        for _ in 0..<20 {
            server.stop()
            try server.start()
            XCTAssertEqual(server.activeConnectionCount, 1, "Revoke cannot forget work that ignores cancellation")
            let rejected = await Task.detached { try? client.call(tool: "fast", arguments: [:], isCancelled: { false }) }.value
            XCTAssertNil(rejected)
        }
        handler.release()
        let response = await request.value
        XCTAssertNil(response, "The old epoch cannot publish its late result")
        let drained = await eventually { server.activeConnectionCount == 0 }
        XCTAssertTrue(drained)
        let next = try await Task.detached { try client.call(tool: "fast", arguments: [:], isCancelled: { false }) }.value
        XCTAssertEqual(next, .string("alive"))
    }

    func testDeadlineCancelsActualHandlerWork() async throws {
        try await assertCancellation(trigger: .deadline)
    }

    func testDisconnectCancelsActualHandlerWork() async throws {
        try await assertCancellation(trigger: .disconnect)
    }

    func testStopCancelsActualHandlerWorkAndRestartCanServe() async throws {
        try await assertCancellation(trigger: .stop)
    }

    private enum Trigger { case deadline, disconnect, stop }

    private func assertCancellation(trigger: Trigger) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/ds-cancel-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = CancellationHandler()
        let server = UnixSocketEvidenceServer(socketPath: root.appending(path: "s").path, handler: handler,
                                              maximumConnections: 1, timeoutSeconds: trigger == .deadline ? 0.2 : 3)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: server.socketPath, timeoutSeconds: 3)
        let abandoned = CancellationFlag()
        let request = Task.detached { try? client.call(tool: "slow", arguments: [:], isCancelled: { abandoned.value }) }
        let began = await eventually { handler.started == 1 }
        XCTAssertTrue(began)
        switch trigger {
        case .deadline: break
        case .disconnect: abandoned.set()
        case .stop: server.stop()
        }
        let stopped = await eventually { handler.cancelled == 1 }
        XCTAssertTrue(stopped, "The backend must observe cancellation within one second")
        _ = await request.value
        // Drain the deliberately finite fixture even against the unfixed server.
        let drained = await eventually(timeout: 3) { handler.finished == 1 }
        XCTAssertTrue(drained)
        if trigger == .stop { try server.start() }
        let next = try await Task.detached { try client.call(tool: "fast", arguments: [:], isCancelled: { false }) }.value
        XCTAssertEqual(next, .string("alive"))
    }

    private func eventually(timeout: TimeInterval = 1, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}

private struct DelayedEcho: DiskStewardIPCRequestHandling {
    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        try await Task.sleep(for: .milliseconds(100))
        return .string("alive")
    }
}

private struct LargeEcho: DiskStewardIPCRequestHandling {
    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        .string(String(repeating: "x", count: 2 * 1_024 * 1_024))
    }
}

private final class HeldHandler: DiskStewardIPCRequestHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var started: Bool { lock.withLock { continuation != nil } }
    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume()
    }
    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        if payload.objectValue?["name"] == .string("slow") {
            await withCheckedContinuation { value in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { return true }
                    continuation = value
                    return false
                }
                if resumeNow { value.resume() }
            }
        }
        return .string("alive")
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class CancellationHandler: DiskStewardIPCRequestHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (started: 0, cancelled: 0, finished: 0)
    var started: Int { lock.withLock { counts.started } }
    var cancelled: Int { lock.withLock { counts.cancelled } }
    var finished: Int { lock.withLock { counts.finished } }
    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        guard payload.objectValue?["name"] == .string("slow") else { return .string("alive") }
        lock.withLock { counts.started += 1 }
        defer { lock.withLock { counts.finished += 1 } }
        do { try await Task.sleep(for: .seconds(2)) }
        catch { lock.withLock { counts.cancelled += 1 }; throw error }
        return .string("too late")
    }
}
