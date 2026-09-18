@testable import DiskStewardApp
import Foundation
import XCTest

/// TASK-562: verification executes the exact command the client will run,
/// binds the self-check to that binary's identity, and reports app-off,
/// access-off and stale evidence for what they are. A different helper's
/// exit-0 self-check can never make a moved or missing helper "verified".
@MainActor
final class HelperVerificationTests: XCTestCase {
    func testExitZeroWithoutASelfCheckReportIsNotVerification() async throws {
        let fixture = try VerificationFixture()
        fixture.runner.script = { _ in .init(exitCode: 0, standardOutput: "ok", standardError: "") }
        let adapter = fixture.adapter()
        let setup = await adapter.perform(.setup)
        XCTAssertEqual(setup.outcome, .changed)
        let verify = await adapter.perform(.verify)
        XCTAssertEqual(verify.outcome, .failed)
        XCTAssertTrue(verify.message.contains("did not identify itself"), verify.message)
        XCTAssertEqual(verify.snapshot.state, .broken)
        XCTAssertNotEqual(try fixture.receipts.receipt(for: .claudeDesktop)?.lastResult, "verified")
    }

    func testADifferentHelperAnsweringTheSelfCheckIsRejected() async throws {
        let fixture = try VerificationFixture()
        let other = fixture.root.appending(path: "other-helper")
        try Data("#!/bin/sh\n".utf8).write(to: other)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path)
        let adapter = fixture.adapter()
        _ = await adapter.perform(.setup)
        fixture.runner.script = { _ in .init(exitCode: 0, standardOutput: SelfCheckReportFixture.report(for: other, app: "connected", ageSeconds: 5), standardError: "") }
        let verify = await adapter.perform(.verify)
        XCTAssertEqual(verify.outcome, .failed)
        XCTAssertTrue(verify.message.contains("A different helper answered the self-check"), verify.message)
        XCTAssertEqual(verify.snapshot.state, .broken)
    }

    func testVerificationRunsTheConfiguredCommandWithACleanEnvironment() async throws {
        let fixture = try VerificationFixture()
        let adapter = fixture.adapter()
        _ = await adapter.perform(.setup)
        fixture.runner.script = { command in .init(exitCode: 0, standardOutput: SelfCheckReportFixture.report(for: command.executableURL, app: "connected", ageSeconds: 30), standardError: "") }
        let verify = await adapter.perform(.verify)
        XCTAssertEqual(verify.outcome, .unchanged, verify.message)
        XCTAssertEqual(verify.snapshot.state, .verified)
        let command = try XCTUnwrap(fixture.runner.commands.last { $0.arguments == ["--self-check"] })
        XCTAssertEqual(command.executableURL, fixture.helper, "the configured command, not an assumed path, is executed")
        XCTAssertFalse(command.inheritsEnvironment, "an inherited DISK_STEWARD_* override must not redirect the self-check")
        XCTAssertNil(command.environment["DISK_STEWARD_SOCKET_PATH"])
        XCTAssertEqual(try fixture.receipts.receipt(for: .claudeDesktop)?.lastResult, "verified")
        XCTAssertTrue(verify.message.contains("Evidence is 1 min old"), verify.message)
    }

    func testMovedHelperCannotBeVerifiedEvenWhenTheNewHelperAnswers() async throws {
        let fixture = try VerificationFixture()
        let adapter = fixture.adapter()
        _ = await adapter.perform(.setup)
        // The bundled helper moves (a new app build at a new path); the client
        // still names the old path, which no longer exists.
        let moved = fixture.root.appending(path: "Disk Steward 2.app/Contents/Helpers/disk-witness-mcp")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.helper, to: moved)
        fixture.runner.script = { _ in .init(exitCode: 0, standardOutput: SelfCheckReportFixture.report(for: moved, app: "connected", ageSeconds: 1), standardError: "") }
        let verify = await adapter.perform(.verify)
        XCTAssertEqual(verify.outcome, .failed)
        XCTAssertEqual(verify.snapshot.state, .broken)
        XCTAssertTrue(verify.message.contains("Repair"), verify.message)
    }

    func testAppOffAccessOffAndStaleEvidenceAreReportedAccurately() async throws {
        for (app, age, expectedState, needle) in [("app-off", nil as Double?, AgentIntegrationStateKind.broken, "not running"),
                                                   ("access-off", nil, .broken, "Agent Access is off"),
                                                   ("connected", 2 * 3_600 + 1, .stale, "2 h old"),
                                                   ("connected", nil, .stale, "no evidence has been persisted yet"),
                                                   ("connected", 90, .verified, "1 min old")] {
            let fixture = try VerificationFixture()
            let adapter = fixture.adapter()
            _ = await adapter.perform(.setup)
            fixture.runner.script = { command in .init(exitCode: app == "connected" ? 0 : 1, standardOutput: SelfCheckReportFixture.report(for: command.executableURL, app: app, ageSeconds: age), standardError: "") }
            let verify = await adapter.perform(.verify)
            XCTAssertEqual(verify.snapshot.state, expectedState, "\(app) \(String(describing: age)): \(verify.message)")
            XCTAssertTrue(verify.message.contains(needle), "\(app): \(verify.message)")
            let receipt = try XCTUnwrap(try fixture.receipts.receipt(for: .claudeDesktop))
            switch expectedState {
            case .verified: XCTAssertEqual(receipt.lastResult, "verified")
            case .stale: XCTAssertEqual(receipt.lastResult, "verified-stale")
            default: XCTAssertEqual(receipt.lastResult, "configured", "a failed test never stamps a verification")
            }
        }
    }

    func testCLIClientVerifiesTheCommandTheClientReports() async throws {
        let fixture = try VerificationFixture()
        let cli = fixture.root.appending(path: "codex")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        // The fake client reports no entry until `mcp add` ran, then whatever
        // command the test says the client would spawn.
        let configured = MutableBox<String?>(nil)
        fixture.runner.script = { command in
            if command.arguments.first == "mcp" && command.arguments[1] == "get" {
                guard let value = configured.value else { return .init(exitCode: 1, standardOutput: "", standardError: "MCP server not found") }
                return .init(exitCode: 0, standardOutput: "{\"transport\":{\"type\":\"stdio\",\"command\":\"\(value)\",\"args\":[]}}", standardError: "")
            }
            if command.arguments.first == "mcp" && command.arguments[1] == "add" { configured.value = command.arguments.last; return .init(exitCode: 0, standardOutput: "Added", standardError: "") }
            if command.arguments.first == "mcp" && command.arguments[1] == "remove" { configured.value = nil; return .init(exitCode: 0, standardOutput: "Removed", standardError: "") }
            if command.arguments == ["--self-check"] {
                return .init(exitCode: 0, standardOutput: SelfCheckReportFixture.report(for: command.executableURL, app: "connected", ageSeconds: 10), standardError: "")
            }
            return .init(exitCode: 0, standardOutput: "", standardError: "")
        }
        let adapter = CodexCLIIntegrationAdapter(executableURL: cli, helperURL: fixture.helper, receiptStore: fixture.receipts, runner: fixture.runner)
        let setup = await adapter.perform(.setup)
        XCTAssertEqual(setup.outcome, .changed, setup.message)
        let verified = await adapter.perform(.verify)
        XCTAssertEqual(verified.snapshot.state, .verified, verified.message)
        // The client now reports another command for the entry: not this build's helper.
        let impostor = fixture.root.appending(path: "impostor")
        try Data("#!/bin/sh\n".utf8).write(to: impostor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: impostor.path)
        configured.value = impostor.path
        let rejected = await adapter.perform(.verify)
        XCTAssertEqual(rejected.outcome, .failed, rejected.message)
        XCTAssertFalse(fixture.runner.commands.contains { $0.executableURL == impostor }, "the impostor is never executed")
    }
}

