import Foundation
import XCTest
@testable import DiskStewardApp

@MainActor
final class AboutVersionTests: XCTestCase {
    func testAboutUsesVersionAndStringBuildFromBundleMetadata() {
        let view = AboutView(infoDictionary: [
            "CFBundleShortVersionString": "2.7.3",
            "CFBundleVersion": "42",
        ])
        XCTAssertEqual(view.versionDescription, "Version 2.7.3 (42)")
    }

    func testAboutSupportsIntegerBuildUsedByCurrentPackaging() {
        let view = AboutView(infoDictionary: [
            "CFBundleShortVersionString": "1.2.0",
            "CFBundleVersion": 4,
        ])
        XCTAssertEqual(view.versionDescription, "Version 1.2.0 (4)")
    }

    func testAboutSupportsVersionWithoutBuild() {
        XCTAssertEqual(
            AboutView(infoDictionary: ["CFBundleShortVersionString": "3.0.1"]).versionDescription,
            "Version 3.0.1"
        )
    }

    func testAboutSupportsBuildWithoutMarketingVersion() {
        XCTAssertEqual(AboutView(infoDictionary: ["CFBundleVersion": "57"]).versionDescription, "Build 57")
    }

    func testUnbundledDevelopmentBuildDoesNotInventAReleaseVersion() {
        XCTAssertEqual(AboutView(infoDictionary: nil).versionDescription, "Development build")
        XCTAssertEqual(AboutView(infoDictionary: [:]).versionDescription, "Development build")
    }

    func testBlankAndUnexpectedMetadataDoNotProduceBrokenLabels() {
        XCTAssertEqual(AboutView(infoDictionary: [
            "CFBundleShortVersionString": " \n",
            "CFBundleVersion": "\t",
        ]).versionDescription, "Development build")
        XCTAssertEqual(AboutView(infoDictionary: [
            "CFBundleShortVersionString": ["invalid"],
            "CFBundleVersion": ["invalid"],
        ]).versionDescription, "Development build")
    }

    func testAboutTrimsSurroundingWhitespace() {
        XCTAssertEqual(AboutView(infoDictionary: [
            "CFBundleShortVersionString": " 2.0.0\n",
            "CFBundleVersion": " 9 ",
        ]).versionDescription, "Version 2.0.0 (9)")
    }

    func testDefaultInitializerUsesMainBundleMetadata() {
        XCTAssertEqual(
            AboutView().versionDescription,
            AboutView(infoDictionary: Bundle.main.infoDictionary).versionDescription
        )
    }
}
