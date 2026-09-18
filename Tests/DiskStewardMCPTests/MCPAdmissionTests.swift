import DiskStewardCore
@testable import DiskStewardMCP
import Foundation
import XCTest

final class MCPAdmissionTests: XCTestCase {
    func testAdmissionBoundsDuplicateIDsAndCancelBeforeDispatch() {
        let client = GatedIPCClient(block: false)
        let server = initialized(client)
        var admitted: [MCPServer.Request] = []
        for id in 10..<14 {
            guard case .request(let token) = server.prepare(line: request(id)) else { return XCTFail("not admitted") }
            admitted.append(token)
        }
        XCTAssertEqual(server.activeRequestCount, 4)
        guard case .response(let overloaded) = server.prepare(line: request(14)) else { return XCTFail("capacity bypass") }
        XCTAssertTrue(overloaded?.contains("-32000") == true)
        guard case .response(let duplicate) = server.prepare(line: request(10)) else { return XCTFail("duplicate admitted") }
        XCTAssertTrue(duplicate?.contains("Duplicate active request ID") == true)
        for method in ["ping", "initialize", "tools/list", "resources/list"] {
            let response = server.handle(line: #"{"jsonrpc":"2.0","id":10,"method":"\#(method)","params":{}}"#)
            XCTAssertTrue(response?.contains("Duplicate active request ID") == true, method)
        }
        cancel(10, on: server)
        XCTAssertEqual(server.activeRequestCount, 4, "Cancelled work counts until drained")
        XCTAssertNil(server.perform(admitted.removeFirst()))
        XCTAssertEqual(client.calls, 0)
        XCTAssertEqual(server.activeRequestCount, 3)
        XCTAssertTrue(server.handle(line: request(10))?.contains("fixture-success") == true)
        for token in admitted { XCTAssertNotNil(server.perform(token)) }
        XCTAssertEqual(server.activeRequestCount, 0)
    }

    func testCancellationCanWinAfterSerializationBeforeTerminalClaim() async {
        let gate = TerminalGate()
        defer { gate.release() }
        let server = MCPServer(client: GatedIPCClient(block: false), beforeTerminalClaim: { gate.wait() })
        _ = server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        let line = request(7)
        let work = Task.detached { server.handle(line: line) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !gate.started, ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(gate.started)
        cancel(7, on: server)
        gate.release()
        let result = await work.value
        XCTAssertNil(result)
        XCTAssertEqual(server.activeRequestCount, 0)
        let completionWon = server.handle(line: request(8))
        cancel(8, on: server)
        XCTAssertTrue(completionWon?.contains("fixture-success") == true)
        XCTAssertTrue(server.handle(line: request(8))?.contains("fixture-success") == true)
    }

    func testTransportFailureCancelsEveryAdmittedRequestAndClosesAdmission() {
        let client = GatedIPCClient(block: false)
        let server = initialized(client)
        guard case .request(let request) = server.prepare(line: self.request(7)) else { return XCTFail("not admitted") }
        server.cancelAll()
        XCTAssertNil(server.perform(request))
        XCTAssertEqual(client.calls, 0)
        XCTAssertEqual(server.activeRequestCount, 0)
        guard case .response(let response) = server.prepare(line: self.request(8)) else { return XCTFail("closed transport admitted work") }
        XCTAssertTrue(response?.contains("-32000") == true)
    }

    func testUnknownCancellationDoesNotCancelFutureRequest() {
        let client = GatedIPCClient(block: false)
        let server = initialized(client)
        cancel(7, on: server)
        let result = server.handle(line: request(7))
        XCTAssertTrue(result?.contains("fixture-success") == true)
        XCTAssertEqual(client.calls, 1)
    }

    func testUnknownCancellationFloodCannotPreventActiveCancellation() async {
        let client = GatedIPCClient(block: true)
        let server = initialized(client)
        for id in 100..<300 { cancel(id, on: server) }
        let requestLine = request(7)
        let work = Task.detached { server.handle(line: requestLine) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while client.calls == 0, ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(client.calls, 1)
        cancel(7, on: server)
        let result = await work.value
        XCTAssertTrue(client.sawCancellation)
        XCTAssertNil(result, "Explicit cancellation suppresses the response even if IPC returns a late value")
        client.unblock()
        cancel(7, on: server) // Late notification cannot poison ID reuse.
        XCTAssertTrue(server.handle(line: request(7))?.contains("fixture-success") == true)
    }

    private func initialized(_ client: GatedIPCClient) -> MCPServer {
        let server = MCPServer(client: client)
        _ = server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        _ = server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        return server
    }

    private func request(_ id: Int) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"get_storage_summary","arguments":{}}}"#
    }
    private func cancel(_ id: Int, on server: MCPServer) {
        _ = server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(id)}}"#)
    }
}

private final class TerminalGate: @unchecked Sendable {
    private let lock = NSLock()
    private let barrier = DispatchSemaphore(value: 0)
    private var waiting = false
    private var released = false
    var started: Bool { lock.withLock { waiting } }
    func wait() {
        let shouldWait = lock.withLock { waiting = true; return !released }
        if shouldWait { _ = barrier.wait(timeout: .now() + 2) }
    }
    func release() { lock.withLock { released = true }; barrier.signal() }
}

private final class GatedIPCClient: DiskStewardIPCClient, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldBlock: Bool
    private var callCount = 0
    private var cancelled = false
    init(block: Bool) { shouldBlock = block }
    var calls: Int { lock.withLock { callCount } }
    var sawCancellation: Bool { lock.withLock { cancelled } }
    func unblock() { lock.withLock { shouldBlock = false } }
    func call(tool: String, arguments: [String: JSONValue], isCancelled: @Sendable () -> Bool) throws -> JSONValue {
        lock.withLock { callCount += 1 }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while lock.withLock({ shouldBlock }), ProcessInfo.processInfo.systemUptime < deadline {
            if isCancelled() { lock.withLock { cancelled = true }; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return .object(["schema": .string("fixture-success")])
    }
    func readResource(uri: String, isCancelled: @Sendable () -> Bool) throws -> JSONValue {
        try call(tool: uri, arguments: [:], isCancelled: isCancelled)
    }
}
