@testable import DiskStewardApp
import Foundation
import XCTest

@MainActor
final class AgentIntegrationsPresentationTests: XCTestCase {
    func testDetectedClientsAreSelectableAndAbsentClientsAreNotPreselected() async {
        let codex = descriptor(.codex)
        let claude = descriptor(.claudeCode)
        let environment = PresentationDetectionEnvironment(executables: ["codex": "/usr/local/bin/codex"])
        let adapter = PresentationAdapter(descriptor: codex, outcomes: [.setup: .changed])
        let manager = AgentIntegrationManager(
            descriptors: [codex, claude],
            detector: .init(environment: environment),
            adapters: [.codex: adapter],
            helperURL: URL(fileURLWithPath: "/Applications/Disk Steward.app/Contents/Helpers/disk-witness-mcp")
        )

        await manager.rescan()

        XCTAssertEqual(manager.snapshots[.codex]?.state, .available)
        XCTAssertEqual(manager.snapshots[.claudeCode]?.state, .notDetected)
        XCTAssertTrue(manager.selectedClients.isEmpty)
        let row = try! XCTUnwrap(manager.snapshots[.codex]).rowPresentation(selected: false)
        XCTAssertTrue(row.accessibilityLabel.contains("Codex"))
        XCTAssertTrue(row.accessibilityLabel.contains("available"))
    }

    func testMultiSelectReportsPartialResultsWithoutRollingBackSuccess() async {
        let codex = descriptor(.codex)
        let claude = descriptor(.claudeCode)
        let environment = PresentationDetectionEnvironment(executables: [
            "codex": "/usr/local/bin/codex",
            "claude": "/usr/local/bin/claude",
        ])
        let codexAdapter = PresentationAdapter(descriptor: codex, outcomes: [.setup: .changed])
        let claudeAdapter = PresentationAdapter(descriptor: claude, outcomes: [.setup: .failed])
        let manager = AgentIntegrationManager(
            descriptors: [codex, claude],
            detector: .init(environment: environment),
            adapters: [.codex: codexAdapter, .claudeCode: claudeAdapter],
            helperURL: URL(fileURLWithPath: "/tmp/disk-witness-mcp")
        )
        await manager.rescan()
        manager.setSelected(true, clientID: .codex)
        manager.setSelected(true, clientID: .claudeCode)

        await manager.setupSelected()

        XCTAssertEqual(manager.results[.codex]?.outcome, .changed)
        XCTAssertEqual(manager.results[.claudeCode]?.outcome, .failed)
        XCTAssertEqual(codexAdapter.actions, [.setup])
        XCTAssertEqual(claudeAdapter.actions, [.setup])
    }

    func testRepairAndRemoveAreForwardedToTheSelectedClientOnly() async {
        let codex = descriptor(.codex)
        let adapter = PresentationAdapter(descriptor: codex, outcomes: [.repair: .changed, .remove: .changed])
        let manager = AgentIntegrationManager(
            descriptors: [codex],
            detector: .init(environment: PresentationDetectionEnvironment(executables: ["codex": "/bin/codex"])),
            adapters: [.codex: adapter],
            helperURL: URL(fileURLWithPath: "/tmp/helper")
        )
        await manager.perform(.repair, clientID: .codex)
        await manager.perform(.remove, clientID: .codex)

        XCTAssertEqual(adapter.actions, [.repair, .remove])
    }

    func testSetupSelectionDoesNotMutateAgentAccessState() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-presentation-access-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let access = MCPAccessController(
            settingsStore: AgentAccessSettingsStore(stateFile: .init(url: root.appending(path: "access.json"))),
            serverFactory: { PresentationAccessServer() }
        )
        let codex = descriptor(.codex)
        let manager = AgentIntegrationManager(
            descriptors: [codex],
            detector: .init(environment: PresentationDetectionEnvironment(executables: ["codex": "/bin/codex"])),
            adapters: [.codex: PresentationAdapter(descriptor: codex, outcomes: [.setup: .changed])],
            helperURL: URL(fileURLWithPath: "/tmp/helper")
        )
        manager.setSelected(true, clientID: .codex)

        await manager.setupSelected()

        XCTAssertFalse(access.isEnabled)
        XCTAssertEqual(access.state.kind, .off)
    }

    private func descriptor(_ id: AgentClientID) -> AgentClientDescriptor {
        AgentClientDescriptor.supported.first { $0.id == id }!
    }
}

private extension AgentIntegrationSnapshot {
    func rowPresentation(selected: Bool) -> AgentIntegrationRowPresentation {
        AgentIntegrationRowPresentation(snapshot: self, isSelected: selected)
    }
}

private struct PresentationDetectionEnvironment: AgentDetectionEnvironment {
    let executables: [String: String]
    func executableURL(named name: String) -> URL? { executables[name].map(URL.init(fileURLWithPath:)) }
    func applicationExists(at path: String) -> Bool { false }
}

@MainActor
private final class PresentationAdapter: AgentIntegrationAdapting {
    let descriptor: AgentClientDescriptor
    var actions: [AgentIntegrationAction] = []
    private let outcomes: [AgentIntegrationAction: AgentIntegrationOperationOutcome]

    init(descriptor: AgentClientDescriptor, outcomes: [AgentIntegrationAction: AgentIntegrationOperationOutcome]) {
        self.descriptor = descriptor
        self.outcomes = outcomes
    }

    func inspect() async -> AgentIntegrationSnapshot {
        .derive(descriptor: descriptor, presence: .detected(location: "/usr/local/bin/\(descriptor.id.rawValue)"), inspection: .missing)
    }

    func perform(_ action: AgentIntegrationAction) async -> AgentIntegrationOperationResult {
        actions.append(action)
        let outcome = outcomes[action] ?? .unchanged
        let inspection: AgentConfigurationInspection = outcome == .failed
            ? .malformed(reason: "fixture failure")
            : (action == .remove ? .missing : .owned(receipt: .init(clientID: descriptor.id, definition: .init(command: "/tmp/helper"))))
        let snapshot = AgentIntegrationSnapshot.derive(
            descriptor: descriptor,
            presence: .detected(location: "/usr/local/bin/\(descriptor.id.rawValue)"),
            inspection: inspection
        )
        return .init(clientID: descriptor.id, action: action, outcome: outcome, message: outcome == .failed ? "fixture failure" : "ok", snapshot: snapshot)
    }
}

private final class PresentationAccessServer: MCPAccessServing {
    func start() throws {}
    func stop() {}
}
