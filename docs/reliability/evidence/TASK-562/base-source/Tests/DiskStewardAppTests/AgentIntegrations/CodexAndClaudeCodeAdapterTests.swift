@testable import DiskStewardApp
import Foundation
import XCTest

@MainActor
final class CodexAndClaudeCodeAdapterTests: XCTestCase {
    func testClaudeParserAcceptsEmptyEnvironmentButRejectsNonUserScopeAndUnknownFields() {
        let standard = "disk-steward:\n  Scope: User config (available in all your projects)\n  Status: ✘ Failed to connect\n  Type: stdio\n  Command: /tmp/helper with spaces\n  Args:\n  Environment:\n\nTo remove this server, run: claude mcp remove disk-steward -s user\n"
        let expected = AgentIntegrationDefinition(command: "/tmp/helper with spaces")
        XCTAssertEqual(ClaudeCodeIntegrationAdapter.parseClaudeDefinition(standard), expected)
        for changed in [standard + "  Cwd: /tmp/custom\n", standard + "  TOKEN: user-value\n",
                        standard.replacingOccurrences(of: "User config (available in all your projects)", with: "Local config (private to you in this project)")] {
            XCTAssertNotEqual(ClaudeCodeIntegrationAdapter.parseClaudeDefinition(changed), expected)
        }
    }
    func testReceiptFailureRollsBackSetupRepairAndRemoval() async throws {
        for client in [AgentClientID.codex, .claudeCode] {
            for action in [AgentIntegrationAction.setup, .repair, .remove] {
                var failWrites = false
                let fixture = try Fixture(client: client, beforePersist: {
                    if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
                })
                let adapter: CodexCLIIntegrationAdapter = client == .codex ? fixture.codexAdapter() : fixture.claudeAdapter()
                let old = AgentIntegrationDefinition(command: "/tmp/old-helper")
                if action != .setup {
                    fixture.runner.currentDefinition = old
                    try fixture.receipts.upsert(.init(clientID: client, definition: old))
                }
                failWrites = true
                let result = await adapter.perform(action)
                XCTAssertEqual(result.outcome, .failed, "\(client) \(action)")
                XCTAssertEqual(fixture.runner.currentDefinition, action == .setup ? nil : old)
                XCTAssertEqual(try fixture.receipts.receipt(for: client)?.definition, action == .setup ? nil : old)
                XCTAssertTrue(result.message.contains("previous configuration was restored"), result.message)
            }
        }
    }

    func testVerificationRejectsConfigurationChangedDuringHelperCheck() async throws {
        let fixture = try Fixture(client: .codex)
        let adapter = fixture.codexAdapter()
        _ = await adapter.perform(.setup)
        fixture.runner.modifyDuringSelfCheck = true
        let result = await adapter.perform(.verify)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertNil(try fixture.receipts.receipt(for: .codex)?.lastVerifiedAt)
        XCTAssertEqual(result.snapshot.state, .conflict)
    }

    func testFailedMutationDoesNotRollBackOverConcurrentUserChange() async throws {
        let fixture = try Fixture(client: .codex)
        let original = AgentIntegrationDefinition(command: fixture.helper.path)
        fixture.runner.currentDefinition = original
        try fixture.receipts.upsert(.init(clientID: .codex, definition: original))
        fixture.runner.modifyAndFailAdd = true
        let result = await fixture.codexAdapter().perform(.repair)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(fixture.runner.currentDefinition?.command, "/tmp/user-changed")
        XCTAssertEqual(try fixture.receipts.receipt(for: .codex)?.definition, original)
    }

