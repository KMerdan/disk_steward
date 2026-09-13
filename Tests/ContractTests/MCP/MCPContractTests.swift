import Foundation
import XCTest

final class MCPContractTests: XCTestCase {
    private let validator = JSONSchemaContractValidator()

    func testSessionLifecycleFixturesAreVersionedAndAuthenticated() throws {
        let schema = try object(at: "Schemas/Session/session-registration-v1.schema.json")

        for fixture in ["valid-active-session", "valid-ended-session"] {
            let instance = try json(at: "Fixtures/Session/\(fixture).json")
            XCTAssertEqual(validator.validate(instance: instance, schema: schema), [], fixture)
        }
    }

    func testSpoofedSessionFailsClosedAndRegistrationCannotClaimExact() throws {
        let schema = try object(at: "Schemas/Session/session-registration-v1.schema.json")
        let spoofed = try json(at: "Fixtures/Session/invalid-spoofed-session.json")
        let errors = validator.validate(instance: spoofed, schema: schema)

        XCTAssertTrue(errors.contains { $0.contains("registration_id") && $0.contains("pattern") })
        XCTAssertTrue(errors.contains { $0.contains("authentication.transport") && $0.contains("const") })
        XCTAssertTrue(errors.contains { $0.contains("peer_uid_verified") && $0.contains("const") })
        XCTAssertTrue(errors.contains { $0.contains("secret_persisted") && $0.contains("const") })
        XCTAssertTrue(errors.contains { $0.contains("attribution.confidence") && $0.contains("enum") })
        XCTAssertTrue(errors.contains { $0.contains("attribution.limitations") && $0.contains("fewer") })
    }

    func testMCPInventoryIsBoundedLocalAndStrictlyReadOnly() throws {
        let schema = try object(at: "Schemas/MCP/mcp-readonly-contract-v1.schema.json")
        let inventory = try object(at: "Fixtures/MCP/readonly-inventory.json")
        XCTAssertEqual(validator.validate(instance: inventory, schema: schema), [])

        XCTAssertEqual(inventory["transport"] as? String, "stdio")
        let capabilities = try XCTUnwrap(inventory["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["sampling"] as? Bool, false)
        XCTAssertEqual(capabilities["prompts"] as? Bool, false)

        let tools = try XCTUnwrap(inventory["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 10)
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }).count, tools.count)
        for tool in tools {
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, false)
            XCTAssertEqual(annotations["openWorldHint"] as? Bool, false)
            let input = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(input["additionalProperties"] as? Bool, false)
            XCTAssertNil((input["properties"] as? [String: Any])?["destination"])
        }

        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isDisjoint(with: ["delete", "remove", "move", "stop_process", "set_monitoring", "change_settings"]))
    }

    func testMCPFixturesFollowLifecycleAndErrorSeparation() throws {
        let request = try object(at: "Fixtures/MCP/initialize-request.json")
        let response = try object(at: "Fixtures/MCP/initialize-response.json")
        XCTAssertEqual(request["method"] as? String, "initialize")
        XCTAssertEqual((request["params"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((response["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")

        let unavailable = try object(at: "Fixtures/MCP/tool-call-app-unavailable.json")
        let unavailableResult = try XCTUnwrap(unavailable["result"] as? [String: Any])
        XCTAssertEqual(unavailableResult["isError"] as? Bool, true)
        XCTAssertNil(unavailable["error"])
        let structured = try XCTUnwrap(unavailableResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["code"] as? String, "app_unavailable")
        XCTAssertNotNil(structured["recovery"])

        let malformed = try object(at: "Fixtures/MCP/protocol-error-malformed-input.json")
        XCTAssertNil(malformed["result"])
        XCTAssertEqual((malformed["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testSanitizedResponseCarriesConfidenceLimitationsAndNoSecrets() throws {
        let response = try object(at: "Fixtures/MCP/sanitized-growth-response.json")
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(text.contains("file_contents"))
        XCTAssertFalse(text.contains("environment"))
        XCTAssertFalse(text.contains("--token"))
        XCTAssertFalse(text.contains("/Users/example"))

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let items = try XCTUnwrap(structured["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["confidence"] as? String, "inferred")
        XCTAssertFalse((items.first?["limitations"] as? [String] ?? []).isEmpty)
    }

    func testClientCompatibilityFixturesUseLocalStdioWithoutCredentials() throws {
        let codex = try text(at: "Fixtures/MCP/codex-stdio.toml.txt")
        XCTAssertTrue(codex.contains("[mcp_servers.disk_steward]"))
        XCTAssertTrue(codex.contains("command ="))
        XCTAssertTrue(codex.contains("enabled_tools ="))
        XCTAssertFalse(codex.contains("token"))

        let claude = try object(at: "Fixtures/MCP/claude-stdio.json")
        let servers = try XCTUnwrap(claude["mcpServers"] as? [String: Any])
        let diskSteward = try XCTUnwrap(servers["disk_steward"] as? [String: Any])
        XCTAssertEqual(diskSteward["type"] as? String, "stdio")
        XCTAssertNotNil(diskSteward["command"])
        XCTAssertEqual((diskSteward["env"] as? [String: String])?.count, 0)
    }

    private func json(at path: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: repositoryRoot.appending(path: path)))
    }

    private func object(at path: String) throws -> [String: Any] {
        try XCTUnwrap(try json(at: path) as? [String: Any])
    }

    private func text(at path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
