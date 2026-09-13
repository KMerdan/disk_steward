import Foundation
import XCTest

final class DistributionReleaseIntegrityTests: XCTestCase {
    private let expectedAppID = "com.marudankiji.disksteward"
    private let expectedHelperID = "com.marudankiji.disksteward.mcp"
    private let expectedTeamID = "G3P6TU385Y"

    func testReleasePolicyAcceptsOnlyCompleteDeveloperIDFixture() throws {
        let fixtures = try JSONDecoder().decode(
            [ReleaseObservation].self,
            from: Data(contentsOf: repository.appendingPathComponent("Tests/Distribution/release-policy-fixtures.json"))
        )
        XCTAssertEqual(fixtures.filter { $0.expectedIssue == nil }.count, 1)
        XCTAssertGreaterThanOrEqual(fixtures.count, 12)

        for fixture in fixtures {
            XCTAssertEqual(validate(fixture), fixture.expectedIssue, fixture.name)
        }
    }

    func testProductionVerifierContainsEveryFailClosedArtifactGate() throws {
        let verifier = try text("Scripts/Distribution/verify-release")
        let requiredControls = [
            "com.marudankiji.disksteward",
            "com.marudankiji.disksteward.mcp",
            "Authority=Apple Distribution:",
            "Authority=Developer ID Application:",
            "TeamIdentifier=G3P6TU385Y",
            "Timestamp=",
            "runtime",
            "com.apple.security.application-groups",
            "no additional entitlement keys or group values",
            "codesign --verify --deep --strict",
            "xcrun stapler validate",
            "spctl --assess --type execute",
        ]
        for control in requiredControls {
            XCTAssertTrue(verifier.contains(control), "Missing production release control: \(control)")
        }

        let release = try text("Config/Signing/Release.xcconfig")
        XCTAssertTrue(release.contains("CODE_SIGN_IDENTITY = Developer ID Application"))
        XCTAssertTrue(release.contains("DEVELOPMENT_TEAM = \(expectedTeamID)"))
        XCTAssertTrue(release.contains("ENABLE_HARDENED_RUNTIME = YES"))
        XCTAssertFalse(release.contains("DISK_STEWARD_TEAM_ID_REQUIRED"))
    }

    func testStandardAndOptionalEntitlementsRemainSeparated() throws {
        let app = try entitlementKeys("Config/Entitlements/DiskStewardApp.entitlements")
        let endpoint = try entitlementKeys("Config/Entitlements/DiskStewardEndpoint.entitlements")
        XCTAssertEqual(app, ["com.apple.security.application-groups"])
        XCTAssertEqual(endpoint, ["com.apple.security.application-groups", "com.apple.developer.endpoint-security.client"])
    }

    func testActualVerifierRejectsMissingHelperWrongBundleAndUnsignedArtifact() throws {
        let missingHelper = try makeApp(bundleID: expectedAppID, includeHelper: false)
        defer { try? FileManager.default.removeItem(at: missingHelper.deletingLastPathComponent()) }
        let missing = try runVerifier(missingHelper)
        XCTAssertEqual(missing.status, 67)
        XCTAssertTrue(missing.output.contains("bundled MCP helper is missing"))

        let wrongBundle = try makeApp(bundleID: "example.invalid.disksteward", includeHelper: true)
        defer { try? FileManager.default.removeItem(at: wrongBundle.deletingLastPathComponent()) }
        let wrong = try runVerifier(wrongBundle)
        XCTAssertEqual(wrong.status, 67)
        XCTAssertTrue(wrong.output.contains("application bundle identifier"))

        let unsigned = try makeApp(bundleID: expectedAppID, includeHelper: true)
        defer { try? FileManager.default.removeItem(at: unsigned.deletingLastPathComponent()) }
        let unsignedResult = try runVerifier(unsigned)
        XCTAssertEqual(unsignedResult.status, 67)
        XCTAssertTrue(unsignedResult.output.contains("signature is missing, ad hoc, damaged, or incomplete"))
    }

    func testRepositoryReleaseSurfacesContainNoCredentialMaterial() throws {
        let roots = ["Config", "Scripts", "Sources", "docs/release"]
        let forbidden = [
            "-----BEGIN " + "PRIVATE KEY-----",
            "notarytool " + "store-credentials",
            "AC_" + "PASSWORD=",
            "APPLE_ID_" + "PASSWORD=",
            "NOTARY_" + "PASSWORD=",
        ]
        var violations: [String] = []
        for root in roots {
            let url = repository.appendingPathComponent(root, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) < 1_000_000,
                      let contents = try? String(contentsOf: file, encoding: .utf8)
                else { continue }
                for pattern in forbidden where contents.localizedCaseInsensitiveContains(pattern) {
                    violations.append(file.path.replacingOccurrences(of: repository.path + "/", with: ""))
                }
            }
        }
        XCTAssertEqual(violations, [])
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    }

    private func entitlementKeys(_ path: String) throws -> Set<String> {
        let data = try Data(contentsOf: repository.appendingPathComponent(path))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return Set(try XCTUnwrap(object as? [String: Any]).keys)
    }

    private func validate(_ value: ReleaseObservation) -> String? {
        if value.appBundleID != expectedAppID { return "app-bundle-id" }
        if value.helperIdentifier != expectedHelperID { return "helper-identifier" }
        if value.authority != "Developer ID Application" { return "authority" }
        if value.teamID != expectedTeamID { return "team-id" }
        if !value.appSignatureValid { return "app-signature" }
        if !value.helperSignatureValid { return "helper-signature" }
        if !value.hardenedRuntime { return "hardened-runtime" }
        if !value.secureTimestamp { return "secure-timestamp" }
        if Set(value.appEntitlements) != ["com.apple.security.application-groups"] { return "app-entitlements" }
        if !value.stapleValid { return "notarization-staple" }
        if !value.gatekeeperAccepted { return "gatekeeper" }
        return nil
    }

    private func makeApp(bundleID: String, includeHelper: Bool) throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ds-release-negative-\(UUID().uuidString)", isDirectory: true)
        let app = parent.appendingPathComponent("Disk Steward.app", isDirectory: true)
        let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Disk Steward",
            "CFBundlePackageType": "APPL",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Disk Steward")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if includeHelper {
            let helper = helpers.appendingPathComponent("disk-witness-mcp")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        }
        return app
    }

    private func runVerifier(_ artifact: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = repository.appendingPathComponent("Scripts/Distribution/verify-release")
        process.arguments = [artifact.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

private struct ReleaseObservation: Decodable {
    let name: String
    let appBundleID: String
    let helperIdentifier: String
    let authority: String
    let teamID: String
    let appSignatureValid: Bool
    let helperSignatureValid: Bool
    let hardenedRuntime: Bool
    let secureTimestamp: Bool
    let appEntitlements: [String]
    let stapleValid: Bool
    let gatekeeperAccepted: Bool
    let expectedIssue: String?
}
