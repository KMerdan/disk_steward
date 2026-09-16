@testable import DiskStewardApp
import Foundation
import XCTest

@MainActor
final class RemainingClientsAdapterTests: XCTestCase {
    func testCursorSetupUsesClientOwnedInstallLinkAndBecomesApprovalPending() async throws {
        let fixture = try RemainingFixture(client: .cursor)
        let adapter = CursorIntegrationAdapter(
            configurationURL: fixture.config,
            helperURL: fixture.helper,
            receiptStore: fixture.receipts,
            runner: fixture.runner,
            linkOpener: fixture.opener
        )

        let result = await adapter.perform(.setup)

        XCTAssertEqual(result.outcome, .approvalRequired)
        XCTAssertEqual(result.snapshot.state, .approvalPending)
        let url = try XCTUnwrap(fixture.opener.urls.first)
        XCTAssertEqual(url.scheme, "cursor")
        XCTAssertTrue(url.absoluteString.contains("mcp/install"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.config.path))
    }

    func testVSCodeInstallLinkCarriesAStdioDefinition() async throws {
        let fixture = try RemainingFixture(client: .visualStudioCode)
        let adapter = VSCodeIntegrationAdapter(
            configurationURL: fixture.config,
            helperURL: fixture.helper,
            receiptStore: fixture.receipts,
            runner: fixture.runner,
            linkOpener: fixture.opener
        )

        let result = await adapter.perform(.setup)

        XCTAssertEqual(result.outcome, .approvalRequired)
        XCTAssertEqual(fixture.opener.urls.first?.scheme, "vscode")
        XCTAssertTrue(fixture.opener.urls.first?.absoluteString.contains("stdio") == true)
    }

    func testClaudeDesktopDirectSetupPreservesForeignKeysAndMakesBackup() async throws {
        let fixture = try RemainingFixture(client: .claudeDesktop)
        try fixture.writeConfig([
            "theme": "dark",
            "mcpServers": ["foreign": ["command": "/tmp/foreign"]],
        ])
        let adapter = ClaudeDesktopIntegrationAdapter(
            configurationURL: fixture.config,
            helperURL: fixture.helper,
            receiptStore: fixture.receipts,
            runner: fixture.runner
        )

        let setup = await adapter.perform(.setup)
        XCTAssertEqual(setup.outcome, .changed)
        let object = try fixture.readConfig()
        XCTAssertEqual(object["theme"] as? String, "dark")
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["foreign"])
        XCTAssertNotNil(servers["disk-steward"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.config.appendingPathExtension("disk-steward-backup").path))
    }

    func testForeignEntryFailsClosedAndRemovalPreservesOtherEntries() async throws {
        let fixture = try RemainingFixture(client: .claudeDesktop)
        try fixture.writeConfig(["mcpServers": [
            "foreign": ["command": "/tmp/foreign"],
            "disk-steward": ["command": "/tmp/not-owned"],
        ]])
        let adapter = ClaudeDesktopIntegrationAdapter(
            configurationURL: fixture.config,
            helperURL: fixture.helper,
            receiptStore: fixture.receipts,
            runner: fixture.runner
        )
        let setup = await adapter.perform(.setup)
        let removal = await adapter.perform(.remove)
        XCTAssertEqual(setup.outcome, .failed)
        XCTAssertEqual(removal.outcome, .failed)
        XCTAssertEqual(try fixture.definition(named: "disk-steward")?.command, "/tmp/not-owned")
        XCTAssertEqual(try fixture.definition(named: "foreign")?.command, "/tmp/foreign")
    }

    func testOwnedDirectEntryCanVerifyRepairAndRemoveWithoutTouchingForeignEntry() async throws {
        let fixture = try RemainingFixture(client: .claudeDesktop)
        try fixture.writeConfig(["mcpServers": ["foreign": ["command": "/tmp/foreign"]]])
        let adapter = ClaudeDesktopIntegrationAdapter(
            configurationURL: fixture.config,
            helperURL: fixture.helper,
            receiptStore: fixture.receipts,
            runner: fixture.runner
        )
        _ = await adapter.perform(.setup)

        let verification = await adapter.perform(.verify)
        let repair = await adapter.perform(.repair)
        let removal = await adapter.perform(.remove)
        XCTAssertEqual(verification.snapshot.state, .verified)
        XCTAssertEqual(repair.outcome, .changed)
        XCTAssertEqual(removal.outcome, .changed)
        XCTAssertNil(try fixture.definition(named: "disk-steward"))
        XCTAssertEqual(try fixture.definition(named: "foreign")?.command, "/tmp/foreign")
    }

    func testManualAdapterCopiesPortableConfigAndExplainsClientOwnedRemoval() async throws {
        let fixture = try RemainingFixture(client: .manual)
        let copier = FixtureCopier()
        let adapter = ManualIntegrationAdapter(helperURL: fixture.helper, runner: fixture.runner, copier: copier)

        let setup = await adapter.perform(.setup)
        XCTAssertEqual(setup.outcome, .unchanged)
        let copied = try XCTUnwrap(copier.value)
        XCTAssertTrue(copied.contains("disk-steward"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(copied.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers["disk-steward"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, fixture.helper.path)
        let removal = await adapter.perform(.remove)
        XCTAssertEqual(removal.outcome, .unchanged)
        XCTAssertTrue(removal.message.contains("client-owned"))
    }
}

@MainActor
private final class RemainingFixture {
    let root: URL
    let helper: URL
    let config: URL
    let receipts: AgentIntegrationReceiptStore
    let runner = RemainingRunner()
    let opener = FixtureLinkOpener()

    init(client: AgentClientID) throws {
        root = URL(fileURLWithPath: "/tmp/ds-remaining-\(client.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        helper = root.appending(path: "disk-witness-mcp")
        FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        config = root.appending(path: "client.json")
        receipts = AgentIntegrationReceiptStore(url: root.appending(path: "receipts.json"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func writeConfig(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: config)
    }

    func readConfig() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    }

    func definition(named name: String) throws -> AgentIntegrationDefinition? {
        let object = try readConfig()
        guard let servers = object["mcpServers"] as? [String: Any],
              let entry = servers[name] as? [String: Any],
              let command = entry["command"] as? String
        else { return nil }
        return .init(command: command, arguments: entry["args"] as? [String] ?? [])
    }
}

@MainActor
private final class FixtureLinkOpener: AgentIntegrationLinkOpening {
    var urls: [URL] = []
    func open(_ url: URL) -> Bool { urls.append(url); return true }
}

@MainActor
private final class FixtureCopier: ManualConfigurationCopying {
    var value: String?
    func copy(_ value: String) -> Bool { self.value = value; return true }
}

private actor RemainingRunner: AgentCommandRunning {
    func run(_ command: AgentCommand) async throws -> AgentCommandResult {
        .init(exitCode: 0, standardOutput: "ok", standardError: "")
    }
}