@MainActor
private final class VerificationFixture {
    let root: URL
    let config: URL
    let helper: URL
    let receipts: AgentIntegrationReceiptStore
    let runner = ScriptedRunner()

    init() throws {
        root = URL(fileURLWithPath: "/tmp/ds-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        config = root.appending(path: "claude_desktop_config.json")
        helper = root.appending(path: "Disk Steward.app/Contents/Helpers/disk-witness-mcp")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        receipts = AgentIntegrationReceiptStore(url: root.appending(path: "support/receipts.json"))
        try JSONSerialization.data(withJSONObject: ["mcpServers": [:]]).write(to: config, options: .atomic)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func adapter() -> ClaudeDesktopIntegrationAdapter {
        ClaudeDesktopIntegrationAdapter(configurationURL: config, helperURL: helper, receiptStore: receipts, runner: runner)
    }

}

private final class MutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private actor ScriptedRunner: AgentCommandRunning {
    nonisolated(unsafe) var script: @Sendable (AgentCommand) -> AgentCommandResult = { _ in .init(exitCode: 0, standardOutput: "", standardError: "") }
    nonisolated(unsafe) var commands: [AgentCommand] = []
    func run(_ command: AgentCommand) async throws -> AgentCommandResult {
        commands.append(command)
        return script(command)
    }
}
