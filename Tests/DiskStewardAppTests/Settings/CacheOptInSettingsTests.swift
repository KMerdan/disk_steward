import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

/// TASK-631: no cache is opted in by default, opting in and out persists, and
/// settings written before the field existed still decode.
final class CacheOptInSettingsTests: XCTestCase {
    func testNothingIsOptedInByDefaultAndChoicesPersist() throws {
        var settings = MonitoringSettings.defaults
        XCTAssertTrue(settings.optedInCaches.isEmpty, "no cache is reviewed until the user opts it in")
        settings.setCache("uv", optedIn: true)
        settings.setCache("ollama", optedIn: true)
        settings.setCache("uv", optedIn: false)
        XCTAssertEqual(settings.optedInCaches, ["ollama"])
        let decoded = try JSONDecoder().decode(MonitoringSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.optedInCaches, ["ollama"])
        settings.setCache("ollama", optedIn: false)
        XCTAssertNil(settings.reviewCatalogOptIns)
    }

    func testSettingsWrittenBeforeTheOptInsStillDecode() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(MonitoringSettings.defaults)) as? [String: Any])
        object.removeValue(forKey: "reviewCatalogOptIns")
        let decoded = try JSONDecoder().decode(MonitoringSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.optedInCaches.isEmpty)
    }
}
