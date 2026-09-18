import AppKit
import CryptoKit
import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

@MainActor
final class FinalProductIncrementTests: XCTestCase {
    func testReleaseSmokeGateRejectsMissingOrUnsafeIsolationFields() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let verifier = try String(contentsOf: repository.appending(path: "Scripts/Distribution/verify-release"), encoding: .utf8)
        let start = try XCTUnwrap(verifier.range(of: "smoke_field()"))
        let end = try XCTUnwrap(verifier.range(of: "print \"Release verification passed:", range: start.upperBound..<verifier.endIndex))
        let gate = String(verifier[start.lowerBound..<end.lowerBound])
        let valid: [String: Any] = [
            "status": "launched", "activation_policy": "accessory", "isolated_smoke": true,
            "detail_sampling_paused": true, "watched_root_count": 0, "agent_access": "off",
            "settings_persistence": "ephemeral", "notifications_enabled": false,
        ]
        func check(_ report: [String: Any]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", gate]
            process.environment = ["smoke_output": String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self)]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try check(valid), 0)
        for key in valid.keys {
            var missing = valid
            missing.removeValue(forKey: key)
            XCTAssertEqual(try check(missing), 70, "Missing \(key) must reject the release")
        }
        for (key, badValue) in ["isolated_smoke": false, "detail_sampling_paused": false, "watched_root_count": 1, "agent_access": "on", "settings_persistence": "user-defaults", "notifications_enabled": true] as [String: Any] {
            var unsafe = valid
            unsafe[key] = badValue
            XCTAssertEqual(try check(unsafe), 70, "Unsafe \(key) must reject the release")
        }
    }

    func testSmokeStartupPreservesLiveFixtureEndpointAndAllSentinelState() throws {
        let fixture = try FinalFixture()
        let sentinels = ["evidence.sqlite", "monitoring-settings-v1", "monitoring-safety-v1", "agent-access.json", "exports/retained.json", "codex/config.toml", "claude/config.json", "cursor/mcp.json"]
            .map { fixture.directory.appending(path: $0) }
        for (index, file) in sentinels.enumerated() {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("untouched-sentinel-\(index)".utf8).write(to: file)
        }
        let leaseURL = fixture.directory.appending(path: "application.lock")
        let owner = try LocalServiceLease(url: leaseURL)
        let server = UnixSocketEvidenceServer(socketPath: fixture.socket.path, handler: SmokeSentinelHandler())
        try server.start()
        defer { server.stop(); withExtendedLifetime(owner) {} }
        let identities = try (sentinels + [fixture.socket, leaseURL]).map {
            try FileManager.default.attributesOfItem(atPath: $0.path)[.systemFileNumber] as? NSNumber
        }
        let contents = try sentinels.map { try Data(contentsOf: $0) }
        let client = UnixSocketDiskStewardIPCClient(socketPath: fixture.socket.path)
        let before = try client.send(method: "sentinel", payload: .object([:]), isCancelled: { false })
        let override = [
            "DISK_STEWARD_SUPPORT_DIRECTORY": fixture.directory.path,
            "DISK_STEWARD_SOCKET_PATH": fixture.socket.path,
            "DISK_STEWARD_CAPTURE_DIR": fixture.directory.path,
            "DISK_STEWARD_GATE_EVIDENCE": fixture.directory.path,
        ]
        for _ in 0..<2 {
            let launch = try runProduct(executable: "DiskStewardApp", arguments: ["--ui-smoke"], environment: override)
            XCTAssertEqual(launch.status, 0, launch.stderr)
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(launch.stdout.utf8)) as? [String: Any])
            XCTAssertEqual(report["isolated_smoke"] as? Bool, true)
            XCTAssertEqual(report["settings_persistence"] as? String, "ephemeral")
            XCTAssertEqual(report["notifications_enabled"] as? Bool, false)
            XCTAssertEqual(report["detail_sampling_paused"] as? Bool, true)
            XCTAssertEqual(report["watched_root_count"] as? Int, 0)
            XCTAssertEqual(report["agent_access"] as? String, "off")
            let scratch = try XCTUnwrap(report["support_directory"] as? String)
            XCTAssertNotEqual(scratch, fixture.directory.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch), "Smoke scratch must be removed after shutdown")
        }
        // Non-smoke support overrides must fail before opening a database,
        // initializing defaults or interacting with the existing application.
        let rejected = try runProduct(executable: "DiskStewardApp", environment: override)
        XCTAssertNotEqual(rejected.status, 0)
        XCTAssertTrue(rejected.stderr.contains("not an isolated launch"))
        XCTAssertEqual(try sentinels.map { try Data(contentsOf: $0) }, contents)
        XCTAssertEqual(try (sentinels + [fixture.socket, leaseURL]).map {
            try FileManager.default.attributesOfItem(atPath: $0.path)[.systemFileNumber] as? NSNumber
        }, identities)
        XCTAssertThrowsError(try LocalServiceLease(url: leaseURL))
        XCTAssertEqual(try client.send(method: "sentinel", payload: .object([:]), isCancelled: { false }), before)
    }

    func testCompleteProductJourneyPreservesEvidenceAndHonestFallback() async throws {
        let fixture = try FinalFixture()
        let launch = try runProduct(executable: "DiskStewardApp", arguments: ["--ui-smoke"])
        XCTAssertEqual(launch.status, 0, launch.stderr)
        let launchReport = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(launch.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(launchReport["status"] as? String, "launched")
        XCTAssertEqual(launchReport["activation_policy"] as? String, "accessory")
        XCTAssertEqual(launchReport["isolated_smoke"] as? Bool, true)
        XCTAssertEqual(launchReport["detail_sampling_paused"] as? Bool, true)
        XCTAssertEqual(launchReport["watched_root_count"] as? Int, 0)
        XCTAssertEqual(launchReport["agent_access"] as? String, "off")
        XCTAssertEqual(launchReport["settings_persistence"] as? String, "ephemeral")
        XCTAssertEqual(launchReport["notifications_enabled"] as? Bool, false)

        let live = try VolumeSnapshotService().capture()
        XCTAssertFalse(live.volumes.isEmpty)
        let board = StatusBoardViewModel(snapshotLoader: { live }, exportParent: { fixture.snapshotExports })
        board.refresh()
        XCTAssertNotNil(board.primaryVolume)
        XCTAssertNotNil(board.exportCurrentSnapshot())
        XCTAssertEqual(StatusItemSurface.route(for: .leftMouseUp), .statusBoard)
        XCTAssertEqual(StatusItemSurface.route(for: .rightMouseUp), .utilityMenu)

        let persistence = EphemeralSettingsPersistence()
        let settings = MonitoringSettingsStore(persistence: persistence, key: "gate-490")
        settings.update {
            $0.watchedRoots = [fixture.watched.path]
            $0.excludedRoots = [fixture.excluded.path]
            $0.maxDatabaseMiB = 10
            $0.rawEventDays = 7
        }
        let restored = MonitoringSettingsStore(persistence: persistence, key: "gate-490")
        XCTAssertEqual(restored.settings.watchedRoots, [fixture.watched.path])
        XCTAssertEqual(restored.settings.excludedRoots, [fixture.excluded.path])
        XCTAssertEqual(try restored.settings.retentionPolicy().maxDatabaseBytes, 10 * 1_024 * 1_024)

        let policy = restored.settings.monitoringPolicy(at: fixture.instant)
        let scanner = DirectoryMetadataScanner()
        let before = scanner.scan(policy: policy, at: fixture.instant)
        let artifact = fixture.watched.appendingPathComponent("agent-artifact.bin")
        try Data(repeating: 7, count: 16_384).write(to: artifact)
        try Data(repeating: 9, count: 32).write(to: fixture.excluded.appendingPathComponent("secret.txt"))
        let after = scanner.scan(policy: policy, at: fixture.instant)
        let changes = scanner.changes(from: before, to: after)
        let observed = try XCTUnwrap(changes.first { $0.path == artifact.path })
        XCTAssertFalse(changes.contains { $0.path.contains("/excluded/") })
        XCTAssertEqual(observed.confidence, .inferred)

        let writer = ProcessIdentity(pid: 490, startTime: fixture.instant.addingTimeInterval(-10), executablePath: "/usr/bin/codex")
        let registration = AgentSessionRegistration(
            registrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000490")!,
            client: .codex,
            sessionID: "gate-490-task",
            process: writer,
            workspaceRoots: [fixture.watched.path],
            registeredAt: fixture.instant.addingTimeInterval(-20),
            expiresAt: fixture.instant.addingTimeInterval(20),
            endedAt: nil,
            lifecycle: .active,
            authentication: .init(challengeDigest: String(repeating: "4", count: 64))
        )
        let privilegedRaw = RawPrivilegedNotification(
            eventID: "gate-490-endpoint",
            streamID: "fixture",
            sequence: 1,
            observedAt: fixture.instant,
            operation: .create,
            path: artifact.path,
            process: writer,
            fileIdentity: .init(volumeID: "fixture-data", fileID: 490, generation: 1),
            size: .init(
                logicalBefore: 0,
                logicalAfter: observed.logicalDelta,
                allocatedBefore: 0,
                allocatedAfter: observed.allocatedDelta,
                method: "fstat"
            )
        )
        let privileged = try XCTUnwrap(
            EndpointEventNormalizer().normalize(
                privilegedRaw,
                scope: .init(watchedRoots: [fixture.watched.path], excludedRoots: [fixture.excluded.path]),
                gapBefore: false
            )
        )
        let exact = ProvenanceEngine().attribute(
            .init(
                event: EvidenceStoreEvent(
                    eventID: observed.eventID,
                    observedAt: fixture.instant,
                    operation: .create,
                    path: observed.path,
                    logicalDelta: observed.logicalDelta,
                    allocatedDelta: observed.allocatedDelta,
                    consumerCategory: observed.consumerCategory,
                    confidence: .exact
                ),
                privilegedEvent: privileged,
                registrations: [registration],
                ancestry: .init(records: [.init(identity: writer, parent: nil)])
            )
        )
        XCTAssertEqual(exact.confidence, .exact)
        XCTAssertEqual(exact.session?.sessionID, "gate-490-task")
        XCTAssertEqual(Set(exact.support.map(\.kind)), [.endpointSecurity, .metadataSnapshot, .processAncestry, .agentSession])
        let adapter = ProvenancePresentationAdapter()
        XCTAssertEqual(adapter.record(for: exact, channel: .userInterface), adapter.record(for: exact, channel: .export))
        XCTAssertEqual(adapter.record(for: exact, channel: .export), adapter.record(for: exact, channel: .mcp))

        let fallback = PermissionOnboardingState(endpointSecurity: .denied, fullDiskAccess: .denied)
        XCTAssertTrue(fallback.metadataFallbackActive)
        XCTAssertFalse(fallback.exactProvenanceAvailable)
        let fallbackClaim = ProvenanceEngine().attribute(.init(event: observed, fseventGap: true, registrations: [registration]))
        XCTAssertEqual(fallbackClaim.confidence, .unknown)
        XCTAssertNil(fallbackClaim.actor)

        let secret = "gate-490-secret"
        let privacy = EvidencePrivacyFilter().filter(
            path: "/Users/\(secret)/work/agent-artifact.bin",
            command: "codex --token \(secret)",
            executable: "/Users/\(secret)/bin/codex",
            policy: .init(pathPolicy: .basename, excludedRoots: [fixture.excluded.path], sensitiveValues: [secret])
        )
        guard case let .included(filtered) = privacy else { return XCTFail("Expected included privacy fixture") }
        let filteredJSON = try JSONEncoder().encode(filtered)
        XCTAssertFalse(String(decoding: filteredJSON, as: UTF8.self).contains(secret))

        let store = try EvidenceStore(url: fixture.database)
        try await store.insert(observed)
        let exportInstant = fixture.instant
        let export = try await EvidenceBundleExporter(
            productVersion: "gate-490",
            identifierSource: { "gate-490-evidence" },
            dateSource: { exportInstant }
        ).export(
            store: store,
            options: .init(from: fixture.instant.addingTimeInterval(-60), through: fixture.instant.addingTimeInterval(60), pathDetail: .basename),
            to: fixture.evidenceExports
        )
        try inspect(bundle: export)
        let diagnostics = try await store.diagnostics()
        XCTAssertEqual(diagnostics.integrity, "ok")
        XCTAssertLessThanOrEqual(diagnostics.storageBytes, 10 * 1_024 * 1_024)
        await store.close()

        let backend = try AppEvidenceQueryBackend(databaseURL: fixture.database)
        let service = UnixSocketEvidenceServer(socketPath: fixture.socket.path, handler: backend)
        try service.start()
        let transcript = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"gate-490","version":"1"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
        {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_provenance","arguments":{"path_query":"agent-artifact","limit":10}}}

        """
        let mcp = try runProduct(executable: "disk-witness-mcp", input: transcript, environment: ["DISK_STEWARD_SOCKET_PATH": fixture.socket.path])
        XCTAssertEqual(mcp.status, 0, mcp.stderr)
        let responses = try responseMap(mcp.stdout)
        let tools = try XCTUnwrap((responses[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 10)
        XCTAssertFalse(tools.contains { ($0["name"] as? String)?.contains("delete") == true })
        let provenance = try structured(responses, id: 3)
        XCTAssertEqual(provenance["schema"] as? String, "evidence-query-page-v1")
        XCTAssertEqual((provenance["items"] as? [[String: Any]])?.count, 1)
        XCTAssertFalse(containsForbiddenKey(provenance, names: ["file_contents", "environment", "token", "secret", "password"]))

        let budget = ResourceBudget(maximumPendingEvents: 4_096, maximumLossRatio: 0.01)
        let healthy = ResourceBudgetEvaluator().assess(
            .init(cpuPercent: 4, residentBytes: 80 * 1_024 * 1_024, databaseBytes: diagnostics.storageBytes, pendingEvents: 100, receivedEvents: 10_000, droppedEvents: 0, underLoad: true),
            against: budget
        )
        XCTAssertTrue(healthy.withinBudget)
        service.stop()
        XCTAssertThrowsError(try UnixSocketDiskStewardIPCClient(socketPath: fixture.socket.path).send(method: "tools/call", payload: .object(["name": .string("get_storage_summary"), "arguments": .object([:])]), isCancelled: { false }))
    }

    private func inspect(bundle: EvidenceBundleExportResult) throws {
        XCTAssertFalse(bundle.manifest.privacy.containsFileContents)
        XCTAssertFalse(bundle.manifest.privacy.containsEnvironment)
        XCTAssertEqual(bundle.manifest.privacy.pathDetail, .basename)
        for file in bundle.manifest.files {
            let data = try Data(contentsOf: bundle.bundleURL.appendingPathComponent(file.path))
            XCTAssertEqual(data.count, file.bytes)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), file.sha256)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("gate-490-secret"))
        }
    }

    private func runProduct(executable: String, arguments: [String] = [], input: String? = nil, environment: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            repository.appendingPathComponent(".build/debug/\(executable)"),
            repository.appendingPathComponent(".build/arm64-apple-macosx/debug/\(executable)"),
        ]
        let process = Process()
        process.executableURL = try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func responseMap(_ transcript: String) throws -> [Int: [String: Any]] {
        var responses: [Int: [String: Any]] = [:]
        for line in transcript.split(separator: "\n") {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if let id = (object["id"] as? NSNumber)?.intValue { responses[id] = object }
        }
        return responses
    }

    private func structured(_ responses: [Int: [String: Any]], id: Int) throws -> [String: Any] {
        let result = try XCTUnwrap(responses[id]?["result"] as? [String: Any])
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }

    private func containsForbiddenKey(_ value: Any, names: Set<String>) -> Bool {
        if let object = value as? [AnyHashable: Any] {
            return object.contains { key, child in
                (key as? String).map { names.contains($0.lowercased()) } == true || containsForbiddenKey(child, names: names)
            }
        }
        if let array = value as? [Any] { return array.contains { containsForbiddenKey($0, names: names) } }
        return false
    }
}

private actor SmokeSentinelHandler: DiskStewardIPCRequestHandling {
    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        .object(["sentinel": .string("still-live")])
    }
}

private final class FinalFixture {
    let directory: URL
    let watched: URL
    let excluded: URL
    let database: URL
    let socket: URL
    let snapshotExports: URL
    let evidenceExports: URL
    let instant: Date

    init() throws {
        instant = Date()
        directory = URL(fileURLWithPath: "/tmp/ds-g490-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        watched = directory.appendingPathComponent("watched", isDirectory: true)
        excluded = watched.appendingPathComponent("excluded", isDirectory: true)
        database = directory.appendingPathComponent("evidence/evidence.sqlite")
        socket = directory.appendingPathComponent("ipc/evidence.sock")
        snapshotExports = directory.appendingPathComponent("snapshots", isDirectory: true)
        evidenceExports = directory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
