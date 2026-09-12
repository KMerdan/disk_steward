import Foundation
import XCTest
@testable import DiskStewardApp
@testable import DiskStewardCore

final class SafetyTests: XCTestCase {
    func testSensitiveValuesNeverAppearInFilteredMetadata() throws {
        let filter = EvidencePrivacyFilter()
        for index in 0 ..< 500 {
            let secret = "token-\(index)-\(UUID().uuidString)"
            let policy = EvidencePrivacyPolicy(pathPolicy: .full, sensitiveValues: [secret])
            let result = filter.filter(
                path: "/Users/example/\(secret)/artifact.json",
                command: "tool --secret \(secret)",
                executable: "/opt/\(secret)/tool",
                policy: policy
            )
            guard case let .included(metadata) = result else { return XCTFail("Unexpected exclusion") }
            let encoded = try JSONEncoder().encode(metadata)
            let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            XCTAssertFalse(text.contains(secret))
            XCTAssertEqual(metadata.redactionsApplied, 3)
        }
    }

    func testExcludedRootsAndPathDetailAreDeterministic() {
        let filter = EvidencePrivacyFilter()
        let excluded = EvidencePrivacyPolicy(excludedRoots: ["/Users/example/private"])
        XCTAssertEqual(
            filter.filter(path: "/Users/example/private/note.txt", command: nil, executable: nil, policy: excluded),
            .excluded(reason: "Path is inside a user-configured excluded root.")
        )

        let basename = filter.filter(
            path: "/Users/example/work/report.pdf",
            command: nil,
            executable: nil,
            policy: .init(pathPolicy: .basename)
        )
        guard case let .included(metadata) = basename else { return XCTFail("Expected included metadata") }
        XCTAssertEqual(metadata.path, "report.pdf")

        let hashed = filter.filter(
            path: "/Users/example/work/report.pdf",
            command: nil,
            executable: nil,
            policy: .init(pathPolicy: .hashed)
        )
        guard case let .included(first) = hashed,
              case let .included(second) = filter.filter(path: "/Users/example/work/report.pdf", command: nil, executable: nil, policy: .init(pathPolicy: .hashed))
        else { return XCTFail("Expected hashed metadata") }
        XCTAssertEqual(first.path, second.path)
        XCTAssertTrue(first.path.hasPrefix("sha256:"))
        XCTAssertFalse(first.path.contains("report.pdf"))
    }

    func testPermissionRefusalKeepsFallbackVisibleAndAvailable() {
        for state in [PermissionGrantState.denied, .unavailable, .pendingUserApproval, .notRequested] {
            let onboarding = PermissionOnboardingState(endpointSecurity: state, fullDiskAccess: state)
            XCTAssertTrue(onboarding.metadataFallbackActive)
            XCTAssertFalse(onboarding.exactProvenanceAvailable)
            XCTAssertEqual(onboarding.headline, "Standard monitoring is active")
            XCTAssertTrue(onboarding.detail.contains("continue"))
        }
    }

    func testUninstallPreservesEvidenceUnlessUserExplicitlyChoosesExportThenDelete() {
        let normal = SafeUninstallPlan()
        XCTAssertEqual(normal.evidenceAction, .preserve)
        XCTAssertFalse(normal.requiresExplicitEvidenceConfirmation)
        XCTAssertTrue(normal.removeIntegrationEntries)

        let destructive = SafeUninstallPlan(evidenceAction: .exportThenDelete)
        XCTAssertTrue(destructive.requiresExplicitEvidenceConfirmation)
    }

    func testBudgetEvaluatorMakesOverloadAndLossVisible() {
        let budget = ResourceBudget(maximumPendingEvents: 100, maximumLossRatio: 0.01)
        let assessment = ResourceBudgetEvaluator().assess(
            .init(cpuPercent: 18, residentBytes: 200 * 1_024 * 1_024, databaseBytes: 600 * 1_024 * 1_024, pendingEvents: 101, receivedEvents: 900, droppedEvents: 100, underLoad: true),
            against: budget
        )
        XCTAssertFalse(assessment.withinBudget)
        XCTAssertTrue(assessment.backpressureRequired)
        XCTAssertEqual(assessment.lossRatio, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(assessment.reasons.count, 5)
    }
}
