@testable import DiskStewardApp
import Foundation
import XCTest

/// TASK-561: every client-configuration mutation preserves the user's file
/// byte for byte or fails with an explicit, recoverable report. Malformed
/// roots and args, user additions (env, cwd, unknown keys), second profiles,
/// concurrent writes and a failure at each mutation step are exercised on
/// isolated fixtures; setup and remove stay idempotent.
@MainActor
final class ConfigurationOwnershipTests: XCTestCase {
    func testMalformedRootAndArgsFailClosedWithoutTouchingTheFile() async throws {
        for (label, bytes) in [("array root", "[1, 2]"), ("string servers", "{\"mcpServers\": \"nope\"}"),
                               ("string args", "{\"mcpServers\": {\"disk-steward\": {\"command\": \"/x\", \"args\": \"--bad\"}}}"),
                               ("missing command", "{\"mcpServers\": {\"disk-steward\": {\"args\": []}}}")] {
            let fixture = try OwnershipFixture()
            try Data(bytes.utf8).write(to: fixture.config, options: .atomic)
            let original = try Data(contentsOf: fixture.config)
            let adapter = fixture.adapter()
            let inspected = await adapter.inspect()
            XCTAssertEqual(inspected.state, .broken, label)
            for action in [AgentIntegrationAction.setup, .repair, .remove] {
                let result = await adapter.perform(action)
                XCTAssertEqual(result.outcome, .failed, "\(label) \(action)")
                XCTAssertEqual(try Data(contentsOf: fixture.config), original, "\(label) \(action) must not rewrite a malformed file")
            }
            XCTAssertNil(try fixture.receipts.receipt(for: .claudeDesktop), label)
            XCTAssertTrue(PrivateIntegrationFile.backups(for: fixture.config).isEmpty, "No backup is written when nothing is changed")
        }
    }

    func testUserAdditionsAreNeverOverwrittenOrRemoved() async throws {
        for (label, entry) in [("env", ["command": "/tmp/helper", "args": [], "env": ["TOKEN": "secret"]] as [String: Any]),
                               ("cwd", ["command": "/tmp/helper", "cwd": "/Users/me"] as [String: Any]),
                               ("unknown key", ["command": "/tmp/helper", "args": ["--flag"], "timeout": 30] as [String: Any])] {
            let fixture = try OwnershipFixture()
            try fixture.write(["mcpServers": ["disk-steward": entry, "foreign": ["command": "/tmp/foreign"]], "theme": "dark"])
            let original = try Data(contentsOf: fixture.config)
            let adapter = fixture.adapter()
            let observed1 = await adapter.inspect().state
            XCTAssertEqual(observed1, .conflict, label)
            for action in [AgentIntegrationAction.setup, .repair, .remove] {
                let result = await adapter.perform(action)
                XCTAssertEqual(result.outcome, .failed, "\(label) \(action)")
                XCTAssertTrue(result.message.contains("does not own"), result.message)
                XCTAssertTrue(result.message.contains(fixture.config.path), "The report names the file: \(result.message)")
                XCTAssertEqual(try Data(contentsOf: fixture.config), original, "\(label) \(action) must preserve the user's entry")
            }
            // An owned entry that the user later extends becomes a conflict too.
            let clean = try OwnershipFixture()
            let owner = clean.adapter()
            let observed2 = await owner.perform(.setup).outcome
            XCTAssertEqual(observed2, .changed)
            var document = try clean.document()
            var servers = try XCTUnwrap(document["mcpServers"] as? [String: Any])
            var owned = try XCTUnwrap(servers["disk-steward"] as? [String: Any])
            owned["env"] = ["EXTRA": "1"]
            servers["disk-steward"] = owned
            document["mcpServers"] = servers
            try clean.write(document)
            let extended = try Data(contentsOf: clean.config)
            let observed3 = await owner.inspect().state
            XCTAssertEqual(observed3, .conflict, "user additions to an owned entry end ownership")
            let observed4 = await owner.perform(.repair).outcome
            XCTAssertEqual(observed4, .failed)
            let observed5 = await owner.perform(.remove).outcome
            XCTAssertEqual(observed5, .failed)
            XCTAssertEqual(try Data(contentsOf: clean.config), extended)
        }
    }

