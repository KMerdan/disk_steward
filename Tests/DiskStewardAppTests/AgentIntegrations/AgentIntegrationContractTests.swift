@testable import DiskStewardApp
import Foundation
import XCTest

final class AgentIntegrationContractTests: XCTestCase {
    func testStateDerivationKeepsPresenceConfigurationApprovalAndVerificationDistinct() {
        let descriptor = descriptor(.codex)
        let receipt = receipt(.codex)
        let cases: [(AgentClientPresence, AgentConfigurationInspection, AgentVerification, AgentIntegrationStateKind)] = [
            (.notDetected, .missing, .notRun, .notDetected),
            (.detected(location: "/opt/homebrew/bin/codex"), .missing, .notRun, .available),
            (.detected(location: nil), .owned(receipt: receipt), .notRun, .configured),
            (.detected(location: nil), .approvalPending(receipt: receipt), .notRun, .approvalPending),
            (.detected(location: nil), .owned(receipt: receipt), .passed(at: Date(timeIntervalSince1970: 1)), .verified),
            (.detected(location: nil), .owned(receipt: receipt), .failed(reason: "helper moved"), .broken),
            (.detected(location: nil), .external(definition: .init(command: "/tmp/other")), .notRun, .conflict),
            (.unavailable(reason: "configuration unreadable"), .missing, .notRun, .unavailable),
        ]

        XCTAssertEqual(cases.map { presence, inspection, verification, _ in
            AgentIntegrationSnapshot.derive(
                descriptor: descriptor,
                presence: presence,
                inspection: inspection,
                verification: verification
            ).state
        }, cases.map(\.3))
    }

    func testOwnershipNeverTreatsAnUnreceiptedOrChangedDefinitionAsOwned() {
        let expected = AgentIntegrationDefinition(command: "/Applications/Disk Steward.app/Contents/Helpers/disk-witness-mcp")
        let installed = AgentIntegrationReceipt(clientID: .codex, definition: expected)
        let changed = AgentIntegrationDefinition(command: "/tmp/replaced-helper")

        XCTAssertEqual(AgentIntegrationOwnership.resolve(current: nil, receipt: installed), .missing)
        XCTAssertEqual(AgentIntegrationOwnership.resolve(current: expected, receipt: nil), .external(expected))
        XCTAssertEqual(AgentIntegrationOwnership.resolve(current: expected, receipt: installed), .owned(installed))
        XCTAssertEqual(
            AgentIntegrationOwnership.resolve(current: changed, receipt: installed),
            .conflict(expected: expected, actual: changed)
        )
    }

    @MainActor
    func testReceiptStoreIsIdempotentAndPersistsOnlyOneReceiptPerClient() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentIntegrationReceiptStore(url: root.appending(path: "receipts.json"))
        var first = receipt(.codex)
        try store.upsert(first)
        first.lastResult = "verified"
        first.lastVerifiedAt = Date(timeIntervalSince1970: 10)
        try store.upsert(first)
        try store.upsert(receipt(.claudeCode))

        XCTAssertEqual(try store.allReceipts().count, 2)
        XCTAssertEqual(try store.receipt(for: .codex)?.lastResult, "verified")
        try store.remove(clientID: .codex)
        try store.remove(clientID: .codex)
        XCTAssertNil(try store.receipt(for: .codex))
        XCTAssertNotNil(try store.receipt(for: .claudeCode))

        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testDetectionChecksOnlyDeclaredExecutableAndApplicationCandidates() {
        let environment = DetectionFixture(
            executables: ["codex": URL(fileURLWithPath: "/fixture/bin/codex")],
            applications: ["/Applications/Claude.app"]
        )
        let detector = KnownAgentClientDetector(environment: environment)

        XCTAssertEqual(detector.detect(descriptor(.codex)), .detected(location: "/fixture/bin/codex"))
        XCTAssertEqual(detector.detect(descriptor(.claudeDesktop)), .detected(location: "/Applications/Claude.app"))
        XCTAssertEqual(detector.detect(descriptor(.cursor)), .notDetected)
        XCTAssertEqual(Set(environment.requestedExecutableNames), Set(descriptor(.codex).executableNames + descriptor(.claudeDesktop).executableNames + descriptor(.cursor).executableNames))
        XCTAssertFalse(environment.requestedApplicationPaths.contains("/"))
    }

    func testProcessFailureMappingPreservesExitCodeAndActionableOutput() {
        let command = AgentCommand(executableURL: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        let result = AgentCommandResult(exitCode: 7, standardOutput: "", standardError: "client rejected duplicate name")

        XCTAssertThrowsError(try result.requireSuccess(command: command)) { error in
            XCTAssertEqual(
                error as? AgentIntegrationCommandError,
                .exited(executable: "/usr/bin/false", code: 7, message: "client rejected duplicate name")
            )
            XCTAssertTrue(error.localizedDescription.contains("duplicate name"))
        }
    }

    func testSelectionEligibilityIsExplicit() {
        let descriptor = descriptor(.codex)
        let available = AgentIntegrationSnapshot.derive(descriptor: descriptor, presence: .detected(location: nil), inspection: .missing)
        let conflict = AgentIntegrationSnapshot.derive(
            descriptor: descriptor,
            presence: .detected(location: nil),
            inspection: .external(definition: .init(command: "/tmp/other"))
        )
        XCTAssertTrue(available.canSelectForSetup)
        XCTAssertFalse(conflict.canSelectForSetup)
    }

    private func descriptor(_ id: AgentClientID) -> AgentClientDescriptor {
        AgentClientDescriptor.supported.first { $0.id == id }!
    }

    private func receipt(_ id: AgentClientID) -> AgentIntegrationReceipt {
        AgentIntegrationReceipt(
            clientID: id,
            definition: .init(command: "/Applications/Disk Steward.app/Contents/Helpers/disk-witness-mcp"),
            installedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: "/tmp/ds-agent-contract-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class DetectionFixture: AgentDetectionEnvironment, @unchecked Sendable {
    let executables: [String: URL]
    let applications: Set<String>
    private(set) var requestedExecutableNames: [String] = []
    private(set) var requestedApplicationPaths: [String] = []

    init(executables: [String: URL], applications: Set<String>) {
        self.executables = executables
        self.applications = applications
    }

    func executableURL(named name: String) -> URL? {
        requestedExecutableNames.append(name)
        return executables[name]
    }

    func applicationExists(at path: String) -> Bool {
        requestedApplicationPaths.append(path)
        return applications.contains(path)
    }
}
