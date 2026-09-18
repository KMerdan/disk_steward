@testable import DiskStewardApp
import Foundation
import XCTest

@MainActor
final class NativeClientLifecycleTests: XCTestCase {
    // Opt in: these exercise installed client binaries, never personal profiles.
    func testNativeClientsInIsolatedProfiles() async throws {
        guard ProcessInfo.processInfo.environment["DISK_STEWARD_NATIVE_CLIENT_TESTS"] == "1" else {
            throw XCTSkip("Set DISK_STEWARD_NATIVE_CLIENT_TESTS=1 for isolated installed-client acceptance")
        }
        let detector = SystemAgentDetectionEnvironment()
        for client in [AgentClientID.codex, .claudeCode] {
            let name = client == .codex ? "codex" : "claude"
            let executable = try XCTUnwrap(detector.executableURL(named: name), "Install \(name) to run this acceptance matrix")
            let root = FileManager.default.temporaryDirectory.appending(path: "ds-native-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let helper = root.appending(path: "helper with spaces")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let runner = IsolatedClientRunner(root: root)
            let receipts = AgentIntegrationReceiptStore(url: root.appending(path: "receipts.json"))
            let adapter: CodexCLIIntegrationAdapter = client == .codex
                ? CodexCLIIntegrationAdapter(executableURL: executable, helperURL: helper, receiptStore: receipts, runner: runner)
                : ClaudeCodeIntegrationAdapter(executableURL: executable, helperURL: helper, receiptStore: receipts, runner: runner)
            let version = try await runner.run(.init(executableURL: executable, arguments: ["--version"]))
            print("Native acceptance: \(name) \(version.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            for action in [AgentIntegrationAction.setup, .setup, .repair, .remove, .remove] {
                let result = await adapter.perform(action)
                XCTAssertNotEqual(result.outcome, .failed, "\(client) \(action): \(result.message)")
                if result.outcome == .failed {
                    let arguments = client == .codex ? ["mcp", "get", "disk-steward", "--json"] : ["mcp", "get", "disk-steward"]
                    let diagnostic = try await runner.run(.init(executableURL: executable, arguments: arguments))
                    print("Isolated client definition: \(diagnostic.combinedOutput)")
                    break
                }
            }
            XCTAssertNil(try receipts.receipt(for: client))
        }
    }
}

private struct IsolatedClientRunner: AgentCommandRunning {
    let root: URL
    private let runner = FoundationAgentCommandRunner(timeoutSeconds: 15)

    func run(_ command: AgentCommand) async throws -> AgentCommandResult {
        var environment = command.environment
        // These are the clients' documented profile overrides, not a changed
        // login HOME. A clean cwd also excludes project-scoped MCP entries.
        environment["CODEX_HOME"] = root.path
        environment["CLAUDE_CONFIG_DIR"] = root.path
        environment["DISABLE_TELEMETRY"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        environment["DISK_STEWARD_SOCKET_PATH"] = root.appending(path: "not-running.sock").path
        environment["MCP_TIMEOUT"] = "1000"
        return try await runner.run(.init(executableURL: command.executableURL, arguments: command.arguments,
            environment: environment, workingDirectoryURL: root))
    }
}