    func testSecondProfileAndUnrelatedKeysStayUntouchedAcrossSetupRepairRemove() async throws {
        let fixture = try OwnershipFixture()
        let profile = fixture.root.appending(path: "profiles/work/claude_desktop_config.json")
        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let profileBytes = Data("{\"mcpServers\": {\"disk-steward\": {\"command\": \"/somewhere/else\"}}, \"note\": \"work profile\"}".utf8)
        try profileBytes.write(to: profile, options: .atomic)
        try fixture.write(["mcpServers": ["foreign": ["command": "/tmp/foreign", "env": ["A": "1"]]], "theme": "dark", "nested": ["keep": [1, 2, 3]]])
        let adapter = fixture.adapter()
        let observed6 = await adapter.perform(.setup).outcome
        XCTAssertEqual(observed6, .changed)
        let observed7 = await adapter.perform(.repair).outcome
        XCTAssertEqual(observed7, .changed)
        let observed8 = await adapter.perform(.remove).outcome
        XCTAssertEqual(observed8, .changed)
        let document = try fixture.document()
        XCTAssertEqual(document["theme"] as? String, "dark")
        XCTAssertEqual((document["nested"] as? [String: Any])?["keep"] as? [Int], [1, 2, 3])
        let servers = try XCTUnwrap(document["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["foreign"] as? [String: Any])?["env"] as? [String: String], ["A": "1"])
        XCTAssertNil(servers["disk-steward"])
        XCTAssertEqual(try Data(contentsOf: profile), profileBytes, "Another profile's file is never read or written")
        // The other profile is a separate file: without a receipt it is external, never ours.
        let profileAdapter = fixture.adapter(configuration: profile)
        let observed9 = await profileAdapter.inspect().state
        XCTAssertEqual(observed9, .conflict)
        let observed10 = await profileAdapter.perform(.remove).outcome
        XCTAssertEqual(observed10, .failed)
        XCTAssertEqual(try Data(contentsOf: profile), profileBytes)
    }

    func testConcurrentWriteBetweenReadAndCommitIsAnExplicitRecoverableConflict() async throws {
        for action in [AgentIntegrationAction.setup, .repair, .remove] {
            let fixture = try OwnershipFixture()
            let adapter = fixture.adapter()
            if action != .setup {
                let prepared = await adapter.perform(.setup).outcome
                XCTAssertEqual(prepared, .changed)
            }
            let receiptBefore = try fixture.receipts.receipt(for: .claudeDesktop)
            let backupsBefore = PrivateIntegrationFile.backups(for: fixture.config).count
            let invocationsBefore = adapter.beforeCommitInvocations
            let concurrent = Data("{\"mcpServers\": {\"foreign\": {\"command\": \"/tmp/foreign\"}}, \"other-writer\": true}".utf8)
            adapter.beforeCommit = { try concurrent.write(to: fixture.config, options: .atomic) }
            let result = await adapter.perform(action)
            XCTAssertEqual(result.outcome, .failed, "\(action)")
            XCTAssertTrue(result.message.contains("changed while Disk Steward was editing it"), result.message)
            XCTAssertTrue(result.message.contains(".disk-steward-backups"), "The report names the backup: \(result.message)")
            XCTAssertEqual(try Data(contentsOf: fixture.config), concurrent, "\(action): the other writer's file wins and is never lost")
            XCTAssertEqual(try fixture.receipts.receipt(for: .claudeDesktop), receiptBefore, "\(action): no receipt change without a commit")
            let backups = PrivateIntegrationFile.backups(for: fixture.config)
            XCTAssertEqual(backups.count, backupsBefore + 1, "\(action)")
            XCTAssertNotEqual(try Data(contentsOf: try XCTUnwrap(backups.last)), concurrent, "The backup holds the bytes read before the edit")
            XCTAssertEqual(adapter.beforeCommitInvocations, invocationsBefore + 1)
        }
    }

    func testConcurrentCreationOfAMissingFileIsRefused() async throws {
        let fixture = try OwnershipFixture()
        try FileManager.default.removeItem(at: fixture.config)
        let adapter = fixture.adapter()
        let concurrent = Data("{\"mcpServers\": {}}".utf8)
        adapter.beforeCommit = { try concurrent.write(to: fixture.config, options: .atomic) }
        let result = await adapter.perform(.setup)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.contains("changed while Disk Steward was editing it"), result.message)
        XCTAssertEqual(try Data(contentsOf: fixture.config), concurrent)
        XCTAssertNil(try fixture.receipts.receipt(for: .claudeDesktop))
    }

    func testBackupFailureChangesNothing() async throws {
        let fixture = try OwnershipFixture()
        // A regular file where the private backup directory must go.
        try Data("occupied".utf8).write(to: PrivateIntegrationFile.backupDirectory(for: fixture.config))
        let original = try Data(contentsOf: fixture.config)
        let adapter = fixture.adapter()
        let result = await adapter.perform(.setup)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.contains("could not write a backup"), result.message)
        XCTAssertTrue(result.message.contains("changed nothing"), result.message)
        XCTAssertEqual(try Data(contentsOf: fixture.config), original)
        XCTAssertNil(try fixture.receipts.receipt(for: .claudeDesktop))
    }

