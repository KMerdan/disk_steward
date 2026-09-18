import Foundation
import XCTest

/// TASK-561: the CLI install/uninstall path keeps user additions, refuses to
/// delete what it does not own, records a recoverable manifest-backed backup
/// for every mutation, restores on a mid-way failure, and `rollback` puts a
/// backup back only while the current file is still what that operation
/// wrote. Everything runs against per-test temporary configuration roots.
final class ConfigurationRollbackTests: XCTestCase {
    func testClaudeUpgradePreservesUserAdditionsAndUninstallRefusesToDeleteThem() throws {
        let root = temporaryRoot("ds-own-claude")
        defer { try? FileManager.default.removeItem(at: root) }
        let configRoot = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let config = configRoot.appendingPathComponent(".mcp.json")
        let original: [String: Any] = [
            "custom": "preserve-me",
            "mcpServers": [
                "other": ["command": "other-server"],
                "disk_steward": ["command": "/old/helper", "args": ["--legacy"], "env": ["TOKEN": "secret"], "cwd": "/Users/me"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted]).write(to: config)
        let connector = try fakeConnector(in: root)

        let installed = try run(install, ["--client", "claude", "--config-root", configRoot.path, "--connector", connector.path])
        XCTAssertEqual(installed.status, 0, installed.combined)
        XCTAssertTrue(installed.stdout.contains("Preserved user settings on disk_steward: cwd, env"), installed.combined)
        var configured = try servers(of: config)
        let entry = try XCTUnwrap(configured["disk_steward"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, connector.path)
        XCTAssertEqual(entry["args"] as? [String], ["--legacy"], "user args are kept")
        XCTAssertEqual(entry["env"] as? [String: String], ["TOKEN": "secret"])
        XCTAssertEqual(entry["cwd"] as? String, "/Users/me")
        XCTAssertNotNil(configured["other"])

        let removal = try run(uninstall, ["--client", "claude", "--config-root", configRoot.path])
        XCTAssertEqual(removal.status, 65, removal.combined)
        XCTAssertTrue(removal.stderr.contains("settings Disk Steward does not own (cwd, env)"), removal.combined)
        configured = try servers(of: config)
        XCTAssertNotNil(configured["disk_steward"], "the entry with user additions is never deleted")
        XCTAssertEqual((try jsonObject(config))["custom"] as? String, "preserve-me")
    }

    func testMalformedRootsAndEntriesAreRefusedWithoutChanges() throws {
        for (label, bytes) in [("array root", "[1]"), ("string servers", "{\"mcpServers\": \"x\"}"),
                               ("string args", "{\"mcpServers\": {\"disk_steward\": {\"command\": \"/x\", \"args\": \"bad\"}}}")] {
            let root = temporaryRoot("ds-malformed")
            defer { try? FileManager.default.removeItem(at: root) }
            let configRoot = root.appendingPathComponent("claude")
            try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
            let config = configRoot.appendingPathComponent(".mcp.json")
            try Data(bytes.utf8).write(to: config)
            let connector = try fakeConnector(in: root)
            let result = try run(install, ["--client", "claude", "--config-root", configRoot.path, "--connector", connector.path])
            XCTAssertEqual(result.status, 65, "\(label): \(result.combined)")
            XCTAssertTrue(result.stderr.contains("nothing was changed"), "\(label): \(result.combined)")
            XCTAssertEqual(try Data(contentsOf: config), Data(bytes.utf8), label)
            XCTAssertFalse(result.stderr.contains("restoring"), "a refusal changes nothing, so nothing is restored: \(result.combined)")
        }
    }

    func testInstallThenRollbackRestoresBothClientsAndRefusesEditedFiles() throws {
        let root = temporaryRoot("ds-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = try fakeConnector(in: root)
        for client in ["codex", "claude"] {
            let configRoot = root.appendingPathComponent(client)
            try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
            let config = configRoot.appendingPathComponent(client == "codex" ? "config.toml" : ".mcp.json")
            let original = client == "codex" ? Data("[core]\nname = \"keep\"\n".utf8) : Data("{\"mcpServers\": {\"other\": {\"command\": \"o\"}}, \"custom\": 1}".utf8)
            try original.write(to: config)
            let installed = try run(install, ["--client", client, "--config-root", configRoot.path, "--connector", connector.path])
            XCTAssertEqual(installed.status, 0, installed.combined)
            XCTAssertNotEqual(try Data(contentsOf: config), original)
            let backupsDir = configRoot.appendingPathComponent(".disk-steward-backups")
            let listing = try run(rollback, ["--client", client, "--config-root", configRoot.path, "--list"])
            XCTAssertTrue(listing.stdout.contains("install  \(client)  installed"), listing.combined)
            let manifests = try FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil).map { $0.appendingPathComponent("manifest.json") }
            XCTAssertEqual(manifests.count, 1)
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(manifests.first))) as? [String: Any])
            XCTAssertEqual(manifest["status"] as? String, "installed")
            let record = try XCTUnwrap((manifest["files"] as? [String: Any])?[config.lastPathComponent] as? [String: Any])
            XCTAssertEqual(record["existedBefore"] as? Bool, true)
            XCTAssertNotNil(record["sha256After"])

            let plan = try run(rollback, ["--client", client, "--config-root", configRoot.path, "--dry-run"])
            XCTAssertEqual(plan.status, 0, plan.combined)
            XCTAssertTrue(plan.stdout.contains("Dry run: nothing was changed."), plan.combined)
            XCTAssertNotEqual(try Data(contentsOf: config), original, "a dry run changes nothing")

            // The user edits the installed file: rollback must refuse without --force.
            let edited = try Data(contentsOf: config) + Data("\n".utf8)
            try edited.write(to: config)
            let refused = try run(rollback, ["--client", client, "--config-root", configRoot.path])
            XCTAssertEqual(refused.status, 65, refused.combined)
            XCTAssertTrue(refused.stderr.contains("changed since that backup was made; use --force"), refused.combined)
            XCTAssertEqual(try Data(contentsOf: config), edited)

            let forced = try run(rollback, ["--client", client, "--config-root", configRoot.path, "--force"])
            XCTAssertEqual(forced.status, 0, forced.combined)
            XCTAssertEqual(try Data(contentsOf: config), original, "\(client): the pre-install bytes are back")
            if client == "codex" {
                XCTAssertFalse(FileManager.default.fileExists(atPath: configRoot.appendingPathComponent("plugins/disk-steward").path), "the plugin that did not exist before is gone")
            }
            let after = try FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("rollback-") }
            XCTAssertEqual(after.count, 1, "a rollback saves the state it replaced")
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(after.first).appendingPathComponent("manifest.json"))) as? [String: Any])
            XCTAssertEqual(saved["status"] as? String, "restored")
        }
    }

    func testUninstallBackupIsRestorableAndRollbackRefusesAnotherClientsBackup() throws {
        let root = temporaryRoot("ds-uninstall-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = try fakeConnector(in: root)
        let configRoot = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let config = configRoot.appendingPathComponent("config.toml")
        try Data("[core]\nname = \"keep\"\n".utf8).write(to: config)
        XCTAssertEqual(try run(install, ["--client", "codex", "--config-root", configRoot.path, "--connector", connector.path]).status, 0)
        let installedBytes = try Data(contentsOf: config)
        let removed = try run(uninstall, ["--client", "codex", "--config-root", configRoot.path])
        XCTAssertEqual(removed.status, 0, removed.combined)
        XCTAssertFalse(try String(contentsOf: config, encoding: .utf8).contains("disk_steward"))
        let uninstallBackup = try XCTUnwrap(removed.stdout.split(separator: "\n").first { $0.hasPrefix("Recoverable backup: ") }?.replacingOccurrences(of: "Recoverable backup: ", with: ""))
        let name = URL(fileURLWithPath: uninstallBackup).lastPathComponent
        let wrongClient = try run(rollback, ["--client", "claude", "--config-root", configRoot.path, "--backup", name])
        XCTAssertEqual(wrongClient.status, 65, wrongClient.combined)
        XCTAssertTrue(wrongClient.stderr.contains("backup is for client codex, not claude"), wrongClient.combined)
        let restored = try run(rollback, ["--client", "codex", "--config-root", configRoot.path, "--backup", name])
        XCTAssertEqual(restored.status, 0, restored.combined)
        XCTAssertEqual(try Data(contentsOf: config), installedBytes, "uninstall is undone exactly")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configRoot.appendingPathComponent("plugins/disk-steward/.mcp.json").path), "the plugin directory comes back")
    }

    func testFailureBeforeAnyChangeIsReportedAsARefusalWithoutRestoring() throws {
        let root = temporaryRoot("ds-refused")
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = try fakeConnector(in: root)
        let configRoot = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let config = configRoot.appendingPathComponent("config.toml")
        let original = Data("[core]\nname = \"keep\"\n".utf8)
        try original.write(to: config)
        // A regular file where the plugin directory must be created fails before
        // anything was written: the report says so, and nothing is "restored".
        try Data("busy".utf8).write(to: configRoot.appendingPathComponent("plugins"))
        let result = try run(install, ["--client", "codex", "--config-root", configRoot.path, "--connector", connector.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("nothing was changed"), result.combined)
        XCTAssertFalse(result.stderr.contains("restored"), result.combined)
        XCTAssertEqual(try Data(contentsOf: config), original)
        let manifest = try singleManifest(under: configRoot)
        XCTAssertEqual(manifest["status"] as? String, "refused-nothing-changed")
    }

    func testMidInstallFailureRestoresWhatWasAlreadyWrittenAndKeepsTheBackup() throws {
        let root = temporaryRoot("ds-midfail")
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = try fakeConnector(in: root)
        let configRoot = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        // The plugin step succeeds, then the configuration commit fails because a
        // directory sits where config.toml must be written.
        let config = configRoot.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let result = try run(install, ["--client", "codex", "--config-root", configRoot.path, "--connector", connector.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("restored the codex configuration"), result.combined)
        XCTAssertTrue(result.stderr.contains("nothing from this attempt remains"), result.combined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configRoot.appendingPathComponent("plugins/disk-steward").path), "the plugin written before the failure is removed again")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path, isDirectory: &isDirectory) && isDirectory.boolValue, "the user's directory is untouched")
        let manifest = try singleManifest(under: configRoot)
        XCTAssertEqual(manifest["status"] as? String, "failed-and-restored")
    }

    func testBackupsAreBoundedToTenOwnedDirectoriesAndForeignEntriesStay() throws {
        let root = temporaryRoot("ds-bounded")
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = try fakeConnector(in: root)
        let configRoot = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let backupsDir = configRoot.appendingPathComponent(".disk-steward-backups")
        try FileManager.default.createDirectory(at: backupsDir.appendingPathComponent("user-notes"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: backupsDir.appendingPathComponent("user-notes/keep.txt"))
        for _ in 0..<13 {
            XCTAssertEqual(try run(install, ["--client", "claude", "--config-root", configRoot.path, "--connector", connector.path]).status, 0)
        }
        let entries = try FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)
        let owned = entries.filter { $0.lastPathComponent.first?.isNumber == true }
        XCTAssertEqual(owned.count, 10)
        XCTAssertEqual(try Data(contentsOf: backupsDir.appendingPathComponent("user-notes/keep.txt")), Data("mine".utf8))
    }

    func testDefaultRollbackAndPruningFollowTheStampNotTheNamePrefix() throws {
        let root = temporaryRoot("ds-chrono")
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = try fakeConnector(in: root)
        let configRoot = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let config = configRoot.appendingPathComponent(".mcp.json")
        try Data("{\"mcpServers\": {}}".utf8).write(to: config)
        XCTAssertEqual(try run(install, ["--client", "claude", "--config-root", configRoot.path, "--connector", connector.path]).status, 0)
        let installedBytes = try Data(contentsOf: config)
        // A much newer "uninstalled-" backup by name prefix sorts after any
        // digit-first name lexically, but its stamp is older than the install.
        let backupsDir = configRoot.appendingPathComponent(".disk-steward-backups")
        let stale = backupsDir.appendingPathComponent("uninstalled-20200101T000000Z-1")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("{\"mcpServers\": {\"ancient\": {}}}".utf8).write(to: stale.appendingPathComponent(".mcp.json"))
        let manifest: [String: Any] = ["schema": "disk-steward-client-backup-v1", "operation": "uninstall", "client": "claude", "status": "uninstalled", "createdAt": "2020-01-01T00:00:00Z",
                                       "files": [".mcp.json": ["path": config.path, "existedBefore": true, "sha256Before": "x", "sha256After": "y", "existsAfter": true]], "plugin": NSNull()]
        try JSONSerialization.data(withJSONObject: manifest).write(to: stale.appendingPathComponent("manifest.json"))
        let plan = try run(rollback, ["--client", "claude", "--config-root", configRoot.path, "--dry-run"])
        XCTAssertEqual(plan.status, 0, plan.combined)
        XCTAssertFalse(plan.stdout.contains("uninstalled-20200101T000000Z-1"), "the older uninstall backup must not be chosen by name order: \(plan.combined)")
        XCTAssertTrue(plan.stdout.contains("Rollback plan for claude from 2026"), plan.combined)
        XCTAssertEqual(try Data(contentsOf: config), installedBytes)
        // Pruning keeps the newest ten by stamp: eleven fabricated old
        // rollback-/uninstalled- directories plus the real install make twelve,
        // and the two oldest by stamp go, whatever their prefix.
        for index in 0..<11 {
            let name = (index % 2 == 0 ? "rollback-" : "uninstalled-") + String(format: "2021%02d01T000000Z-%d", index + 1, index)
            let dir = backupsDir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        }
        XCTAssertEqual(try run(install, ["--client", "claude", "--config-root", configRoot.path, "--connector", connector.path]).status, 0)
        let remaining = try FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil).map(\.lastPathComponent).sorted()
        XCTAssertEqual(remaining.count, 10, "\(remaining)")
        XCTAssertFalse(remaining.contains("uninstalled-20200101T000000Z-1"), "the oldest stamp goes first")
        XCTAssertFalse(remaining.contains("rollback-20210101T000000Z-0"))
        XCTAssertEqual(remaining.filter { $0.hasPrefix("2026") }.count, 2, "both real install backups (newest stamps) survive: \(remaining)")
    }

    func testARestoreFailureInsideUndoIsReportedAndKeepsTheBackup() throws {
        let root = URL(fileURLWithPath: "/tmp/ds-undofault-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = try fakeConnector(in: root)
        let configRoot = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: configRoot.appendingPathComponent("plugins/disk-steward"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: configRoot.appendingPathComponent("plugins/disk-steward/.mcp.json"))
        try FileManager.default.createDirectory(at: configRoot.appendingPathComponent("config.toml"), withIntermediateDirectories: true)
        let result = try run(install, ["--client", "codex", "--config-root", configRoot.path, "--connector", connector.path], environment: ["DISK_STEWARD_INTEGRATION_FAULT": "undo-plugin"])
        XCTAssertEqual(result.status, 70, result.combined)
        XCTAssertTrue(result.stderr.contains("automatic restore did not complete"), result.combined)
        XCTAssertTrue(result.stderr.contains("restore them with"), result.combined)
        let manifest = try singleManifest(under: configRoot)
        XCTAssertEqual(manifest["status"] as? String, "restore-failed")
        let backups = try FileManager.default.contentsOfDirectory(at: configRoot.appendingPathComponent(".disk-steward-backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first).appendingPathComponent("disk-steward-plugin/.mcp.json")), Data("mine".utf8), "the previous plugin is still in the backup")
    }

    func testRollbackApplyFailurePutsThePreviousStateBack() throws {
        let root = URL(fileURLWithPath: "/tmp/ds-rbfault-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = try fakeConnector(in: root)
        let configRoot = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let config = configRoot.appendingPathComponent("config.toml")
        try Data("[core]\nname = \"keep\"\n".utf8).write(to: config)
        XCTAssertEqual(try run(install, ["--client", "codex", "--config-root", configRoot.path, "--connector", connector.path]).status, 0)
        let installed = try Data(contentsOf: config)
        let plugin = configRoot.appendingPathComponent("plugins/disk-steward/.mcp.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.path))
        let result = try run(rollback, ["--client", "codex", "--config-root", configRoot.path], environment: ["DISK_STEWARD_INTEGRATION_FAULT": "rollback-plugin"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("putting the previous state back"), result.combined)
        XCTAssertTrue(result.stderr.contains("previous state is back"), result.combined)
        XCTAssertEqual(try Data(contentsOf: config), installed, "the installed configuration is back after the failed rollback")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.path), "the plugin is back")
        let saves = try FileManager.default.contentsOfDirectory(at: configRoot.appendingPathComponent(".disk-steward-backups"), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("rollback-") }
        XCTAssertEqual(saves.count, 1)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(saves.first).appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["status"] as? String, "rollback-failed-and-restored", "the safety backup is finished, never left in progress")
    }

    // MARK: - helpers

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var install: URL { repositoryRoot.appendingPathComponent("Scripts/Integration/install") }
    private var uninstall: URL { repositoryRoot.appendingPathComponent("Scripts/Integration/uninstall") }
    private var rollback: URL { repositoryRoot.appendingPathComponent("Scripts/Integration/rollback") }

    private func temporaryRoot(_ prefix: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(prefix)-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
    }

    private func fakeConnector(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let connector = root.appendingPathComponent("disk-witness-mcp")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: connector)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: connector.path)
        return connector
    }

    private func singleManifest(under configRoot: URL) throws -> [String: Any] {
        let entries = try FileManager.default.contentsOfDirectory(at: configRoot.appendingPathComponent(".disk-steward-backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 1)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(entries.first).appendingPathComponent("manifest.json"))) as? [String: Any])
    }

    private func jsonObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func servers(of url: URL) throws -> [String: Any] {
        try XCTUnwrap(jsonObject(url)["mcpServers"] as? [String: Any])
    }

    private func run(_ script: URL, _ arguments: [String], environment: [String: String] = [:]) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path] + arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptResult(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
    }
}

private struct ScriptResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var combined: String { stdout + stderr }
}
