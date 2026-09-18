import DiskStewardCore
import Foundation
import XCTest

/// TASK-562: the session entry point talks to the canonical socket, binds a
/// registration to an explicit, alive, ancestor agent process (never to the
/// short-lived script or a wrapper shell), carries the lease on heartbeats,
/// and nothing infers a session from MCP initialize.
final class SessionContractTests: XCTestCase {
    func testRegisterRequiresAnExplicitLongLivedProcess() async throws {
        let root = temporaryRoot("ds-session-contract")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("private/evidence.sock")
        let handler = RecordingHandler()
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: handler)
        try server.start()
        defer { server.stop() }

        // No --process-pid: usage error, nothing registered.
        let missing = try run("/usr/bin/swift", [session.path, "register", "--client", "codex", "--session-id", "t", "--workspace", root.path, "--socket", socket.path])
        XCTAssertEqual(missing.status, 64, missing.combined)
        XCTAssertTrue(missing.stderr.contains("requires --process-pid"), missing.combined)

        // The script's own pid can never be named; a dead pid is refused.
        let dead = Process(); dead.executableURL = URL(fileURLWithPath: "/bin/sleep"); dead.arguments = ["0"]
        try dead.run(); dead.waitUntilExit()
        let deadResult = try run("/usr/bin/swift", [session.path, "register", "--client", "codex", "--session-id", "t", "--workspace", root.path, "--process-pid", String(dead.processIdentifier), "--socket", socket.path])
        XCTAssertEqual(deadResult.status, 65, deadResult.combined)
        XCTAssertTrue(deadResult.stderr.contains("is not running") || deadResult.stderr.contains("not an ancestor"), deadResult.combined)

        // A process that is not an ancestor of the command is refused before any IPC.
        let bystander = Process(); bystander.executableURL = URL(fileURLWithPath: "/bin/sleep"); bystander.arguments = ["30"]
        try bystander.run()
        defer { bystander.terminate() }
        let unrelated = try run("/usr/bin/swift", [session.path, "register", "--client", "codex", "--session-id", "t", "--workspace", root.path, "--process-pid", String(bystander.processIdentifier), "--socket", socket.path])
        XCTAssertEqual(unrelated.status, 65, unrelated.combined)
        XCTAssertTrue(unrelated.stderr.contains("not an ancestor"), unrelated.combined)
        let registrationsSoFar = await handler.recordedRegistrations()
        XCTAssertTrue(registrationsSoFar.isEmpty, "refusals happen before any request reaches the app")

        // The test process is the long-lived agent: registering through a
        // transient wrapper shell still names the agent, not the wrapper.
        let agentPID = ProcessInfo.processInfo.processIdentifier
        let wrapped = try run("/bin/zsh", ["-c", "/usr/bin/swift \(shellQuote(session.path)) register --client codex --session-id wrapped-task --workspace \(shellQuote(root.path)) --process-pid \(agentPID) --lease-seconds 600 --socket \(shellQuote(socket.path))"])
        XCTAssertEqual(wrapped.status, 0, wrapped.combined)
        let registrations = await handler.recordedRegistrations()
        XCTAssertEqual(registrations.count, 1)
        XCTAssertEqual(registrations.first?["process_pid"], String(agentPID))
        XCTAssertEqual(registrations.first?["session_id"], "wrapped-task")
        XCTAssertNotEqual(registrations.first?["process_pid"], registrations.first?["peer_pid"], "the registering peer (the script) is not what gets registered")

