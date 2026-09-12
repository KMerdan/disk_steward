import CoreFoundation
import Foundation
import XCTest

final class EndpointSecurityContractTests: XCTestCase {
    private let validator = JSONSchemaContractValidator()

    func testExactCreateRenameAndCoalescedCloseRequireCompleteLinkage() throws {
        let schema = try object("Schemas/EndpointSecurity/privileged-event-v1.schema.json")
        let names = ["exact-create", "exact-rename", "exact-close-coalesced"]
        let events = try names.map { try object("Fixtures/EndpointSecurity/\($0).json") }
        for (name, event) in zip(names, events) {
            XCTAssertEqual(validator.validate(instance: event, schema: schema), [], name)
            try assertExactEligible(event)
        }
        XCTAssertEqual(events.map { $0["operation"] as? String }, ["create", "rename", "write-close"])
        XCTAssertEqual((events[2]["delivery"] as? [String: Any])?["coalesced_count"] as? Int, 6)
        XCTAssertEqual((events[2]["size"] as? [String: Any])?["allocated_delta"] as? Int, 4096)
    }

    func testPIDReuseUsesPIDAndStartTimeIdentity() throws {
        let first = try object("Fixtures/EndpointSecurity/pid-reuse-first.json")
        let second = try object("Fixtures/EndpointSecurity/pid-reuse-second.json")
        let old = try processIdentity(first)
        let new = try processIdentity(second)
        XCTAssertEqual(old.pid, new.pid)
        XCTAssertNotEqual(old.start, new.start)
        XCTAssertNotEqual(old, new)
    }

    func testIncompleteOrGappedEventCannotClaimExact() throws {
        let schema = try object("Schemas/EndpointSecurity/privileged-event-v1.schema.json")
        let invalid = try object("Fixtures/EndpointSecurity/invalid-exact-incomplete.json")
        let errors = validator.validate(instance: invalid, schema: schema)
        XCTAssertTrue(errors.contains { $0.contains("file_identity.file_id") && $0.contains("required") })
        XCTAssertThrowsError(try assertExactEligible(invalid))
    }

    func testDenialLossOverloadAndUnavailableStatesKeepFallbackActive() throws {
        let schema = try object("Schemas/EndpointSecurity/privileged-bridge-status-v1.schema.json")
        let cases = try array("Fixtures/EndpointSecurity/status-cases.json")
        XCTAssertEqual(cases.count, 5)
        for status in cases {
            XCTAssertEqual(validator.validate(instance: status, schema: schema), [])
            let fallback = try XCTUnwrap(status["fallback"] as? [String: Any])
            XCTAssertEqual(fallback["active"] as? Bool, true)
            XCTAssertNotEqual(fallback["maximum_confidence"] as? String, "exact")
            XCTAssertFalse((status["limitations"] as? [String] ?? []).isEmpty)
        }
        let byState = Dictionary(uniqueKeysWithValues: cases.compactMap { caseValue -> (String, [String: Any])? in
            guard let state = caseValue["state"] as? String else { return nil }
            return (state, caseValue)
        })
        XCTAssertEqual((byState["dropped-events"]?["dropped_events"] as? Int), 42)
        XCTAssertEqual((byState["overloaded"]?["dropped_events"] as? Int), 1200)
        XCTAssertEqual((byState["not-entitled"]?["retry"] as? [String: Any])?["requires_user_action"] as? Bool, true)
        XCTAssertEqual((byState["not-permitted"]?["retry"] as? [String: Any])?["requires_user_action"] as? Bool, true)
    }

    func testPrivacyFilteringIsDeterministicAndContentsAreUnrepresentable() throws {
        let cases = try array("Fixtures/EndpointSecurity/privacy-filter-cases.json")
        for item in cases {
            let path = try XCTUnwrap(item["path"] as? String)
            let watched = item["watched_roots"] as? [String] ?? []
            let excluded = item["excluded_roots"] as? [String] ?? []
            let actual = watched.contains { contains(path, root: $0) }
                && !excluded.contains { contains(path, root: $0) }
            XCTAssertEqual(actual, item["emit"] as? Bool, item["label"] as? String ?? path)
        }
        let eventSchema = try object("Schemas/EndpointSecurity/privileged-event-v1.schema.json")
        let properties = try XCTUnwrap(eventSchema["properties"] as? [String: Any])
        XCTAssertNil(properties["file_contents"])
        XCTAssertNil(properties["environment"])
        XCTAssertNil(properties["arguments"])
        XCTAssertNil(properties["command_line"])
    }

    private func assertExactEligible(_ event: [String: Any]) throws {
        let process = try XCTUnwrap(event["process"] as? [String: Any])
        let file = try XCTUnwrap(event["file_identity"] as? [String: Any])
        let size = try XCTUnwrap(event["size"] as? [String: Any])
        let scope = try XCTUnwrap(event["scope"] as? [String: Any])
        let delivery = try XCTUnwrap(event["delivery"] as? [String: Any])
        let attribution = try XCTUnwrap(event["attribution"] as? [String: Any])
        guard attribution["confidence"] as? String == "exact",
              attribution["method"] as? String == "endpoint-security-file-process",
              process["pid"] is NSNumber,
              process["start_time"] is String,
              file["volume_id"] is String,
              file["file_id"] is NSNumber,
              size["complete"] as? Bool == true,
              size["measurement"] as? String != "unknown",
              scope["included"] as? Bool == true,
              delivery["gap_before"] as? Bool == false,
              delivery["deadline_met"] as? Bool == true
        else { throw ContractError.incompleteExactLinkage }
    }

    private func processIdentity(_ event: [String: Any]) throws -> ProcessKey {
        let process = try XCTUnwrap(event["process"] as? [String: Any])
        return ProcessKey(pid: try XCTUnwrap(process["pid"] as? Int), start: try XCTUnwrap(process["start_time"] as? String))
    }

    private func contains(_ path: String, root: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = URL(fileURLWithPath: root).standardizedFileURL.path
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private func object(_ path: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repositoryRoot.appendingPathComponent(path))) as? [String: Any])
    }

    private func array(_ path: String) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repositoryRoot.appendingPathComponent(path))) as? [[String: Any]])
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct ProcessKey: Equatable {
    let pid: Int
    let start: String
}

private enum ContractError: Error {
    case incompleteExactLinkage
}
