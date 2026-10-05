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

    /// A client that probes a newer protocol first (MCP 2026-07-28 sends
    /// server/discover before anything else) gets -32601, the answer that
    /// makes it fall back to initialize; a known method before initialization
    /// still says the server is not initialized.
    func testAnUnknownMethodIsNotFoundBeforeAndAfterInitialization() throws {
        let server = MCPServer(client: FakeIPCClient(result: sampleSummary))
        let probe = try response(server, request(id: 1, method: "server/discover", params: [:]))
        XCTAssertEqual(probe.objectValue?["error"]?.objectValue?["code"], .integer(-32_601), "an unknown method before initialize")
        let early = try response(server, request(id: 2, method: "tools/list", params: [:]))
        XCTAssertEqual(early.objectValue?["error"]?.objectValue?["code"], .integer(-32_002), "a known method before initialize")
        let initialize = try response(server, request(id: 3, method: "initialize", params: [
            "protocolVersion": .string("2025-11-25"),
            "capabilities": .object(["elicitation": .object(["form": .object([:]), "url": .object([:])])]),
            "clientInfo": .object(["name": .string("probe"), "version": .string("1")]),
        ]))
        XCTAssertEqual(initialize.objectValue?["result"]?.objectValue?["protocolVersion"], .string("2025-11-25"), "the probe falls back cleanly")
        XCTAssertNil(server.handle(line: notification(method: "notifications/initialized", params: [:])))
        let later = try response(server, request(id: 4, method: "server/discover", params: [:]))
        XCTAssertEqual(later.objectValue?["error"]?.objectValue?["code"], .integer(-32_601), "and after it")
    }

    /// Clients show `title`; the server says which app build it belongs to,
    /// and its instructions name the review flow within Codex's 512 characters.
    func testToolsCarryTitlesAndTheServerItsVersion() throws {
        let server = MCPServer(client: FakeIPCClient(result: sampleSummary), serverVersion: "9.8.7")
        let initialize = try response(server, request(id: 1, method: "initialize", params: ["protocolVersion": .string("2025-06-18")]))
        let result = try XCTUnwrap(initialize.objectValue?["result"]?.objectValue)
        XCTAssertEqual(result["serverInfo"]?.objectValue?["version"], .string("9.8.7"))
        XCTAssertEqual(result["serverInfo"]?.objectValue?["title"], .string("Disk Steward"))
        let instructions = try XCTUnwrap(result["instructions"]?.stringValue)
        XCTAssertLessThanOrEqual(instructions.count, 512)
        XCTAssertTrue(instructions.hasPrefix("Read local Disk Steward evidence only."), "the rule comes first")
        XCTAssertTrue(instructions.contains("never imply anything is safe to delete"))
        XCTAssertTrue(instructions.contains("list_review_items") && instructions.contains("get_health"))
        XCTAssertNil(server.handle(line: notification(method: "notifications/initialized", params: [:])))
        let listed = try response(server, request(id: 2, method: "tools/list", params: [:]))
        guard case let .array(entries)? = listed.objectValue?["result"]?.objectValue?["tools"] else { return XCTFail("missing tools") }
        for entry in entries {
            let tool = try XCTUnwrap(entry.objectValue)
            let title = try XCTUnwrap(tool["title"]?.stringValue, "\(tool["name"] ?? .null) has a title")
            XCTAssertFalse(title.isEmpty)
            XCTAssertNotEqual(tool["title"], tool["name"], "a display name, not the identifier")
            XCTAssertEqual(tool["annotations"]?.objectValue?["title"], tool["title"], "older clients read it from the annotations")
        }
    }

    /// Every copy-and-paste configuration names the helper where the app
    /// bundle actually puts it, and the inventory carries the live titles
    /// and instructions.
    func testIntegrationTemplatesNameThePackagedHelper() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func text(_ path: String) throws -> String { try String(contentsOf: repository.appending(path: path), encoding: .utf8) }
        XCTAssertTrue(try text("Config/Packaging/project.yml").contains("$(CONTENTS_FOLDER_PATH)/Helpers/disk-witness-mcp"), "the bundle layout")
        for path in ["Integrations/Claude/mcp.template.json", "Integrations/Claude/README.md", "Integrations/Codex/config.toml.fragment",
                     "Fixtures/MCP/claude-stdio.json", "Fixtures/MCP/codex-stdio.toml.txt"] {
            let contents = try text(path)
            XCTAssertTrue(contents.contains("/Applications/Disk Steward.app/Contents/Helpers/disk-witness-mcp"), path)
            XCTAssertFalse(contents.contains("Contents/MacOS/disk-witness-mcp"), path)
        }
        let inventory = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text("Fixtures/MCP/readonly-inventory.json").utf8)) as? [String: Any])
        XCTAssertEqual((inventory["server"] as? [String: Any])?["instructions"] as? String, MCPToolCatalog.instructions)
        for tool in try XCTUnwrap(inventory["tools"] as? [[String: Any]]) {
            let name = try XCTUnwrap(tool["name"] as? String)
            XCTAssertEqual(tool["title"] as? String, MCPToolCatalog.titles[name], name)
        }
    }

    /// TASK-713: every tool declares an outputSchema that requires its schema
    /// name and limitations, names no $schema (clients reject draft-07), and is
    /// published as Schemas/MCP/tool-output-schemas-v1.json.
    func testEveryToolDeclaresAnOutputSchemaAndThePublishedCopyMatches() throws {
        var published: [String: JSONValue] = [:]
        for entry in MCPToolCatalog.tools {
            let tool = try XCTUnwrap(entry.objectValue)
            let name = try XCTUnwrap(tool["name"]?.stringValue)
            let output = try XCTUnwrap(tool["outputSchema"]?.objectValue, name)
            XCTAssertEqual(output["type"], .string("object"), name)
            XCTAssertNil(output["$schema"], name)
            guard case let .array(required)? = output["required"] else { return XCTFail("\(name) requires nothing") }
            XCTAssertTrue(required.contains(.string("schema")) && required.contains(.string("limitations")), name)
            published[name] = .object(output)
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: repository.appending(path: "Schemas/MCP/tool-output-schemas-v1.json")))
        let expected = JSONValue.object(["schema": .string("mcp-tool-output-schemas-v1"), "tools": .object(published)])
        if file != expected {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            // Regenerate the published copy from here when the catalogue changes.
            if let temporary = ProcessInfo.processInfo.environment["TMPDIR"] {
                try encoder.encode(expected).write(to: URL(fileURLWithPath: temporary).appending(path: "tool-output-schemas-v1.json"))
            }
        }
        XCTAssertEqual(file, expected, "Schemas/MCP/tool-output-schemas-v1.json is the catalogue's outputSchema set")
    }

    /// A supported version is echoed; anything newer is answered with the
    /// newest initialize-era version, MCP 2025-11-25.
    func testInitializeEchoesASupportedVersionAndOtherwiseOffers20251125() throws {
        for (requested, expected) in [("2025-06-18", "2025-06-18"), ("2025-11-25", "2025-11-25"), ("2024-11-05", "2024-11-05"), ("2099-01-01", "2025-11-25")] {
            let server = MCPServer(client: FakeIPCClient(result: sampleSummary))
            let answer = try response(server, request(id: 1, method: "initialize", params: ["protocolVersion": .string(requested)]))
            XCTAssertEqual(answer.objectValue?["result"]?.objectValue?["protocolVersion"], .string(expected), requested)
        }
    }

    // MARK: TASK-714: MCP 2026-07-28 beside the initialize era

    private func modern(_ id: Int, _ method: String, _ params: [String: Any] = [:], version: String = "2026-07-28", capabilities: Bool = true) -> String {
        var meta: [String: Any] = ["io.modelcontextprotocol/protocolVersion": version,
                                   "io.modelcontextprotocol/clientInfo": ["name": "era-test", "version": "1"]]
        if capabilities { meta["io.modelcontextprotocol/clientCapabilities"] = [String: Any]() }
        var body = params
        body["_meta"] = meta
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": body]
        return String(decoding: try! JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    }

    /// A 2026-07-28 client discovers, lists, calls and reads without
    /// initialize, and every response validates against the upstream schema.
    func testA20260728ClientIsServedStatelesslyAndMatchesTheUpstreamSchema() throws {
        let upstream = try UpstreamSchemaValidator(version: "2026-07-28")
        let status: JSONValue = .object(["schema": .string("health-v1"), "limitations": .array([])])
        let server = MCPServer(client: FakeIPCClient(result: sampleSummary, resource: status), serverVersion: "1.5.1")
        func answer(_ line: String, _ definition: String, file: StaticString = #filePath, line number: UInt = #line) throws -> [String: Any] {
            let text = try XCTUnwrap(server.handle(line: line), file: file, line: number)
            XCTAssertEqual(upstream.validate(json: text, definition: definition), [], "\(definition): \(text.prefix(400))", file: file, line: number)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], file: file, line: number)
        }
        let discover = try XCTUnwrap(try answer(modern(1, "server/discover"), "DiscoverResultResponse")["result"] as? [String: Any])
        XCTAssertEqual(discover["supportedVersions"] as? [String], ["2026-07-28"])
        XCTAssertEqual(discover["resultType"] as? String, "complete")
        XCTAssertEqual(((discover["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] as? [String: Any])?["version"] as? String, "1.5.1")
        let tools = try XCTUnwrap(try answer(modern(2, "tools/list"), "ListToolsResultResponse")["result"] as? [String: Any])
        XCTAssertEqual((tools["tools"] as? [[String: Any]])?.count, MCPToolCatalog.names.count)
        XCTAssertEqual(tools["cacheScope"] as? String, "public")
        _ = try answer(modern(3, "resources/list"), "ListResourcesResultResponse")
        let read = try XCTUnwrap(try answer(modern(4, "resources/read", ["uri": "disk-steward://status"]), "ReadResourceResultResponse")["result"] as? [String: Any])
        XCTAssertEqual(read["ttlMs"] as? Int, 0, "the live status is not cached")
        XCTAssertEqual(read["cacheScope"] as? String, "private")
        let call = try XCTUnwrap(try answer(modern(5, "tools/call", ["name": "get_storage_summary", "arguments": [String: Any]()]), "CallToolResultResponse")["result"] as? [String: Any])
        XCTAssertEqual(call["resultType"] as? String, "complete")
        XCTAssertEqual(call["isError"] as? Bool, false)
        XCTAssertNotNil(call["structuredContent"])
        let invalid = try XCTUnwrap(try answer(modern(6, "tools/call", ["name": "explain_growth", "arguments": ["from": "x", "through": "y"]]), "CallToolResultResponse")["result"] as? [String: Any])
        XCTAssertEqual(invalid["isError"] as? Bool, true)
        XCTAssertNil(invalid["structuredContent"])
    }

    /// Version and envelope errors in the stateless era, and the methods it
    /// removed; the initialize session keeps working beside it.
    func testThe20260728EnvelopeIsCheckedAndRemovedMethodsAreNotFound() throws {
        let upstream = try UpstreamSchemaValidator(version: "2026-07-28")
        let server = MCPServer(client: FakeIPCClient(result: sampleSummary))
        let unsupported = try XCTUnwrap(server.handle(line: modern(1, "tools/list", version: "2099-01-01")))
        XCTAssertEqual(upstream.validate(json: unsupported, definition: "UnsupportedProtocolVersionError"), [], unsupported)
        let error = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(unsupported.utf8)) as? [String: Any])?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32_022)
        XCTAssertEqual((error["data"] as? [String: Any])?["supported"] as? [String], ["2026-07-28"])
        XCTAssertEqual((error["data"] as? [String: Any])?["requested"] as? String, "2099-01-01")
        for (id, line, code) in [(2, modern(2, "tools/list", capabilities: false), -32_602),
                                 (3, modern(3, "ping"), -32_601), (4, modern(4, "initialize"), -32_601),
                                 (5, modern(5, "logging/setLevel", ["level": "info"]), -32_601)] {
            let text = try XCTUnwrap(server.handle(line: line))
            XCTAssertEqual(upstream.validate(json: text, definition: "JSONRPCErrorResponse"), [], text)
            XCTAssertEqual(((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int, code, "request \(id)")
        }
        // The initialize-era session is unaffected.
        let initialized = try response(server, request(id: 10, method: "initialize", params: ["protocolVersion": .string("2025-06-18")]))
        XCTAssertEqual(initialized.objectValue?["result"]?.objectValue?["protocolVersion"], .string("2025-06-18"))
        XCTAssertNil(server.handle(line: notification(method: "notifications/initialized", params: [:])))
        let legacy = try response(server, request(id: 11, method: "tools/call", params: ["name": .string("get_storage_summary"), "arguments": .object([:])]))
        XCTAssertNil(legacy.objectValue?["result"]?.objectValue?["resultType"], "an initialize-era result keeps its own shape")
    }

    /// A 2025-11-25 session's results validate against that version's schema.
    func testA20251125SessionMatchesTheUpstreamSchema() throws {
        let upstream = try UpstreamSchemaValidator(version: "2025-11-25")
        let status: JSONValue = .object(["schema": .string("health-v1"), "limitations": .array([])])
        let server = MCPServer(client: FakeIPCClient(result: sampleSummary, resource: status), serverVersion: "1.5.1")
        func result(_ line: String, _ definition: String) throws -> [String: JSONValue] {
            let text = try XCTUnwrap(server.handle(line: line))
            let object = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).objectValue?["result"]?.objectValue, text)
            let encoded = String(decoding: try JSONEncoder.diskSteward.encode(JSONValue.object(object)), as: UTF8.self)
            XCTAssertEqual(upstream.validate(json: encoded, definition: definition), [], "\(definition): \(encoded.prefix(400))")
            return object
        }
        let initialize = try result(request(id: 1, method: "initialize", params: [
            "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("era-test"), "version": .string("1")]),
        ]), "InitializeResult")
        XCTAssertEqual(initialize["protocolVersion"], .string("2025-11-25"))
        XCTAssertNil(server.handle(line: notification(method: "notifications/initialized", params: [:])))
        _ = try result(request(id: 2, method: "tools/list", params: [:]), "ListToolsResult")
        _ = try result(request(id: 3, method: "resources/list", params: [:]), "ListResourcesResult")
        _ = try result(request(id: 4, method: "resources/read", params: ["uri": .string("disk-steward://status")]), "ReadResourceResult")
        _ = try result(request(id: 5, method: "tools/call", params: ["name": .string("get_storage_summary"), "arguments": .object([:])]), "CallToolResult")
        _ = try result(request(id: 6, method: "tools/call", params: ["name": .string("list_review_items"), "arguments": .object(["limit": .integer(0)])]), "CallToolResult")
    }

    /// TASK-671: measure_path may take its whole 15 s budget, so it alone
    /// goes through the client with the measurement deadline; the dropped
    /// tools are refused before any call.
    func testMeasurePathUsesTheMeasurementClientAndDroppedToolsAreRefused() throws {
        let fast = FakeIPCClient(result: .object(["schema": .string("fast")]))
        let slow = FakeIPCClient(result: .object(["schema": .string("measure-path-v1")]))
        let server = MCPServer(client: fast, slowClient: slow)
        _ = try response(server, request(id: 1, method: "initialize", params: [
            "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("test"), "version": .string("1")]),
        ]))
        XCTAssertNil(server.handle(line: notification(method: "notifications/initialized", params: [:])))
        _ = try response(server, request(id: 2, method: "tools/call", params: ["name": .string("measure_path"), "arguments": .object(["path": .string("/w/code")])]))
        _ = try response(server, request(id: 3, method: "tools/call", params: ["name": .string("get_health"), "arguments": .object([:])]))
        XCTAssertEqual(slow.calledTools, ["measure_path"])
        XCTAssertEqual(fast.calledTools, ["get_health"])
        XCTAssertEqual(MCPToolCatalog.slowTools, ["measure_path"])
        XCTAssertLessThan(15, UnixSocketDiskStewardIPCClient.measurementTimeoutSeconds, "the deadline covers the 15 s budget")
        for (offset, dropped) in ["find_cleanup_candidates", "list_current_consumers", "get_evidence_lifecycle", "list_active_writers", "get_provenance"].enumerated() {
            let refused = try response(server, request(id: Int64(10 + offset), method: "tools/call", params: ["name": .string(dropped), "arguments": .object([:])]))
            XCTAssertEqual(refused.objectValue?["error"]?.objectValue?["code"], .integer(-32_602), dropped)
        }
        XCTAssertEqual(fast.calledTools + slow.calledTools, ["get_health", "measure_path"], "no dropped tool reached the app")
        XCTAssertEqual(MCPToolCatalog.validationError(tool: "measure_path", arguments: [:]), "Missing required argument: path")
        XCTAssertNotNil(MCPToolCatalog.validationError(tool: "list_review_items", arguments: ["root_path": .string("/x")]), "old arguments are refused")
    }

    /// Every published copy of the tool list is the catalogue: the inventory
    /// fixture, the contract schema, the Codex fragment and fixture, and the
    /// installer's own enabled_tools line.
    func testEveryPublishedToolListIsTheCatalogue() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func text(_ path: String) throws -> String { try String(contentsOf: repository.appending(path: path), encoding: .utf8) }
        // TASK-715: no published configuration pins a tool list (it went
        // stale once), and every one names the server disk-steward.
        for path in ["Integrations/Codex/config.toml.fragment", "Fixtures/MCP/codex-stdio.toml.txt", "Scripts/Integration/install"] {
            let contents = try text(path)
            XCTAssertFalse(contents.contains("enabled_tools"), path)
            XCTAssertTrue(contents.contains("[mcp_servers.disk-steward]"), path)
        }
        for path in ["Integrations/Claude/mcp.template.json", "Fixtures/MCP/claude-stdio.json", "Integrations/Codex/disk-steward/mcp.json"] {
            let servers = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(text(path).utf8)) as? [String: Any])?["mcpServers"] as? [String: Any], path)
            XCTAssertEqual(Array(servers.keys), ["disk-steward"], path)
        }
        let inventory = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text("Fixtures/MCP/readonly-inventory.json").utf8)) as? [String: Any])
        XCTAssertEqual((inventory["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, MCPToolCatalog.names)
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text("Schemas/MCP/mcp-readonly-contract-v1.schema.json").utf8)) as? [String: Any])
        let tools = ((schema["properties"] as? [String: Any])?["tools"] as? [String: Any])
        let names = (((tools?["items"] as? [String: Any])?["properties"] as? [String: Any])?["name"] as? [String: Any])?["enum"] as? [String]
        XCTAssertEqual(names, MCPToolCatalog.names)
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

    /// MCP 2025-11-25 (SEP-1303): arguments a model can correct are a tool
    /// error it reads; an unknown tool or non-object arguments stay -32602.
    func testInvalidArgumentsAreToolErrorsAndUnknownToolsProtocolErrors() throws {
        let client = FakeIPCClient(result: sampleSummary)
        let server = initializedServer(client: client)
        let malformed = try response(server, request(id: 4, method: "tools/call", params: [
            "name": .string("explain_growth"),
            "arguments": .object([
                "from": .string("2026-09-12T13:00:00Z"),
                "through": .string("2026-09-12T12:00:00Z"),
            ]),
        ]))
        XCTAssertNil(malformed.objectValue?["error"], "not a protocol error")
        let error = try errorDetails(malformed)
        XCTAssertEqual(error["code"], .string("invalid_arguments"))
        XCTAssertEqual(error["retryable"], .bool(false))
        XCTAssertTrue(error["message"]?.stringValue?.contains("through must be later than from") == true)
        XCTAssertTrue(client.calledTools.isEmpty, "the app is never asked")
        let notObject = try response(server, request(id: 11, method: "tools/call", params: [
            "name": .string("get_health"), "arguments": .string("x"),
        ]))
        XCTAssertEqual(notObject.objectValue?["error"]?.objectValue?["code"], .integer(-32_602))

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
        XCTAssertNil(disabledResult["structuredContent"], "an error carries its details as text, never as structured content")
        let disabledError = try errorDetails(disabledOutput)
        XCTAssertEqual(disabledError["code"], .string("agent_access_disabled"))
        XCTAssertEqual(disabledError["retryable"], .bool(false))
        XCTAssertTrue(disabledError["recovery"]?.stringValue?.contains("turn on Agent Access") == true)
        XCTAssertTrue(disabledError["message"]?.stringValue?.contains("Agent Access is off") == true)

        let unavailable = initializedServer(client: FakeIPCClient(error: DiskStewardIPCError.appUnavailable))
        let output = try response(unavailable, request(id: 6, method: "tools/call", params: [
            "name": .string("get_storage_summary"), "arguments": .object([:]),
        ]))
        let result = try XCTUnwrap(output.objectValue?["result"]?.objectValue)
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertEqual(try errorDetails(output)["code"], .string("app_unavailable"))
        XCTAssertNotNil(try errorDetails(output)["recovery"])

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
        XCTAssertEqual(try errorDetails(boundedOutput)["code"], .string("response_too_large"))

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

    /// An error result's mcp-error-v1 details, read from its text.
    private func errorDetails(_ output: JSONValue) throws -> [String: JSONValue] {
        let result = try XCTUnwrap(output.objectValue?["result"]?.objectValue)
        XCTAssertEqual(result["isError"], .bool(true))
        guard case let .array(content)? = result["content"] else { return [:] }
        let text = try XCTUnwrap(content.first?.objectValue?["text"]?.stringValue, "an error result carries its details as text")
        let details = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).objectValue)
        XCTAssertEqual(details["schema"], .string("mcp-error-v1"))
        return details
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
