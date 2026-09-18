import Darwin
import DiskStewardCore
import Foundation
import XCTest

final class MCPTransportLifecycleTests: XCTestCase {
    private let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"# + "\n"
        + #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n"

    func testSelfCheckAlsoExitsWhenItsOutputIsNotRead() async throws {
        let fixture = try TransportFixture(drainOutput: false, arguments: ["--self-check"])
        defer { fixture.close() }
        let full = await eventually { fixture.bufferedOutputBytes > 32_000 }
        XCTAssertTrue(full)
        let exited = await eventually(timeout: 4) { !fixture.process.isRunning }
        XCTAssertTrue(exited)
        if exited { XCTAssertEqual(fixture.process.terminationReason, .exit); XCTAssertEqual(fixture.process.terminationStatus, 1) }
    }

    func testBlockedStdoutStillProcessesCancellationAndExitsWithoutMoreInput() async throws {
        let fixture = try TransportFixture(drainOutput: false)
        defer { fixture.close() }
        try fixture.send(initialize + call(2, "get_storage_summary") + call(3, "get_evidence_lifecycle"))
        let fullPipe = await eventually { fixture.bufferedOutputBytes > 32_000 && fixture.handler.started == 1 }
        XCTAssertTrue(fullPipe, "The real child output pipe must be full before cancellation")
        try fixture.send(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"# + "\n"
            + #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"# + "\n")
        let cancelled = await eventually(timeout: 1) { fixture.handler.cancelled == 1 }
        XCTAssertTrue(cancelled, "A blocked stdout writer must not block stdin cancellation")
        let exited = await eventually(timeout: 4) { !fixture.process.isRunning }
        XCTAssertTrue(exited, "Output failure must wake input even while stdin remains open")
        if exited { XCTAssertEqual(fixture.process.terminationReason, .exit); XCTAssertEqual(fixture.process.terminationStatus, 1) }
    }

    func testEOFHasFiniteGraceAndCancelsBackendWork() async throws {
        let fixture = try TransportFixture(drainOutput: true)
        defer { fixture.close() }
        try fixture.send(initialize + call(2, "get_evidence_lifecycle"))
        let started = await eventually { fixture.handler.started == 1 }
        XCTAssertTrue(started)
        try fixture.input.fileHandleForWriting.close()
        let exited = await eventually(timeout: 3) { !fixture.process.isRunning }
        XCTAssertTrue(exited)
        let cancelled = await eventually { fixture.handler.cancelled == 1 }
        XCTAssertTrue(cancelled)
        if exited { XCTAssertEqual(fixture.process.terminationReason, .exit); XCTAssertEqual(fixture.process.terminationStatus, 1) }
    }

    func testClosedStdoutTerminatesNormallyInsteadOfSIGPIPE() async throws {
        let fixture = try TransportFixture(drainOutput: false)
        defer { fixture.close() }
        try fixture.output.fileHandleForReading.close()
        try fixture.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n")
        let exited = await eventually(timeout: 3) { !fixture.process.isRunning }
        XCTAssertTrue(exited)
        if exited { XCTAssertEqual(fixture.process.terminationReason, .exit); XCTAssertEqual(fixture.process.terminationStatus, 1) }
    }

    func testOversizedLineIsDiscardedAndNextFrameIsProcessed() async throws {
        let fixture = try TransportFixture(drainOutput: true)
        defer { fixture.close() }
        try fixture.send(String(repeating: "x", count: 1_024 * 1_024 + 1) + "\n" + #"{"jsonrpc":"2.0","id":9,"method":"ping"}"# + "\n")
        try fixture.input.fileHandleForWriting.close()
        let exited = await eventually(timeout: 3) { !fixture.process.isRunning && fixture.outputFinished }
        XCTAssertTrue(exited)
        XCTAssertTrue(fixture.stdout.contains("Request exceeds 1 MiB"))
        XCTAssertTrue(fixture.stdout.contains(#""id":9"#))
        XCTAssertEqual(fixture.handler.started, 0)
        if exited { XCTAssertEqual(fixture.process.terminationStatus, 0) }
    }

    func testFourCallsAreBoundedAndCancellationFreesCapacity() async throws {
        let fixture = try TransportFixture(drainOutput: true)
        defer { fixture.close() }
        var transcript = initialize
        for id in 100..<228 { transcript += #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(id)}}"# + "\n" }
        for id in 2..<6 { transcript += call(id, "get_evidence_lifecycle") }
        try fixture.send(transcript)
        let started = await eventually { fixture.handler.started == 4 }
        XCTAssertTrue(started)
        try fixture.send(call(6, "get_evidence_lifecycle") + #"{"jsonrpc":"2.0","id":7,"method":"ping"}"# + "\n")
        let overloaded = await eventually { fixture.stdout.contains("-32000") && fixture.stdout.contains(#""id":7"#) }
        XCTAssertTrue(overloaded, fixture.stdout)
        XCTAssertEqual(fixture.handler.started, 4)
        try fixture.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"# + "\n")
        let cancelled = await eventually { fixture.handler.cancelled == 1 }
        XCTAssertTrue(cancelled)
        try fixture.send(call(8, "list_active_agent_sessions"))
        let resumed = await eventually { fixture.stdout.contains("fixture-fast") }
        XCTAssertTrue(resumed, fixture.stdout)
        XCTAssertFalse(fixture.stdout.contains(#""id":2,"#), "Cancelled request must have no response")
        try fixture.input.fileHandleForWriting.close()
        let exited = await eventually(timeout: 3) { !fixture.process.isRunning }
        XCTAssertTrue(exited)
        let allCancelled = await eventually { fixture.handler.cancelled == 4 }
        XCTAssertTrue(allCancelled)
    }

    private func call(_ id: Int, _ name: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":{}}}"# + "\n"
    }

    private func eventually(timeout: TimeInterval = 2, _ predicate: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return predicate()
    }
}

private final class TransportFixture: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let handler = TransportHandler()
    private let errorOutput = Pipe()
    private let root: URL
    private let server: UnixSocketEvidenceServer
    private let lock = NSLock()
    private let readers = DispatchGroup()
    private var captured = Data()
    private var didFinishOutput = false
    var stdout: String { lock.withLock { String(decoding: captured, as: UTF8.self) } }
    var outputFinished: Bool { lock.withLock { didFinishOutput } }
    var bufferedOutputBytes: Int32 {
        var bytes: Int32 = 0
        // Darwin _IOR('f', 127, int); the SDK macro is not imported by Swift.
        let fionread = UInt(0x4000_0000 | (MemoryLayout<Int32>.size << 16) | (0x66 << 8) | 127)
        _ = ioctl(output.fileHandleForReading.fileDescriptor, fionread, &bytes)
        return bytes
    }

    init(drainOutput: Bool, arguments: [String] = []) throws {
        root = URL(fileURLWithPath: "/private/tmp/ds-stdio-\(UUID().uuidString.prefix(8))")
        server = UnixSocketEvidenceServer(socketPath: root.appending(path: "s").path, handler: handler, timeoutSeconds: 15)
        try server.start()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = repository.appending(path: ".build/debug/disk-witness-mcp").resolvingSymlinksInPath()
        // Never invoke an installed or externally overridden helper in this suite.
        guard executable.path.hasPrefix(repository.resolvingSymlinksInPath().path + "/.build/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw CocoaError(.fileNoSuchFile) }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "DISK_STEWARD_SOCKET_PATH": server.socketPath]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        try errorOutput.fileHandleForWriting.close()
        let descriptor = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        if drainOutput {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { self.readers.leave() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let count = Darwin.read(self.output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    self.lock.withLock { if self.captured.count + count <= 2 * 1_024 * 1_024 { self.captured.append(contentsOf: buffer.prefix(count)) } }
                }
                self.lock.withLock { self.didFinishOutput = true }
            }
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { self.readers.leave() }
            while let data = try? self.errorOutput.fileHandleForReading.read(upToCount: 4_096), !data.isEmpty {}
        }
    }

    func send(_ text: String) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        try Data(text.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileWriteUnknown) }
                var item = pollfd(fd: input.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&item, 1, 20)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0, item.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { throw CocoaError(.fileWriteUnknown) }
                let count = Darwin.write(item.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EAGAIN || errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        server.stop()
        _ = readers.wait(timeout: .now() + 1)
        try? output.fileHandleForReading.close()
        try? errorOutput.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class TransportHandler: DiskStewardIPCRequestHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var cancellations = 0
    var started: Int { lock.withLock { starts } }
    var cancelled: Int { lock.withLock { cancellations } }
    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        switch payload.objectValue?["name"]?.stringValue {
        case "get_storage_summary": return .object(["schema": .string("fixture-big"), "blob": .string(String(repeating: "x", count: 500_000))])
        case "get_evidence_lifecycle":
            lock.withLock { starts += 1 }
            do { try await Task.sleep(for: .seconds(8)) }
            catch { lock.withLock { cancellations += 1 }; throw error }
            return .string("unexpected late result")
        default: return .object(["schema": .string("fixture-fast")])
        }
    }
}
