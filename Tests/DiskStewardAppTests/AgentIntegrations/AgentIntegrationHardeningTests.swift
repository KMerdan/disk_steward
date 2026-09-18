@testable import DiskStewardApp
import Foundation
import XCTest

@MainActor
final class AgentIntegrationHardeningTests: XCTestCase {
    func testReplacingHelperAtSamePathRequiresRepairBeforeVerification() async throws {
        let fixture = try HardeningFixture()
        let adapter = ClaudeDesktopIntegrationAdapter(configurationURL: fixture.config,
            helperURL: fixture.firstHelper, receiptStore: fixture.receipts, runner: fixture.runner)
        _ = await adapter.perform(.setup)
        try Data("#!/bin/sh\nexit 0 # replaced\n".utf8).write(to: fixture.firstHelper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.firstHelper.path)
        let inspected = await adapter.inspect()
        XCTAssertEqual(inspected.state, .broken)
        let verification = await adapter.perform(.verify)
        XCTAssertEqual(verification.outcome, .failed)
        let repaired = await adapter.perform(.repair)
        XCTAssertEqual(repaired.outcome, .changed)
        let verified = await adapter.perform(.verify)
        XCTAssertEqual(verified.snapshot.state, .verified)
    }
    func testJSONReceiptFailureRestoresExactDocumentForAllMutations() async throws {
        for action in [AgentIntegrationAction.setup, .repair, .remove] {
            var failWrites = false
            let fixture = try HardeningFixture(beforePersist: {
                if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
            })
            let adapter = ClaudeDesktopIntegrationAdapter(configurationURL: fixture.config,
                helperURL: fixture.firstHelper, receiptStore: fixture.receipts, runner: fixture.runner)
            if action != .setup { _ = await adapter.perform(.setup) }
            let original = try Data(contentsOf: fixture.config)
            let originalReceipt = try fixture.receipts.receipt(for: .claudeDesktop)
            failWrites = true
            let result = await adapter.perform(action)
            XCTAssertEqual(result.outcome, .failed)
            XCTAssertEqual(try Data(contentsOf: fixture.config), original)
            XCTAssertEqual(try fixture.receipts.receipt(for: .claudeDesktop), originalReceipt)
            let permissions = try FileManager.default.attributesOfItem(atPath: fixture.config.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
    }

    func testConfigurationAndReceiptSymlinksFailClosed() async throws {
        let fixture = try HardeningFixture()
        let target = fixture.root.appending(path: "other.json")
        try FileManager.default.moveItem(at: fixture.config, to: target)
        try FileManager.default.createSymbolicLink(at: fixture.config, withDestinationURL: target)
        let original = try Data(contentsOf: target)
        let adapter = ClaudeDesktopIntegrationAdapter(configurationURL: fixture.config,
            helperURL: fixture.firstHelper, receiptStore: fixture.receipts, runner: fixture.runner)
        let setup = await adapter.perform(.setup)
        XCTAssertEqual(setup.outcome, .failed)
        XCTAssertEqual(try Data(contentsOf: target), original)
        try FileManager.default.createSymbolicLink(at: fixture.receipts.url, withDestinationURL: target)
        XCTAssertThrowsError(try fixture.receipts.allReceipts())
    }

    func testMovedPackagedHelperBecomesBrokenAndRepairUpdatesOnlyOwnedEntry() async throws {
        let fixture = try HardeningFixture()
        let first = ClaudeDesktopIntegrationAdapter(
            configurationURL: fixture.config,
            helperURL: fixture.firstHelper,
            receiptStore: fixture.receipts,
            runner: fixture.runner
        )
        let setup = await first.perform(.setup)
        XCTAssertEqual(setup.outcome, .changed)
        try FileManager.default.removeItem(at: fixture.firstHelper)

        let moved = ClaudeDesktopIntegrationAdapter(
            configurationURL: fixture.config,
            helperURL: fixture.secondHelper,
            receiptStore: fixture.receipts,
            runner: fixture.runner
        )
        let beforeRepair = await moved.inspect()
        XCTAssertEqual(beforeRepair.state, .broken)
        XCTAssertTrue(beforeRepair.statusDetail.contains("Repair"))

        let repair = await moved.perform(.repair)
        XCTAssertEqual(repair.outcome, .changed)
        XCTAssertEqual(try fixture.command(named: "disk-steward"), fixture.secondHelper.path)
        XCTAssertEqual(try fixture.command(named: "foreign"), "/tmp/foreign")
    }

    func testUserModificationAfterReceiptCreatesConflictAndBlocksRemoval() async throws {
        let fixture = try HardeningFixture()
        let adapter = ClaudeDesktopIntegrationAdapter(
            configurationURL: fixture.config,
            helperURL: fixture.firstHelper,
            receiptStore: fixture.receipts,
            runner: fixture.runner
        )
        _ = await adapter.perform(.setup)
        var document = try fixture.document()
        var servers = try XCTUnwrap(document["mcpServers"] as? [String: Any])
        servers["disk-steward"] = ["command": "/tmp/user-edited"]
        document["mcpServers"] = servers
        try fixture.write(document)

        let inspection = await adapter.inspect()
        let removal = await adapter.perform(.remove)

        XCTAssertEqual(inspection.state, .conflict)
        XCTAssertEqual(removal.outcome, .failed)
        XCTAssertEqual(try fixture.command(named: "disk-steward"), "/tmp/user-edited")
    }

    func testMissingPackagedHelperNeverReportsSuccessfulSetup() async throws {
        let fixture = try HardeningFixture()
        try FileManager.default.removeItem(at: fixture.firstHelper)
        let adapter = ClaudeDesktopIntegrationAdapter(
            configurationURL: fixture.config,
            helperURL: fixture.firstHelper,
            receiptStore: fixture.receipts,
            runner: fixture.runner
        )

        let result = await adapter.perform(.setup)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.contains("missing"))
        XCTAssertNil(try fixture.command(named: "disk-steward"))
    }
}

@MainActor
private final class HardeningFixture {
    let root: URL
    let config: URL
    let firstHelper: URL
    let secondHelper: URL
    let receipts: AgentIntegrationReceiptStore
    let runner = HardeningRunner()

    init(beforePersist: @escaping () throws -> Void = {}) throws {
        root = URL(fileURLWithPath: "/tmp/ds-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        config = root.appending(path: "claude_desktop_config.json")
        firstHelper = root.appending(path: "Disk Steward 1.app/Contents/Helpers/disk-witness-mcp")
        secondHelper = root.appending(path: "Disk Steward 2.app/Contents/Helpers/disk-witness-mcp")
        for helper in [firstHelper, secondHelper] {
            try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        }
        receipts = AgentIntegrationReceiptStore(url: root.appending(path: "receipts.json"), beforePersist: beforePersist)
        try write(["mcpServers": ["foreign": ["command": "/tmp/foreign"]]])
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: config, options: .atomic)
    }

    func document() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    }

    func command(named name: String) throws -> String? {
        let servers = try XCTUnwrap(document()["mcpServers"] as? [String: Any])
        return (servers[name] as? [String: Any])?["command"] as? String
    }
}

private actor HardeningRunner: AgentCommandRunning {
    func run(_ command: AgentCommand) async throws -> AgentCommandResult {
        command.arguments == ["--self-check"] ? SelfCheckReportFixture.result(for: command) : .init(exitCode: 0, standardOutput: "ok", standardError: "")
    }
}
