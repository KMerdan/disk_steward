import DiskStewardCore
@testable import DiskStewardMCP
import Foundation
import XCTest

final class DiskStewardMCPTests: XCTestCase {
    func testInitializationAndToolDiscoveryExposeOnlyReadOnlyCatalog() throws {
        let client = FakeIPCClient(result: sampleSummary)
        let server = MCPServer(client: client)
        let initialize = try response(server, request(id: 1, method: "initialize", params: [
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("test"), "version": .string("1")]),
        ]))
        XCTAssertEqual(initialize.objectValue?["result"]?.objectValue?["protocolVersion"], .string("2025-06-18"))

        XCTAssertNil(server.handle(line: notification(method: "notifications/initialized", params: [:])))
        let listed = try response(server, request(id: 2, method: "tools/list", params: [:]))
        let tools = try XCTUnwrap(listed.objectValue?["result"]?.objectValue?["tools"])
        guard case let .array(entries) = tools else { return XCTFail("missing tools") }
        XCTAssertEqual(entries.count, MCPToolCatalog.names.count)
        XCTAssertEqual(Set(entries.compactMap { $0.objectValue?["name"]?.stringValue }), Set(MCPToolCatalog.names))
        for entry in entries {
            let annotations = try XCTUnwrap(entry.objectValue?["annotations"]?.objectValue)
            XCTAssertEqual(annotations["readOnlyHint"], .bool(true))
            XCTAssertEqual(annotations["destructiveHint"], .bool(false))
            XCTAssertEqual(entry.objectValue?["inputSchema"]?.objectValue?["additionalProperties"], .bool(false))
        }
    }

    func testToolCallReturnsStructuredAndTextContentWithSanitization() throws {
        let unsafe: JSONValue = .object([
            "schema": .string("storage-summary-v1"),
            "path": .string("artifact.zip"),
            "command": .string("curl --token=supersecret example.test"),
            "environment": .object(["API_KEY": .string("secret")]),
            "file_contents": .string("private data"),
            "confidence": .string("inferred"),
            "limitations": .array([.string("Process identity was not observed.")]),
        ])
        let client = FakeIPCClient(result: unsafe)
        let server = initializedServer(client: client)
        let call = request(id: 3, method: "tools/call", params: [
            "name": .string("get_storage_summary"),
            "arguments": .object([:]),
        ])
        let output = try response(server, call)
        let result = try XCTUnwrap(output.objectValue?["result"]?.objectValue)
        XCTAssertEqual(result["isError"], .bool(false))
        let structured = try XCTUnwrap(result["structuredContent"]?.objectValue)
        XCTAssertNil(structured["environment"])
        XCTAssertNil(structured["file_contents"])
        XCTAssertEqual(structured["command"], .string("curl --token=<redacted> example.test"))
        XCTAssertEqual(structured["confidence"], .string("inferred"))
        XCTAssertNotNil(structured["limitations"])
        XCTAssertEqual(client.calledTools, ["get_storage_summary"])
    }

    func testMalformedInputAndUnknownToolsAreProtocolErrors() throws {
        let server = initializedServer(client: FakeIPCClient(result: sampleSummary))
        let malformed = try response(server, request(id: 4, method: "tools/call", params: [
            "name": .string("explain_growth"),
            "arguments": .object([
                "from": .string("2026-09-12T13:00:00Z"),
                "through": .string("2026-09-12T12:00:00Z"),
            ]),
        ]))
        XCTAssertEqual(malformed.objectValue?["error"]?.objectValue?["code"], .integer(-32_602))

        let unknown = try response(server, request(id: 5, method: "tools/call", params: [
            "name": .string("delete_file"),
            "arguments": .object([:]),
        ]))
        XCTAssertEqual(unknown.objectValue?["error"]?.objectValue?["code"], .integer(-32_602))
    }

    func testUnavailableAppAndInsecureSocketReturnActionableErrors() throws {
        let disabled = initializedServer(client: FakeIPCClient(error: DiskStewardIPCError.agentAccessDisabled))
        let disabledOutput = try response(disabled, request(id: 60, method: "tools/call", params: [
            "name": .string("get_storage_summary"), "arguments": .object([:]),
        ]))
        let disabledResult = try XCTUnwrap(disabledOutput.objectValue?["result"]?.objectValue)
        XCTAssertEqual(disabledResult["isError"], .bool(true))
        XCTAssertEqual(disabledResult["structuredContent"]?.objectValue?["code"], .string("agent_access_disabled"))
        XCTAssertEqual(disabledResult["structuredContent"]?.objectValue?["retryable"], .bool(false))
        XCTAssertTrue(disabledResult["structuredContent"]?.objectValue?["recovery"]?.stringValue?.contains("turn on Agent Access") == true)

        let unavailable = initializedServer(client: FakeIPCClient(error: DiskStewardIPCError.appUnavailable))
        let output = try response(unavailable, request(id: 6, method: "tools/call", params: [
            "name": .string("get_storage_summary"), "arguments": .object([:]),
        ]))
        let result = try XCTUnwrap(output.objectValue?["result"]?.objectValue)
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertEqual(result["structuredContent"]?.objectValue?["code"], .string("app_unavailable"))
        XCTAssertNotNil(result["structuredContent"]?.objectValue?["recovery"])

        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let local = UnixSocketDiskStewardIPCClient(socketPath: temporary.path)
        XCTAssertThrowsError(try local.call(tool: "get_storage_summary", arguments: [:], isCancelled: { false })) { error in
            guard case DiskStewardIPCError.insecureSocket = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testUnknownCancellationDoesNotPoisonLaterRequest() throws {
        let client = FakeIPCClient(result: sampleSummary)
        let server = initializedServer(client: client)
        XCTAssertNil(server.handle(line: notification(method: "notifications/cancelled", params: ["requestId": .integer(7)])))
        let output = try response(server, request(id: 7, method: "tools/call", params: [
            "name": .string("get_storage_summary"), "arguments": .object([:]),
        ]))
        XCTAssertEqual(output.objectValue?["result"]?.objectValue?["isError"], .bool(false))
        XCTAssertEqual(client.calledTools, ["get_storage_summary"])
    }

    func testResponseLimitFailsClosedAndExportPreservesInlineParity() throws {
        let oversized = JSONValue.object([
            "schema": .string("growth-explanation-v1"),
            "items": .array([.string(String(repeating: "x", count: 8_000))]),
        ])
        let bounded = initializedServer(client: FakeIPCClient(result: oversized), maximumResponseBytes: 1_024)
        let boundedOutput = try response(bounded, request(id: 8, method: "tools/call", params: [
            "name": .string("get_storage_summary"), "arguments": .object([:]),
        ]))
        XCTAssertEqual(boundedOutput.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue?["code"], .string("response_too_large"))

        let bundle: JSONValue = .object([
            "schema": .string("inline-evidence-bundle-v1"),
            "manifest": .object([
                "schema": .string("export-manifest-v1"),
                "bundle_id": .string("fixture"),
                "limitations": .array([.string("Inline event detail is bounded.")]),
            ]),
            "summary": .object(["event_count": .integer(2)]),
            "events": .array([.object(["event_id": .string("one")]), .object(["event_id": .string("two")])]),
            "truncated": .bool(false),
        ])
        let exportServer = initializedServer(client: FakeIPCClient(result: bundle))
        let export = try response(exportServer, request(id: 9, method: "tools/call", params: [
            "name": .string("export_evidence"),
            "arguments": .object([
                "from": .string("2026-09-12T12:00:00Z"),
                "through": .string("2026-09-12T13:00:00Z"),
                "max_events": .integer(100),
            ]),
        ]))
        XCTAssertEqual(export.objectValue?["result"]?.objectValue?["structuredContent"], bundle)
    }

    func testResourcesForwardThroughProtectedIPC() throws {
        let guide: JSONValue = .object(["schema": .string("evidence-guide-v1"), "text": .string("Confidence must be interpreted with limitations.")])
        let client = FakeIPCClient(result: sampleSummary, resource: guide)
        let server = initializedServer(client: client)
        let listed = try response(server, request(id: 10, method: "resources/list", params: [:]))
        guard case let .array(resources)? = listed.objectValue?["result"]?.objectValue?["resources"] else {
            return XCTFail("missing resources")
        }
        XCTAssertEqual(resources.count, 2)

        let read = try response(server, request(id: 11, method: "resources/read", params: ["uri": .string("disk-steward://evidence-guide")]))
        XCTAssertNotNil(read.objectValue?["result"]?.objectValue?["contents"])
        XCTAssertEqual(client.readResources, ["disk-steward://evidence-guide"])
    }

    private var sampleSummary: JSONValue {
        .object([
            "schema": .string("storage-summary-v1"),
            "observed_at": .string("2026-09-12T12:00:00Z"),
            "used_bytes": .integer(100),
            "limitations": .array([.string("File detail is limited to monitored roots.")]),
        ])
    }

    private func initializedServer(client: FakeIPCClient, maximumResponseBytes: Int = 4 * 1_024 * 1_024) -> MCPServer {
        let server = MCPServer(client: client, maximumResponseBytes: maximumResponseBytes)
        _ = server.handle(line: request(id: 0, method: "initialize", params: ["protocolVersion": .string("2025-06-18")]))
        _ = server.handle(line: notification(method: "notifications/initialized", params: [:]))
        return server
    }

    private func request(id: Int64, method: String, params: [String: JSONValue]) -> String {
        encode(.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(id),
            "method": .string(method),
            "params": .object(params),
        ]))
    }

    private func notification(method: String, params: [String: JSONValue]) -> String {
        encode(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)]))
    }

    private func response(_ server: MCPServer, _ line: String) throws -> JSONValue {
        let text = try XCTUnwrap(server.handle(line: line))
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func encode(_ value: JSONValue) -> String {
        let data = try! JSONEncoder.diskSteward.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

private final class FakeIPCClient: DiskStewardIPCClient, @unchecked Sendable {
    private let lock = NSLock()
    private let result: JSONValue
    private let resource: JSONValue
    private let error: Error?
    private(set) var calledTools: [String] = []
    private(set) var readResources: [String] = []

    init(result: JSONValue = .object([:]), resource: JSONValue = .object([:]), error: Error? = nil) {
        self.result = result
        self.resource = resource
        self.error = error
    }

    func call(tool: String, arguments: [String: JSONValue], isCancelled: @Sendable () -> Bool) throws -> JSONValue {
        if isCancelled() { throw DiskStewardIPCError.cancelled }
        if let error { throw error }
        lock.lock()
        calledTools.append(tool)
        lock.unlock()
        return result
    }

    func readResource(uri: String, isCancelled: @Sendable () -> Bool) throws -> JSONValue {
        if isCancelled() { throw DiskStewardIPCError.cancelled }
        if let error { throw error }
        lock.lock()
        readResources.append(uri)
        lock.unlock()
        return resource
    }
}
