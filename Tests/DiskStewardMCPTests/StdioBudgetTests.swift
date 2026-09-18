import DiskStewardCore
@testable import DiskStewardMCP
import Foundation
import XCTest

final class StdioBudgetTests: XCTestCase {
    func testEightFrameLimitCountsTheStalledCurrentFrame() {
        let pipe = Pipe()
        let dispatcher = StdioDispatcher(server: MCPServer(client: UnusedIPC()), output: pipe.fileHandleForWriting.fileDescriptor, outputTimeout: 1)
        dispatcher.write(String(repeating: "x", count: 2 * 1_024 * 1_024))
        for _ in 0..<7 { dispatcher.write("{}") }
        XCTAssertFalse(dispatcher.hasFailed)
        XCTAssertLessThan(dispatcher.queuedBytes, StdioDispatcher.maximumQueuedBytes)
        dispatcher.write("{}")
        XCTAssertTrue(dispatcher.hasFailed, "The ninth frame exceeds the count cap even below the byte cap")
        XCTAssertFalse(dispatcher.finish())
    }

    func testExactFourMiBPayloadIsAcceptedWithItsFramingNewline() {
        let pipe = Pipe()
        let server = MCPServer(client: UnusedIPC())
        let dispatcher = StdioDispatcher(server: server, output: pipe.fileHandleForWriting.fileDescriptor, outputTimeout: 1)
        dispatcher.write(String(repeating: "x", count: 4 * 1_024 * 1_024))
        XCTAssertFalse(dispatcher.hasFailed, "A valid maximum-size JSON payload must not fail just because framing adds LF")
        XCTAssertEqual(dispatcher.queuedBytes, 4 * 1_024 * 1_024 + 1)
        // End the intentionally undrained transport without waiting its deadline.
        dispatcher.write(String(repeating: "x", count: StdioDispatcher.maximumFrameBytes))
        XCTAssertFalse(dispatcher.finish())
    }

    func testNonReadingPipeCannotGrowResponseQueueBeyondBudget() {
        let pipe = Pipe()
        let server = MCPServer(client: UnusedIPC())
        let dispatcher = StdioDispatcher(server: server, output: pipe.fileHandleForWriting.fileDescriptor, outputTimeout: 0.1)
        let frame = String(repeating: "x", count: 3 * 1_024 * 1_024)
        for _ in 0..<3 {
            dispatcher.write(frame)
            XCTAssertLessThanOrEqual(dispatcher.queuedBytes, StdioDispatcher.maximumQueuedBytes)
        }
        XCTAssertTrue(dispatcher.hasFailed, "The current frame counts toward the byte cap")
        XCTAssertFalse(dispatcher.finish())
    }

    func testFrameLimitAppliesToEveryResponseIncludingControlMessages() {
        let pipe = Pipe()
        let server = MCPServer(client: UnusedIPC())
        let dispatcher = StdioDispatcher(server: server, output: pipe.fileHandleForWriting.fileDescriptor, outputTimeout: 0.1)
        dispatcher.write(String(repeating: "x", count: StdioDispatcher.maximumFrameBytes))
        XCTAssertTrue(dispatcher.hasFailed)
        XCTAssertEqual(dispatcher.queuedBytes, 0)
        XCTAssertFalse(dispatcher.finish())
    }
}

private struct UnusedIPC: DiskStewardIPCClient {
    func call(tool: String, arguments: [String: JSONValue], isCancelled: @Sendable () -> Bool) throws -> JSONValue { throw DiskStewardIPCError.appUnavailable }
    func readResource(uri: String, isCancelled: @Sendable () -> Bool) throws -> JSONValue { throw DiskStewardIPCError.appUnavailable }
}
