import Foundation
import XCTest

final class ContractTests: XCTestCase {
    private let validator = JSONSchemaContractValidator()

    func testValidEvidenceEvent() throws {
        XCTAssertEqual(try errors(fixture: "valid-evidence-event", schema: "evidence-event-v1"), [])
    }

    func testEvidenceRequiresConfidence() throws {
        let result = try errors(fixture: "invalid-evidence-missing-confidence", schema: "evidence-event-v1")
        XCTAssertTrue(result.contains(where: { $0.contains("attribution.confidence") && $0.contains("missing") }))
    }

    func testEvidenceRejectsFileContents() throws {
        let result = try errors(fixture: "invalid-evidence-with-content", schema: "evidence-event-v1")
        XCTAssertTrue(result.contains(where: { $0.contains("file_contents") && $0.contains("forbidden") }))
    }

    func testRetentionPolicyIsBounded() throws {
        XCTAssertEqual(try errors(fixture: "valid-retention-policy", schema: "retention-policy-v1"), [])

        let result = try errors(fixture: "invalid-retention-unbounded", schema: "retention-policy-v1")
        XCTAssertGreaterThanOrEqual(result.count, 4)
        XCTAssertTrue(result.contains(where: { $0.contains("raw_event_days") && $0.contains("maximum") }))
        XCTAssertTrue(result.contains(where: { $0.contains("max_database_bytes") && $0.contains("maximum") }))
    }

    func testExportManifestRequiresLimitationsAndValidHashes() throws {
        XCTAssertEqual(try errors(fixture: "valid-export-manifest", schema: "export-manifest-v1"), [])

        let result = try errors(fixture: "invalid-export-manifest", schema: "export-manifest-v1")
        XCTAssertTrue(result.contains(where: { $0.contains("limitations") && $0.contains("missing") }))
        XCTAssertTrue(result.contains(where: { $0.contains("sha256") && $0.contains("pattern") }))
    }

    func testPrivacyContractHardDisablesContentsAndEnvironment() throws {
        let schema = try loadJSON(path: repositoryRoot.appending(path: "Schemas/privacy-policy-v1.schema.json")) as! [String: Any]
        let valid: [String: Any] = [
            "schema": "privacy-policy-v1",
            "record_file_contents": false,
            "capture_environment": false,
            "path_detail": "hashed",
            "excluded_paths": ["/Users/example/Private"],
            "redacted_argument_patterns": ["--token"],
        ]
        XCTAssertEqual(validator.validate(instance: valid, schema: schema), [])

        var unsafe = valid
        unsafe["record_file_contents"] = true
        unsafe["capture_environment"] = true
        let result = validator.validate(instance: unsafe, schema: schema)
        XCTAssertEqual(result.filter { $0.contains("does not match const") }.count, 2)
    }

    func testEverySchemaIsClosedAndVersioned() throws {
        let schemaDirectory = repositoryRoot.appending(path: "Schemas")
        let files = try FileManager.default.contentsOfDirectory(at: schemaDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertGreaterThanOrEqual(files.count, 6)

        for file in files {
            let schema = try loadJSON(path: file) as! [String: Any]
            XCTAssertEqual(schema["type"] as? String, "object", file.lastPathComponent)
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false, file.lastPathComponent)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let discriminator = try XCTUnwrap(properties["schema"] as? [String: Any])
            XCTAssertNotNil(discriminator["const"], file.lastPathComponent)
        }
    }

    private func errors(fixture: String, schema: String) throws -> [String] {
        let instance = try loadJSON(path: repositoryRoot.appending(path: "Fixtures/Contracts/\(fixture).json"))
        let schemaObject = try loadJSON(path: repositoryRoot.appending(path: "Schemas/\(schema).schema.json")) as! [String: Any]
        return validator.validate(instance: instance, schema: schemaObject)
    }

    private func loadJSON(path: URL) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: path))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
