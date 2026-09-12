import XCTest
@testable import DiskStewardCore

final class ProductIdentityTests: XCTestCase {
    func testStableEvidenceIdentity() throws {
        let identity = ProductIdentity.diskSteward

        XCTAssertEqual(identity.name, "Disk Steward")
        XCTAssertEqual(identity.evidenceProducer, "disk-steward")
        XCTAssertEqual(identity.schemaVersion, 1)

        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(ProductIdentity.self, from: encoded)
        XCTAssertEqual(decoded, identity)
    }
}