    func testFailedRepairRestoresPreviousOwnedDefinition() async throws {
        let fixture = try Fixture(client: .codex)
        let original = AgentIntegrationDefinition(command: fixture.helper.path)
        fixture.runner.currentDefinition = original
        try fixture.receipts.upsert(.init(clientID: .codex, definition: original))
        fixture.runner.failNextAdd = true
        let result = await fixture.codexAdapter().perform(.repair)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(fixture.runner.currentDefinition, original)
        XCTAssertTrue(result.message.contains("previous configuration was restored"))
        XCTAssertEqual(try fixture.receipts.receipt(for: .codex)?.definition, original)
    }
    func testCodexUsesOfficialLifecycleAndRepeatedSetupIsIdempotent() async throws {
        let fixture = try Fixture(client: .codex)
        let adapter = fixture.codexAdapter()

        let first = await adapter.perform(.setup)
        let second = await adapter.perform(.setup)

        XCTAssertEqual(first.outcome, .changed)
        XCTAssertEqual(second.outcome, .unchanged)
        XCTAssertEqual(fixture.runner.commands.filter { $0.arguments.prefix(2) == ["mcp", "add"] }.count, 1)
        XCTAssertEqual(fixture.runner.commands.first { $0.arguments.contains("add") }?.arguments, ["mcp", "add", "disk-steward", "--", fixture.helper.path])
        XCTAssertNotNil(try fixture.receipts.receipt(for: .codex))
    }

    func testClaudeCodeUsesUserScopeForAddAndRemove() async throws {
        let fixture = try Fixture(client: .claudeCode)
        let adapter = fixture.claudeAdapter()

        let setup = await adapter.perform(.setup)
        let removal = await adapter.perform(.remove)

        XCTAssertEqual(setup.outcome, .changed)
        XCTAssertEqual(removal.outcome, .changed)

        XCTAssertTrue(fixture.runner.commands.contains { $0.arguments == ["mcp", "add", "--scope", "user", "disk-steward", "--", fixture.helper.path] })
        XCTAssertTrue(fixture.runner.commands.contains { $0.arguments == ["mcp", "remove", "--scope", "user", "disk-steward"] })
        XCTAssertFalse(fixture.runner.joinedArguments.contains(".mcp.json"))
    }

