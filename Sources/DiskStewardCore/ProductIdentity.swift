import Foundation

/// Stable product metadata shared by the app, exports, and future integrations.
public struct ProductIdentity: Codable, Equatable, Sendable {
    public let name: String
    public let evidenceProducer: String
    public let schemaVersion: Int

    public init(
        name: String,
        evidenceProducer: String,
        schemaVersion: Int
    ) {
        self.name = name
        self.evidenceProducer = evidenceProducer
        self.schemaVersion = schemaVersion
    }

    public static let diskSteward = ProductIdentity(
        name: "Disk Steward",
        evidenceProducer: "disk-steward",
        schemaVersion: 1
    )
}