        // Heartbeats carry the lease explicitly; end closes the registration.
        let heartbeat = try run("/usr/bin/swift", [session.path, "heartbeat", "--registration-id", "3f20eaaa-c6f7-4e25-8d3e-67c5ce70a773", "--lease-seconds", "900", "--socket", socket.path])
        XCTAssertEqual(heartbeat.status, 0, heartbeat.combined)
        let heartbeats = await handler.recordedHeartbeats()
        XCTAssertEqual(heartbeats.first?["lease_seconds"], "900")
        let ended = try run("/usr/bin/swift", [session.path, "end", "--registration-id", "3f20eaaa-c6f7-4e25-8d3e-67c5ce70a773", "--socket", socket.path])
        XCTAssertEqual(ended.status, 0, ended.combined)
        XCTAssertTrue(ended.stdout.contains("\"lifecycle\":\"ended\""))
    }

    func testDefaultSocketPathsAreCanonicalAcrossEntryPoints() throws {
        let sessionDefault = try run("/usr/bin/swift", [session.path, "register", "--client", "codex", "--session-id", "t", "--workspace", "/tmp", "--process-pid", String(ProcessInfo.processInfo.processIdentifier), "--dry-run"])
        XCTAssertEqual(sessionDefault.status, 0, sessionDefault.combined)
        let doctorSource = try String(contentsOf: doctor, encoding: .utf8)
        XCTAssertTrue(doctorSource.contains("Library/Application Support/Disk Steward/disk-steward.sock"), "doctor must default to the app's socket path")
        XCTAssertFalse(doctorSource.contains("Support/DiskSteward/"), "the old misspelt default is gone")
        let sessionSource = try String(contentsOf: session, encoding: .utf8)
        XCTAssertTrue(sessionSource.contains("Library/Application Support/Disk Steward/disk-steward.sock"))
        XCTAssertEqual(UnixSocketDiskStewardIPCClient.defaultSocketPath(), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Disk Steward/disk-steward.sock").path)
    }

    func testHelperSelfCheckReportsItsIdentityAndNeverRegistersASession() async throws {
        let root = temporaryRoot("ds-selfcheck")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("private/evidence.sock")
        let handler = RecordingHandler()
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: handler)
        try server.start()
        defer { server.stop() }
        let connector = try connectorURL()
        let check = try run(connector.path, ["--self-check"], environment: ["DISK_STEWARD_SOCKET_PATH": socket.path])
        XCTAssertEqual(check.status, 0, check.combined)
        let reportLine = try XCTUnwrap(check.stdout.split(separator: "\n").last { $0.contains("disk-steward-self-check-v1") })
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reportLine.utf8)) as? [String: Any])
        XCTAssertEqual(report["app"] as? String, "connected")
        XCTAssertEqual(report["socket"] as? String, socket.path)
        let helper = try XCTUnwrap(report["helper"] as? [String: Any])
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(helper["path"] as? String)).resolvingSymlinksInPath(), connector.resolvingSymlinksInPath())
        XCTAssertNotNil(helper["identity"] as? String)
        let evidence = try XCTUnwrap(report["evidence"] as? [String: Any])
        XCTAssertEqual(evidence["observedAt"] as? String, "2026-09-13T00:00:00Z")
        XCTAssertGreaterThan(evidence["ageSeconds"] as? Double ?? -1, 3_600, "the fixture's evidence is days old and must be reported as such")
        let registered = await handler.recordedRegistrations()
        XCTAssertTrue(registered.isEmpty, "initialize and the self-check never register a session")
        let methods = await handler.recordedMethods()
        XCTAssertEqual(methods.filter { $0.hasPrefix("sessions/") }.count, 0)

        // An app that has persisted nothing yet says so instead of claiming fresh evidence.
        await handler.setPersistedStateAsOf(.null)
        let empty = try run(connector.path, ["--self-check"], environment: ["DISK_STEWARD_SOCKET_PATH": socket.path])
        XCTAssertEqual(empty.status, 0, empty.combined)
        let emptyLine = try XCTUnwrap(empty.stdout.split(separator: "\n").last { $0.contains("disk-steward-self-check-v1") })
        let emptyReport = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(emptyLine.utf8)) as? [String: Any])
        XCTAssertEqual(emptyReport["app"] as? String, "connected", empty.combined)
        let emptyEvidence = try XCTUnwrap(emptyReport["evidence"] as? [String: Any])
        XCTAssertEqual(emptyEvidence["persisted"] as? Bool, false, "\(emptyEvidence)")
        XCTAssertNil(emptyEvidence["ageSeconds"] as? Double, "\(emptyEvidence)")

        // Access off and app off are distinguished by the report, not guessed.
        server.stop()
        let offline = try run(connector.path, ["--self-check"], environment: ["DISK_STEWARD_SOCKET_PATH": socket.path])
        XCTAssertNotEqual(offline.status, 0)
        let offlineLine = try XCTUnwrap(offline.stdout.split(separator: "\n").last { $0.contains("disk-steward-self-check-v1") })
        let offlineReport = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(offlineLine.utf8)) as? [String: Any])
        XCTAssertEqual(offlineReport["app"] as? String, "app-off", offline.combined)
        let stateURL = root.appendingPathComponent("agent-access.json")
        try AgentAccessStateFile(url: stateURL).write(enabled: false)
        let accessOff = try run(connector.path, ["--self-check"], environment: ["DISK_STEWARD_SOCKET_PATH": socket.path, "DISK_STEWARD_AGENT_ACCESS_STATE_PATH": stateURL.path])
        let accessLine = try XCTUnwrap(accessOff.stdout.split(separator: "\n").last { $0.contains("disk-steward-self-check-v1") })
        let accessReport = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(accessLine.utf8)) as? [String: Any])
        XCTAssertEqual(accessReport["app"] as? String, "access-off", accessOff.combined)
    }

    // MARK: - helpers

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var session: URL { repositoryRoot.appendingPathComponent("Scripts/Integration/session") }
    private var doctor: URL { repositoryRoot.appendingPathComponent("Scripts/Integration/doctor") }

    private func connectorURL() throws -> URL {
        let candidates = [repositoryRoot.appendingPathComponent(".build/debug/disk-witness-mcp"), repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/disk-witness-mcp")]
        return try XCTUnwrap(candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }), "Build disk-witness-mcp before running integration tests")
    }

    private func temporaryRoot(_ prefix: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(prefix)-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
    }

    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws -> ScriptOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptOutput(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
    }
}