    func testConflictFailsClosedWithoutAddRemoveOrReceiptMutation() async throws {
        let fixture = try Fixture(client: .codex)
        fixture.runner.currentDefinition = .init(command: "/tmp/someone-elses-helper")
        let adapter = fixture.codexAdapter()

        let result = await adapter.perform(.setup)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.snapshot.state, .conflict)
        XCTAssertFalse(fixture.runner.commands.contains { $0.arguments.contains("add") || $0.arguments.contains("remove") })
        XCTAssertNil(try fixture.receipts.receipt(for: .codex))
    }

    func testRepairReplacesOnlyReceiptedOwnedDefinition() async throws {
        let fixture = try Fixture(client: .codex)
        let old = AgentIntegrationDefinition(command: fixture.helper.path)
        fixture.runner.currentDefinition = old
        try fixture.receipts.upsert(.init(clientID: .codex, definition: old))
        let adapter = fixture.codexAdapter()

        let result = await adapter.perform(.repair)

        XCTAssertEqual(result.outcome, .changed)
        XCTAssertTrue(fixture.runner.commands.contains { $0.arguments == ["mcp", "remove", "disk-steward"] })
        XCTAssertTrue(fixture.runner.commands.contains { $0.arguments == ["mcp", "add", "disk-steward", "--", fixture.helper.path] })
    }

    func testVerificationRunsBundledHelperSelfCheckAndUpdatesReceipt() async throws {
        let fixture = try Fixture(client: .codex)
        let adapter = fixture.codexAdapter()
        _ = await adapter.perform(.setup)

        let result = await adapter.perform(.verify)

        XCTAssertEqual(result.outcome, .unchanged)
        XCTAssertEqual(result.snapshot.state, .verified)
        XCTAssertTrue(fixture.runner.commands.contains { $0.executableURL == fixture.helper && $0.arguments == ["--self-check"] })
        XCTAssertNotNil(try fixture.receipts.receipt(for: .codex)?.lastVerifiedAt)
    }

    func testMissingHelperIsActionableAndDoesNotInvokeClientMutation() async throws {
        let fixture = try Fixture(client: .codex, createHelper: false)
        let result = await fixture.codexAdapter().perform(.setup)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.contains("Reinstall Disk Steward"))
        XCTAssertFalse(fixture.runner.commands.contains { $0.arguments.contains("add") })
    }

    func testClientCommandFailureIsReportedWithoutFalseReceipt() async throws {
        let fixture = try Fixture(client: .claudeCode)
        fixture.runner.addFailure = AgentCommandResult(exitCode: 9, standardOutput: "", standardError: "permission denied")

        let result = await fixture.claudeAdapter().perform(.setup)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.contains("permission denied"))
        XCTAssertNil(try fixture.receipts.receipt(for: .claudeCode))
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let executable: URL
    let helper: URL
    let receipts: AgentIntegrationReceiptStore
    let runner: CLIAdapterRunnerFixture
    let client: AgentClientID

    init(client: AgentClientID, createHelper: Bool = true, beforePersist: @escaping () throws -> Void = {}) throws {
        self.client = client
        root = URL(fileURLWithPath: "/tmp/ds-cli-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appending(path: client == .codex ? "codex" : "claude")
        helper = root.appending(path: "disk-witness-mcp")
        FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if createHelper {
            FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        }
        receipts = AgentIntegrationReceiptStore(url: root.appending(path: "receipts.json"), beforePersist: beforePersist)
        runner = CLIAdapterRunnerFixture(client: client)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func codexAdapter() -> CodexCLIIntegrationAdapter {
        CodexCLIIntegrationAdapter(executableURL: executable, helperURL: helper, receiptStore: receipts, runner: runner)
    }

    func claudeAdapter() -> ClaudeCodeIntegrationAdapter {
        ClaudeCodeIntegrationAdapter(executableURL: executable, helperURL: helper, receiptStore: receipts, runner: runner)
    }
}

private actor CLIAdapterRunnerFixture: AgentCommandRunning {
    nonisolated(unsafe) var currentDefinition: AgentIntegrationDefinition?
    nonisolated(unsafe) var addFailure: AgentCommandResult?
    nonisolated(unsafe) var failNextAdd = false
    nonisolated(unsafe) var modifyDuringSelfCheck = false
    nonisolated(unsafe) var modifyAndFailAdd = false
    nonisolated(unsafe) private(set) var commands: [AgentCommand] = []
    let client: AgentClientID

    nonisolated var joinedArguments: String { commands.flatMap(\.arguments).joined(separator: " ") }

    init(client: AgentClientID) { self.client = client }

    func run(_ command: AgentCommand) async throws -> AgentCommandResult {
        commands.append(command)
        if command.arguments.contains("get") {
            guard let definition = currentDefinition else {
                return .init(exitCode: 1, standardOutput: "", standardError: "MCP server not found")
            }
            if client == .codex {
                let data = try JSONSerialization.data(withJSONObject: [
                    "transport": ["command": definition.command, "args": definition.arguments],
                ])
                return .init(exitCode: 0, standardOutput: String(decoding: data, as: UTF8.self), standardError: "")
            }
            return .init(exitCode: 0, standardOutput: "Command: \(definition.command)\nArgs: \(definition.arguments.joined(separator: " "))\n", standardError: "")
        }
        if command.arguments.contains("add") {
            if modifyAndFailAdd {
                currentDefinition = .init(command: "/tmp/user-changed")
                return .init(exitCode: 2, standardOutput: "", standardError: "Injected concurrent modification")
            }
            if failNextAdd {
                failNextAdd = false
                return .init(exitCode: 2, standardOutput: "", standardError: "Injected add failure")
            }
            if let addFailure { return addFailure }
            currentDefinition = .init(command: command.arguments.last!)
            return .init(exitCode: 0, standardOutput: "Added", standardError: "")
        }
        if command.arguments.contains("remove") {
            currentDefinition = nil
            return .init(exitCode: 0, standardOutput: "Removed", standardError: "")
        }
        if command.arguments == ["--self-check"] {
            if modifyDuringSelfCheck { currentDefinition = .init(command: "/tmp/user-changed") }
            return .init(exitCode: 0, standardOutput: "ok", standardError: "")
        }
        return .init(exitCode: 2, standardOutput: "", standardError: "unexpected command")
    }
}