    func testCommitFailureLeavesTheFileAndNamesTheBackup() async throws {
        let fixture = try OwnershipFixture()
        let adapter = fixture.adapter()
        let observed11 = await adapter.perform(.setup).outcome
        XCTAssertEqual(observed11, .changed)
        let original = try Data(contentsOf: fixture.config)
        let receipt = try fixture.receipts.receipt(for: .claudeDesktop)
        // The directory becomes unwritable after the backup is written.
        adapter.beforeCommit = { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.root.path) }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path) }
        let result = await adapter.perform(.repair)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.contains("could not save"), result.message)
        XCTAssertTrue(result.message.contains(".disk-steward-backups"), result.message)
        XCTAssertEqual(try Data(contentsOf: fixture.config), original)
        XCTAssertEqual(try fixture.receipts.receipt(for: .claudeDesktop), receipt)
    }

    func testReceiptFailureRestoresOrReportsTheBackupWhenRestoreIsImpossible() async throws {
        // Restore succeeds: exact bytes come back (covered for all actions in
        // AgentIntegrationHardeningTests). Here the file changes again before
        // the restore, so the restore must refuse and name the backup.
        var failWrites = false
        let fixture = try OwnershipFixture(beforePersist: { if failWrites { throw CocoaError(.fileWriteOutOfSpace) } })
        let adapter = fixture.adapter()
        let concurrent = Data("{\"mcpServers\": {\"foreign\": {\"command\": \"/tmp/foreign\"}}, \"third-writer\": true}".utf8)
        adapter.beforeRestore = { try concurrent.write(to: fixture.config, options: .atomic) }
        failWrites = true
        let result = await adapter.perform(.setup)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.contains("could not restore the file automatically"), result.message)
        XCTAssertTrue(result.message.contains(".disk-steward-backups"), result.message)
        XCTAssertEqual(try Data(contentsOf: fixture.config), concurrent, "The later writer's file is preserved")
        XCTAssertNil(try fixture.receipts.receipt(for: .claudeDesktop))
        let backup = try XCTUnwrap(PrivateIntegrationFile.backups(for: fixture.config).first)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any])
        XCTAssertNotNil((saved["mcpServers"] as? [String: Any])?["foreign"], "The backup is the user's pre-edit configuration")
    }

    func testFailedUndoSwapPreservesTheOtherWritersBytesAndSaysSo() async throws {
        let fixture = try OwnershipFixture()
        let adapter = fixture.adapter()
        let prepared = await adapter.perform(.setup).outcome
        XCTAssertEqual(prepared, .changed)
        let concurrent = Data("{\"mcpServers\": {\"foreign\": {\"command\": \"/tmp/foreign\"}}, \"other-writer\": 2}".utf8)
        adapter.beforeCommit = { try concurrent.write(to: fixture.config, options: .atomic) }
        PrivateIntegrationFile.undoSwapFaultForTesting = true
        defer { PrivateIntegrationFile.undoSwapFaultForTesting = false }
        let result = await adapter.perform(.repair)
        PrivateIntegrationFile.undoSwapFaultForTesting = false
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.contains("could not put that program's version back"), result.message)
        XCTAssertTrue(result.message.contains("preserved at"), result.message)
        let preservedPath = try XCTUnwrap(result.message.components(separatedBy: "preserved at ").last?.components(separatedBy: ". Merge").first)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: preservedPath)), concurrent, "the other writer's bytes survive at the named path")
        XCTAssertTrue(preservedPath.contains(".disk-steward-backups"), preservedPath)
        XCTAssertNotEqual(try Data(contentsOf: fixture.config), concurrent, "Disk Steward's version stands, as the message says")
        XCTAssertNil(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).first { $0.hasPrefix(".disk-steward-") && $0.hasSuffix(".tmp") }, "no stray temporary file is left")
    }

    func testSetupAndRemoveAreIdempotentAndBackupsStayBounded() async throws {
        let fixture = try OwnershipFixture()
        let adapter = fixture.adapter()
        let observed12 = await adapter.perform(.setup).outcome
        XCTAssertEqual(observed12, .changed)
        let observed13 = await adapter.perform(.setup).outcome
        XCTAssertEqual(observed13, .unchanged)
        let receipt = try XCTUnwrap(try fixture.receipts.receipt(for: .claudeDesktop))
        XCTAssertNotNil(receipt.lastBackupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(receipt.lastBackupPath)))
        for _ in 0..<14 {
            let repaired = await adapter.perform(.repair).outcome
            XCTAssertEqual(repaired, .changed)
        }
        XCTAssertEqual(PrivateIntegrationFile.backups(for: fixture.config).count, PrivateIntegrationFile.backupLimitPerFile)
        let observed14 = await adapter.perform(.remove).outcome
        XCTAssertEqual(observed14, .changed)
        let observed15 = await adapter.perform(.remove).outcome
        XCTAssertEqual(observed15, .unchanged)
        XCTAssertNil(try fixture.receipts.receipt(for: .claudeDesktop))
        let document = try fixture.document()
        XCTAssertNotNil((document["mcpServers"] as? [String: Any])?["foreign"])
        // Backups of other files in the same directory are never pruned.
        let sibling = PrivateIntegrationFile.backupDirectory(for: fixture.config).appending(path: "other.json.20260101T000000Z-x.bak")
        try Data("other".utf8).write(to: sibling)
        for _ in 0..<3 { _ = await adapter.perform(.setup); _ = await adapter.perform(.remove) }
        XCTAssertEqual(try Data(contentsOf: sibling), Data("other".utf8))
        XCTAssertLessThanOrEqual(PrivateIntegrationFile.backups(for: fixture.config).count, PrivateIntegrationFile.backupLimitPerFile)
    }
}

@MainActor
private final class OwnershipFixture {
    let root: URL
    let config: URL
    let helper: URL
    let receipts: AgentIntegrationReceiptStore
    let runner = OwnershipRunner()

    init(beforePersist: @escaping () throws -> Void = {}) throws {
        root = URL(fileURLWithPath: "/tmp/ds-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        config = root.appending(path: "claude_desktop_config.json")
        helper = root.appending(path: "Disk Steward.app/Contents/Helpers/disk-witness-mcp")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        receipts = AgentIntegrationReceiptStore(url: root.appending(path: "support/receipts.json"), beforePersist: beforePersist)
        try write(["mcpServers": ["foreign": ["command": "/tmp/foreign"]]])
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    func adapter(configuration: URL? = nil) -> ClaudeDesktopIntegrationAdapter {
        ClaudeDesktopIntegrationAdapter(configurationURL: configuration ?? config, helperURL: helper, receiptStore: receipts, runner: runner)
    }

    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: config, options: .atomic)
    }

    func document() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    }
}

private actor OwnershipRunner: AgentCommandRunning {
    func run(_ command: AgentCommand) async throws -> AgentCommandResult {
        .init(exitCode: 0, standardOutput: "ok", standardError: "")
    }
}
