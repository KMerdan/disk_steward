import Foundation
import XCTest
@testable import DiskStewardApp

final class VerificationIsolationTests: XCTestCase {
    func testArtifactOutputRequiresNewLeafUnderPrivateTemporaryParent() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ds-artifact-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appending(path: "existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appending(path: "export-fixture")
        let bytes = Data("preserve me".utf8)
        try bytes.write(to: sentinel)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        for invalid in [existing.path, link.path, link.appending(path: "new").path, root.path + "/../escape", "/Users/fixture/Documents/export", "relative-export"] {
            XCTAssertThrowsError(try AppConfiguration.createVerificationArtifactDirectory(invalid), invalid)
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), ["export-fixture"])
        let created = try AppConfiguration.createVerificationArtifactDirectory(root.appending(path: "new-output").path)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: created.path).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try AppConfiguration.createVerificationArtifactDirectory(root.appending(path: "nonprivate").path))
    }

    func testNormalStartupAndSmokeCannotMistakeSupportOverrideForIsolation() throws {
        let environment = ["DISK_STEWARD_SUPPORT_DIRECTORY": "/fake-production"]
        XCTAssertThrowsError(try AppConfiguration.validateLaunch(isSmoke: false, environment: environment))
        XCTAssertNoThrow(try AppConfiguration.validateLaunch(isSmoke: false, environment: [:]))
        XCTAssertNoThrow(try AppConfiguration.validateLaunch(isSmoke: true, environment: environment))
        let first = AppConfiguration.resolveSupportDirectory(isSmoke: true, environment: environment)
        let second = AppConfiguration.resolveSupportDirectory(isSmoke: true, environment: environment)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.path, "/fake-production")
        XCTAssertEqual(AppConfiguration.resolveSupportDirectory(isSmoke: false, environment: environment), AppConfiguration.resolveSupportDirectory(isSmoke: false, environment: [:]))
    }
}