private struct ScriptOutput {
    let status: Int32
    let stdout: String
    let stderr: String
    var combined: String { stdout + stderr }
}

private actor RecordingHandler: DiskStewardIPCRequestHandling {
    private var registrations: [[String: String]] = []
    private var heartbeats: [[String: String]] = []
    private var methods: [String] = []
    private var persistedStateAsOf: JSONValue = .string("2026-09-13T00:00:00Z")

    func setPersistedStateAsOf(_ value: JSONValue) { persistedStateAsOf = value }

    func recordedRegistrations() -> [[String: String]] { registrations }
    func recordedHeartbeats() -> [[String: String]] { heartbeats }
    func recordedMethods() -> [String] { methods }

    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        methods.append(method)
        switch method {
        case "tools/call":
            // The exact shape AppEvidenceQueryBackend.storageSummary() publishes:
            // freshness lives under persistedStateAsOf, not under the sampling time.
            return .object(["schema": .string(StorageSummaryContract.schema),
                            StorageSummaryContract.liveVolumeObservedAt: .string("2026-09-18T00:00:00Z"),
                            StorageSummaryContract.persistedStateAsOf: persistedStateAsOf,
                            "volumes": .array([]), "limitations": .array([.string("Fixture evidence only.")])])
        case "sessions/register":
            var record = plain(payload); record["peer_pid"] = String(peer.pid)
            registrations.append(record)
            return .object(["schema": .string("session-registration-result-v1"), "registration_id": .string("3f20eaaa-c6f7-4e25-8d3e-67c5ce70a773"),
                            "session_id": payload.objectValue?["session_id"] ?? .null, "process_pid": payload.objectValue?["process_pid"] ?? .null,
                            "confidence": .string("tool-linked"), "limitations": .array([])])
        case "sessions/heartbeat":
            heartbeats.append(plain(payload))
            return .object(["schema": .string("session-heartbeat-result-v1"), "registration_id": payload.objectValue?["registration_id"] ?? .null, "lifecycle": .string("active")])
        case "sessions/end":
            return .object(["schema": .string("session-end-result-v1"), "registration_id": payload.objectValue?["registration_id"] ?? .null, "lifecycle": .string("ended")])
        default:
            throw DiskStewardIPCError.remote(code: "unsupported", message: "unsupported fixture request", retryable: false)
        }
    }

    private func plain(_ value: JSONValue) -> [String: String] {
        guard let object = value.objectValue else { return [:] }
        var result: [String: String] = [:]
        for (key, item) in object {
            switch item {
            case let .string(text): result[key] = text
            case let .integer(number): result[key] = String(number)
            case let .array(items): result[key] = items.compactMap { if case let .string(s) = $0 { return s } else { return nil } }.joined(separator: ",")
            default: continue
            }
        }
        return result
    }
}
