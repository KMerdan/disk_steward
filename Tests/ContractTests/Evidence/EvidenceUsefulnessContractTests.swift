import Foundation
import XCTest

final class EvidenceUsefulnessContractTests: XCTestCase {
    private let validator = JSONSchemaContractValidator()

    private let requiredRoles: Set<String> = [
        "codex-brief", "summary", "events", "snapshot", "current-state",
        "provenance", "agent-sessions", "coverage", "lifecycle", "integrity",
    ]

    func testActionableExportFixtureIsClosedCompleteAndHonest() throws {
        let fixture = try loadFixture("actionable-export-valid")
        XCTAssertEqual(try schemaErrors(fixture, schema: "actionable-export-v1"), [])
        XCTAssertEqual(exportSemanticErrors(fixture), [])
    }

    func testCapacityOnlyBundleFailsRequiredRoleContract() throws {
        let fixture = try loadFixture("actionable-export-missing-roles")
        let schema = try schemaErrors(fixture, schema: "actionable-export-v1")
        XCTAssertTrue(schema.contains(where: { $0.contains("files") && $0.contains("fewer than 11") }))

        let semantic = exportSemanticErrors(fixture)
        XCTAssertTrue(semantic.contains(where: { $0.contains("missing required roles") }))
    }

    func testOpenCoverageGapCannotClaimCompleteOrNoMeasuredChange() throws {
        let fixture = try loadFixture("actionable-export-false-complete")
        let schema = try schemaErrors(fixture, schema: "actionable-export-v1")
        XCTAssertTrue(schema.contains(where: { $0.contains("limitations") && $0.contains("fewer than 1") }))

        let semantic = exportSemanticErrors(fixture)
        XCTAssertTrue(semantic.contains("open coverage gaps require partial, stale, or unavailable detail coverage"))
        XCTAssertTrue(semantic.contains("an active incomplete generation makes growth unavailable"))
        XCTAssertTrue(semantic.contains("open coverage gaps require at least one human-readable limitation"))
    }

    func testMultiSliceGenerationReconcilesOnlyAtCompletion() throws {
        let fixture = try loadFixture("scan-generation-multi-slice")
        XCTAssertEqual(try schemaErrors(fixture, schema: "scan-generation-scenario-v1"), [])
        XCTAssertEqual(scanSemanticErrors(fixture), [])

        let generation = try XCTUnwrap(generations(fixture).first)
        let slices = try XCTUnwrap(generation["slices"] as? [[String: Any]])
        XCTAssertEqual(slices.count, 3)
        XCTAssertEqual(slices.filter { $0["authoritative_reconciliation"] as? Bool == true }.count, 1)
        XCTAssertEqual(slices.last?["authoritative_reconciliation"] as? Bool, true)
    }

    func testRestartResumesSameGenerationAndFrontier() throws {
        let fixture = try loadFixture("scan-generation-restart")
        XCTAssertEqual(try schemaErrors(fixture, schema: "scan-generation-scenario-v1"), [])
        XCTAssertEqual(scanSemanticErrors(fixture), [])

        let generation = try XCTUnwrap(generations(fixture).first)
        let slices = try XCTUnwrap(generation["slices"] as? [[String: Any]])
        let restartIndex = try XCTUnwrap(slices.firstIndex { $0["restart_boundary"] as? Bool == true })
        XCTAssertGreaterThan(restartIndex, 0)
        XCTAssertEqual(slices[restartIndex]["cursor_before"] as? String, slices[restartIndex - 1]["cursor_after"] as? String)
    }

    func testScopeChangeAbandonsOldGenerationWithoutPromotingIt() throws {
        let fixture = try loadFixture("scan-generation-scope-change")
        XCTAssertEqual(try schemaErrors(fixture, schema: "scan-generation-scenario-v1"), [])
        XCTAssertEqual(scanSemanticErrors(fixture), [])

        let all = generations(fixture)
        let abandoned = try XCTUnwrap(all.first { $0["state"] as? String == "abandoned" })
        let abandonedSlices = try XCTUnwrap(abandoned["slices"] as? [[String: Any]])
        XCTAssertFalse(abandonedSlices.contains { $0["authoritative_reconciliation"] as? Bool == true })

        let expectations = try XCTUnwrap(fixture["expectations"] as? [String: Any])
        XCTAssertNotEqual(expectations["current_state_source"] as? String, abandoned["generation_id"] as? String)
        XCTAssertNotEqual(expectations["change_history_source"] as? String, abandoned["generation_id"] as? String)
    }

