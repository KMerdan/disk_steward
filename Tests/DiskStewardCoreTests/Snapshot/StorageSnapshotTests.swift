import Foundation
import XCTest
@testable import DiskStewardCore

final class StorageSnapshotTests: XCTestCase {
    func testVolumeCapacityClampsInvalidFixtureValues() {
        let volume = VolumeCapacity(
            mountPath: "/fixture",
            totalBytes: 1_000,
            availableBytes: 1_200,
            isInternal: true,
            isReadOnly: false
        )

        XCTAssertEqual(volume.totalBytes, 1_000)
        XCTAssertEqual(volume.availableBytes, 1_000)
        XCTAssertEqual(volume.usedBytes, 0)
    }

    func testSnapshotFixtureIsDeterministicAndSchemaValid() throws {
        let snapshot = StorageSnapshot(
            snapshotID: "snapshot-fixture",
            observedAt: "2026-09-12T00:00:00.000Z",
            volumes: [
                .init(mountPath: "/z", totalBytes: 1_000, availableBytes: 250, isInternal: false, isReadOnly: true),
                .init(mountPath: "/a", totalBytes: 2_000, availableBytes: 500, isInternal: true, isReadOnly: false),
            ],
            limitations: ["z limitation", "a limitation"]
        )

        XCTAssertEqual(snapshot.volumes.map(\.mountPath), ["/a", "/z"])
        XCTAssertEqual(snapshot.limitations, ["a limitation", "z limitation"])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        let schema = try SnapshotJSONSchemaValidator.loadSchema(named: "storage-snapshot-v1")
        XCTAssertEqual(SnapshotJSONSchemaValidator().validate(instance: object, schema: schema), [])
    }

    func testCurrentDataVolumeLiveSmoke() throws {
        let snapshot = try VolumeSnapshotService(
            volumeSource: VolumeSnapshotService.currentDataVolume,
            identifierSource: { "live-smoke" },
            dateSource: { Date(timeIntervalSince1970: 0) }
        ).capture()

        XCTAssertFalse(snapshot.volumes.isEmpty)
        for volume in snapshot.volumes {
            XCTAssertGreaterThanOrEqual(volume.totalBytes, 0)
            XCTAssertGreaterThanOrEqual(volume.usedBytes, 0)
            XCTAssertGreaterThanOrEqual(volume.availableBytes, 0)
            XCTAssertEqual(volume.usedBytes + volume.availableBytes, volume.totalBytes)
        }
    }
}
