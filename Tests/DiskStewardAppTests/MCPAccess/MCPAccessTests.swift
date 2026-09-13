import Darwin
import DiskStewardCore
@testable import DiskStewardApp
import Foundation
import XCTest

@MainActor
final class MCPAccessTests: XCTestCase {
    func testFreshInstallDefaultsOffWithoutStartingAService() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateFile = AgentAccessStateFile(url: root.appending(path: "agent-access.json"))
        let settings = AgentAccessSettingsStore(stateFile: stateFile)
        var factoryCalls = 0

        let controller = MCPAccessController(settingsStore: settings) {
            factoryCalls += 1
            return RecordingService()
        }

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.url.path))
    }

    func testTogglePersistsAndOwnsServiceLifecycle() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateFile = AgentAccessStateFile(url: root.appending(path: "agent-access.json"))
        let service = RecordingService()
        let controller = MCPAccessController(
            settingsStore: AgentAccessSettingsStore(stateFile: stateFile),
            serverFactory: { service }
        )

        controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(service.startCount, 1)
        XCTAssertTrue(try stateFile.readEnabled())
        XCTAssertTrue(AgentAccessSettingsStore(stateFile: stateFile).isEnabled)

        controller.setEnabled(false)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(service.stopCount, 1)
        XCTAssertFalse(try stateFile.readEnabled())
    }

    func testRealPrivateSocketIsQueryableOnlyWhileEnabled() throws {
        let root = temporaryRoot()
        let socket = root.appending(path: "private/service.sock")
        let stateURL = root.appending(path: "agent-access.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = MCPAccessController(
            settingsStore: AgentAccessSettingsStore(stateFile: AgentAccessStateFile(url: stateURL)),
            serverFactory: { UnixSocketEvidenceServer(socketPath: socket.path, handler: EchoHandler()) }
        )
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket.path, accessStateURL: stateURL)

        controller.setEnabled(true)
        XCTAssertEqual(controller.state.kind, .on)
        XCTAssertEqual(
            try client.call(tool: "get_storage_summary", arguments: [:], isCancelled: { false }),
            .object(["method": .string("tools/call")])
        )
        var metadata = stat()
        XCTAssertEqual(lstat(socket.path, &metadata), 0)
        XCTAssertEqual(metadata.st_uid, getuid())
        XCTAssertEqual(metadata.st_mode & 0o077, 0)

        controller.setEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertThrowsError(
            try client.call(tool: "get_storage_summary", arguments: [:], isCancelled: { false })
        ) { error in
            XCTAssertEqual(error as? DiskStewardIPCError, .agentAccessDisabled)
        }
    }

    func testStartupFailureIsExplicitlyDegradedAndDoesNotPretendAccessIsOn() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = MCPAccessController(
            settingsStore: AgentAccessSettingsStore(
                stateFile: AgentAccessStateFile(url: root.appending(path: "agent-access.json"))
            ),
            serverFactory: { throw StubError.cannotStart }
        )

        controller.setEnabled(true)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.state.kind, .degraded)
        XCTAssertTrue(controller.state.title.contains("Attention"))
        XCTAssertTrue(controller.state.detail.contains("cannot start"))
        XCTAssertTrue(controller.state.accessibilitySummary.contains("unavailable"))
    }

    func testToggleLeavesEvidenceMonitoringAndExternalAgentConfigurationUntouched() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let evidence = root.appending(path: "evidence.sqlite")
        let monitoring = root.appending(path: "monitoring-settings.json")
        let codex = root.appending(path: "codex-config.toml")
        let claude = root.appending(path: "claude-config.json")
        let sentinels: [(URL, Data)] = [
            (evidence, Data("evidence-sentinel".utf8)),
            (monitoring, Data("monitoring-sentinel".utf8)),
            (codex, Data("codex-sentinel".utf8)),
            (claude, Data("claude-sentinel".utf8)),
        ]
        for (url, data) in sentinels { try data.write(to: url) }
        let controller = MCPAccessController(
            settingsStore: AgentAccessSettingsStore(
                stateFile: AgentAccessStateFile(url: root.appending(path: "agent-access.json"))
            ),
            serverFactory: { RecordingService() }
        )

        controller.setEnabled(true)
        controller.setEnabled(false)

        for (url, expected) in sentinels {
            XCTAssertEqual(try Data(contentsOf: url), expected, "toggle unexpectedly changed \(url.lastPathComponent)")
        }
    }

    func testEveryStateHasHumanReadableTextIndependentOfColor() {
        let states: [MCPAccessState] = [.off, .starting, .on, .degraded("test failure")]
        XCTAssertEqual(Set(states.map(\.kind)).count, 4)
        for state in states {
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.detail.isEmpty)
            XCTAssertTrue(state.accessibilitySummary.contains(state.title))
        }
    }

    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: "/tmp/ds-access-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
    }
}

private final class RecordingService: MCPAccessServing {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws { startCount += 1 }
    func stop() { stopCount += 1 }
}

private struct EchoHandler: DiskStewardIPCRequestHandling {
    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        .object(["method": .string(method)])
    }
}

private enum StubError: LocalizedError {
    case cannotStart

    var errorDescription: String? { "cannot start private service" }
}
