import DiskStewardCore
import Foundation
import XCTest

final class IntegrationInstallTests: XCTestCase {
    func testHelperSelfCheckRequiresLiveEvidenceService() throws {
        let root = temporaryRoot("ds-helper")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("evidence.sock")
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: FixtureEvidenceHandler())
        try server.start()
        let helper = try connectorURL()
        let available = try run(helper.path, ["--self-check"], environment: ["DISK_STEWARD_SOCKET_PATH": socket.path])
        XCTAssertEqual(available.status, 0, available.combined)
        server.stop()
        let unavailable = try run(helper.path, ["--self-check"], environment: ["DISK_STEWARD_SOCKET_PATH": socket.path])
        XCTAssertNotEqual(unavailable.status, 0, "Helper protocol initialization alone is not app connectivity")
    }
    func testInstallAndUninstallDryRunsAreMutationFree() throws {
        let root = temporaryRoot("ds-dry")
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = try connectorURL()

        for client in ["codex", "claude"] {
            let configRoot = root.appendingPathComponent(client)
            let installPreview = try run("/bin/zsh", [install.path, "--client", client, "--config-root", configRoot.path, "--connector", connector.path, "--dry-run"])
            XCTAssertEqual(installPreview.status, 0, installPreview.combined)
            XCTAssertTrue(installPreview.stdout.contains("Only the disk_steward MCP entry"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: configRoot.path))

            let uninstallPreview = try run("/bin/zsh", [uninstall.path, "--client", client, "--config-root", configRoot.path, "--dry-run"])
            XCTAssertEqual(uninstallPreview.status, 0, uninstallPreview.combined)
            XCTAssertTrue(uninstallPreview.stdout.contains("evidence and unrelated client settings"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: configRoot.path))
        }
    }

    func testCodexInstallUpgradeAndUninstallPreserveUnrelatedConfigurationAndEvidence() throws {
        let root = temporaryRoot("ds-codex")
        defer { try? FileManager.default.removeItem(at: root) }
        let configRoot = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let config = configRoot.appendingPathComponent("config.toml")
        try "[mcp_servers.other]\ncommand = \"other-server\"\n".write(to: config, atomically: true, encoding: .utf8)
        let evidence = root.appendingPathComponent("evidence.sqlite")
        try Data("do-not-delete".utf8).write(to: evidence)

        let connector = try connectorURL()
        let first = try run("/bin/zsh", [install.path, "--client", "codex", "--config-root", configRoot.path, "--connector", connector.path])
        XCTAssertEqual(first.status, 0, first.combined)
        try assertCodexDiscovery(configRoot: configRoot, connector: connector)

        let second = try run("/bin/zsh", [install.path, "--client", "codex", "--config-root", configRoot.path, "--connector", connector.path])
        XCTAssertEqual(second.status, 0, second.combined)
        let upgraded = try String(contentsOf: config, encoding: .utf8)
        XCTAssertEqual(upgraded.components(separatedBy: "# BEGIN DISK STEWARD MANAGED v1").count - 1, 1)
        XCTAssertTrue(try containsBackup(named: "config.toml", below: configRoot.appendingPathComponent(".disk-steward-backups")))

        let removed = try run("/bin/zsh", [uninstall.path, "--client", "codex", "--config-root", configRoot.path])
        XCTAssertEqual(removed.status, 0, removed.combined)
        let final = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(final.contains("mcp_servers.other"))
        XCTAssertFalse(final.contains("DISK STEWARD MANAGED"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configRoot.appendingPathComponent("plugins/disk-steward").path))
        XCTAssertEqual(try Data(contentsOf: evidence), Data("do-not-delete".utf8))
    }

    func testCodexInstallerFailsClosedOnMalformedManagedMarkers() throws {
        let root = temporaryRoot("ds-marker")
        defer { try? FileManager.default.removeItem(at: root) }
        let configRoot = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let config = configRoot.appendingPathComponent("config.toml")
        let malformed = "[mcp_servers.other]\ncommand = \"other-server\"\n# BEGIN DISK STEWARD MANAGED v1\nimportant = \"preserve\"\n"
        try malformed.write(to: config, atomically: true, encoding: .utf8)

        let result = try run("/bin/zsh", [install.path, "--client", "codex", "--config-root", configRoot.path, "--connector", try connectorURL().path])
        XCTAssertEqual(result.status, 65)
        XCTAssertTrue(result.combined.contains("managed markers are malformed"))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), malformed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configRoot.appendingPathComponent("plugins/disk-steward").path))
    }

    func testClaudeInstallUpgradeAndUninstallMergeOnlyOwnedServer() throws {
        let root = temporaryRoot("ds-claude")
        defer { try? FileManager.default.removeItem(at: root) }
        let configRoot = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let config = configRoot.appendingPathComponent(".mcp.json")
        let original: [String: Any] = [
            "custom": "preserve-me",
            "mcpServers": ["other": ["command": "other-server", "args": []]],
        ]
        try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted]).write(to: config)
        let evidence = root.appendingPathComponent("evidence.sqlite")
        try Data("retained".utf8).write(to: evidence)

        let connector = try connectorURL()
        for _ in 0 ..< 2 {
            let result = try run("/bin/zsh", [install.path, "--client", "claude", "--config-root", configRoot.path, "--connector", connector.path])
            XCTAssertEqual(result.status, 0, result.combined)
        }
        var object = try jsonObject(config)
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["disk_steward"] as? [String: Any])?["command"] as? String, connector.path)
        XCTAssertNotNil(servers["other"])
        XCTAssertEqual(object["custom"] as? String, "preserve-me")

        let removed = try run("/bin/zsh", [uninstall.path, "--client", "claude", "--config-root", configRoot.path])
        XCTAssertEqual(removed.status, 0, removed.combined)
        object = try jsonObject(config)
        let remaining = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertNil(remaining["disk_steward"])
        XCTAssertNotNil(remaining["other"])
        XCTAssertEqual(object["custom"] as? String, "preserve-me")
        XCTAssertEqual(try Data(contentsOf: evidence), Data("retained".utf8))
    }

    func testInstalledConnectorDiscoversToolsAndQueriesEvidenceOverPrivateSocket() throws {
        let root = temporaryRoot("ds-query")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("private/evidence.sock")
        let handler = FixtureEvidenceHandler()
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: handler)
        try server.start()
        defer { server.stop() }

        let transcript = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"install-test","version":"1"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
        {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_storage_summary","arguments":{}}}

        """
        let result = try run(
            try connectorURL().path,
            [],
            input: transcript,
            environment: ["DISK_STEWARD_SOCKET_PATH": socket.path]
        )
        XCTAssertEqual(result.status, 0, result.combined)
        XCTAssertTrue(result.stdout.contains("get_task_impact"))
        XCTAssertTrue(result.stdout.contains("integration-fixture-summary"))
        XCTAssertFalse(result.stdout.contains("delete_file"))
    }

    func testSessionAdapterRegistersFixtureAndDoctorExplainsUnavailableApp() throws {
        let root = temporaryRoot("ds-session")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("private/evidence.sock")
        let handler = FixtureEvidenceHandler()
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: handler)
        try server.start()
        defer { server.stop() }

        let registration = try run("/usr/bin/swift", [session.path, "register", "--client", "codex", "--session-id", "fixture-task", "--workspace", root.path, "--process-pid", String(ProcessInfo.processInfo.processIdentifier), "--lease-seconds", "600", "--socket", socket.path])
        XCTAssertEqual(registration.status, 0, registration.combined)
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(registration.stdout.utf8)) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["session_id"] as? String, "fixture-task")
        XCTAssertEqual(result["confidence"] as? String, "tool-linked")
        let registrationID = try XCTUnwrap(result["registration_id"] as? String)

        let ended = try run("/usr/bin/swift", [session.path, "end", "--registration-id", registrationID, "--socket", socket.path])
        XCTAssertEqual(ended.status, 0, ended.combined)
        XCTAssertTrue(ended.stdout.contains("\"lifecycle\":\"ended\""))

        let configRoot = root.appendingPathComponent("codex")
        let installed = try run("/bin/zsh", [install.path, "--client", "codex", "--config-root", configRoot.path, "--connector", try connectorURL().path])
        XCTAssertEqual(installed.status, 0, installed.combined)
        let unavailable = try run("/bin/zsh", [doctor.path, "--client", "codex", "--config-root", configRoot.path, "--connector", try connectorURL().path, "--socket", root.appendingPathComponent("missing.sock").path])
        XCTAssertEqual(unavailable.status, 2)
        XCTAssertTrue(unavailable.combined.contains("open Disk Steward and enable Monitoring"))

        let dryRun = try run("/bin/zsh", [doctor.path, "--dry-run"])
        XCTAssertEqual(dryRun.status, 0, dryRun.combined)
        XCTAssertTrue(dryRun.stdout.contains("without scanning the disk or changing evidence"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var install: URL { repositoryRoot.appendingPathComponent("Scripts/Integration/install") }
    private var uninstall: URL { repositoryRoot.appendingPathComponent("Scripts/Integration/uninstall") }
    private var doctor: URL { repositoryRoot.appendingPathComponent("Scripts/Integration/doctor") }
    private var session: URL { repositoryRoot.appendingPathComponent("Scripts/Integration/session") }

    private func connectorURL() throws -> URL {
        if let packaged = ProcessInfo.processInfo.environment["DISK_STEWARD_PACKAGED_HELPER"] {
            return try validatedPackagedHelper(packaged)
        }
        let candidates = [
            repositoryRoot.appendingPathComponent(".build/debug/disk-witness-mcp"),
            repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/disk-witness-mcp"),
        ]
        return try XCTUnwrap(candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }), "Build disk-witness-mcp before running integration tests")
    }

    func testPackagedHelperOverridesFailBeforeExecutionOutsideDisposableBuild() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ds-helper-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appending(path: "helper")
        let sentinel = Data("not an executable program; must not run".utf8)
        try sentinel.write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let alias = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: helper)
        for invalid in ["/Applications/Disk Steward.app/Contents/Helpers/disk-witness-mcp", "/private/tmp/../../Applications/helper", "relative-helper", alias.path, root.path] {
            XCTAssertThrowsError(try validatedPackagedHelper(invalid), invalid)
        }
        XCTAssertEqual(try validatedPackagedHelper(helper.path), helper)
        XCTAssertEqual(try Data(contentsOf: helper), sentinel)
    }

    private func validatedPackagedHelper(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        let resolved = realpath(path, nil)
        defer { if let resolved { free(resolved) } }
        var metadata = stat()
        guard path.hasPrefix("/private/tmp/"),
              let resolved, String(cString: resolved) == path,
              lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isExecutableFile(atPath: path) else {
            // XCTest assertions alone do not stop the caller from executing.
            throw NSError(domain: "DiskSteward.TestIsolation", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Packaged helper must be a regular executable in a disposable /private/tmp build with no symlinks or traversal."
            ])
        }
        return url
    }

    private func temporaryRoot(_ prefix: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(prefix)-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
    }

    private func assertCodexDiscovery(configRoot: URL, connector: URL) throws {
        let text = try String(contentsOf: configRoot.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(text.contains("mcp_servers.other"))
        XCTAssertTrue(text.contains("mcp_servers.disk_steward"))
        XCTAssertTrue(text.contains(connector.path))
        let plugin = configRoot.appendingPathComponent("plugins/disk-steward")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.appendingPathComponent(".codex-plugin/plugin.json").path))
        let mcp = try jsonObject(plugin.appendingPathComponent(".mcp.json"))
        let servers = try XCTUnwrap(mcp["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["disk_steward"] as? [String: Any])?["command"] as? String, connector.path)
    }

    private func jsonObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func containsBackup(named name: String, below root: URL) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        return enumerator.compactMap { $0 as? URL }.contains { $0.lastPathComponent == name }
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        input: String? = nil,
        environment: [String: String] = [:]
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

private struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var combined: String { stdout + stderr }
}

private actor FixtureEvidenceHandler: DiskStewardIPCRequestHandling {
    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        switch method {
        case "tools/call":
            return .object([
                "schema": .string("integration-fixture-summary"),
                "observed_at": .string("2026-09-13T00:00:00Z"),
                "limitations": .array([.string("Fixture evidence only.")]),
            ])
        case "sessions/register":
            return .object([
                "schema": .string("session-registration-result-v1"),
                "registration_id": .string("3f20eaaa-c6f7-4e25-8d3e-67c5ce70a773"),
                "session_id": payload.objectValue?["session_id"] ?? .null,
                "process_pid": .integer(Int64(peer.pid)),
                "confidence": .string("tool-linked"),
                "limitations": .array([.string("Registration does not prove individual file operations.")]),
            ])
        case "sessions/end":
            return .object([
                "schema": .string("session-end-result-v1"),
                "registration_id": payload.objectValue?["registration_id"] ?? .null,
                "lifecycle": .string("ended"),
            ])
        default:
            throw DiskStewardIPCError.remote(code: "unsupported", message: "unsupported fixture request", retryable: false)
        }
    }
}