    private func exportSemanticErrors(_ fixture: [String: Any]) -> [String] {
        var errors: [String] = []
        let files = fixture["files"] as? [[String: Any]] ?? []
        let roles = Set(files.compactMap { $0["role"] as? String })
        let missing = requiredRoles.subtracting(roles).sorted()
        if !missing.isEmpty {
            errors.append("missing required roles: \(missing.joined(separator: ", "))")
        }

        let paths = files.compactMap { $0["path"] as? String }
        if Set(paths).count != paths.count {
            errors.append("manifest paths must be unique")
        }

        let scope = fixture["scope"] as? [String: Any] ?? [:]
        let openGapCount = (scope["open_gap_count"] as? NSNumber)?.intValue ?? 0
        let coverage = scope["detail_coverage"] as? String
        let limitations = fixture["limitations"] as? [String] ?? []
        if openGapCount > 0, coverage == "complete" {
            errors.append("open coverage gaps require partial, stale, or unavailable detail coverage")
        }
        if openGapCount > 0, limitations.isEmpty {
            errors.append("open coverage gaps require at least one human-readable limitation")
        }

        let active = scope["active_generation"] as? [String: Any]
        let hasMore = active?["has_more"] as? Bool ?? false
        let brief = fixture["brief"] as? [String: Any] ?? [:]
        if hasMore, brief["growth_assessment"] as? String != "unavailable" {
            errors.append("an active incomplete generation makes growth unavailable")
        }
        return errors
    }

    private func scanSemanticErrors(_ fixture: [String: Any]) -> [String] {
        var errors: [String] = []
        for generation in generations(fixture) {
            let state = generation["state"] as? String
            let slices = generation["slices"] as? [[String: Any]] ?? []
            for (index, slice) in slices.enumerated() {
                if (slice["slice_index"] as? NSNumber)?.intValue != index {
                    errors.append("slice indexes must be contiguous")
                }
                if index > 0,
                   !jsonValuesEqual(slices[index - 1]["cursor_after"], slice["cursor_before"]) {
                    errors.append("persisted cursor must continue at the next slice")
                }
                let hasMore = slice["has_more"] as? Bool ?? true
                let reconciles = slice["authoritative_reconciliation"] as? Bool ?? false
                if hasMore, reconciles {
                    errors.append("partial slice cannot reconcile authoritative state")
                }
                if state == "abandoned", reconciles {
                    errors.append("abandoned generation cannot reconcile authoritative state")
                }
            }
            if state == "complete" {
                guard let final = slices.last,
                      final["has_more"] as? Bool == false,
                      final["authoritative_reconciliation"] as? Bool == true else {
                    errors.append("complete generation must reconcile only at its final slice")
                    continue
                }
            }
        }
        return errors
    }

    private func generations(_ fixture: [String: Any]) -> [[String: Any]] {
        fixture["generations"] as? [[String: Any]] ?? []
    }

    private func jsonValuesEqual(_ left: Any?, _ right: Any?) -> Bool {
        switch (left, right) {
        case (nil, nil): true
        case let (left?, right?): (left as AnyObject).isEqual(right)
        default: false
        }
    }

    private func schemaErrors(_ fixture: [String: Any], schema name: String) throws -> [String] {
        let schema = try loadJSON(repositoryRoot.appending(path: "Schemas/Evidence/\(name).schema.json"))
        return validator.validate(instance: fixture, schema: schema)
    }

    private func loadFixture(_ name: String) throws -> [String: Any] {
        try loadJSON(repositoryRoot.appending(path: "Fixtures/Contracts/Evidence/\(name).json"))
    }

    private func loadJSON(_ path: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
