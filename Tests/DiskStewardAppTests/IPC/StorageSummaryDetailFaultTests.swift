@testable import DiskStewardCore
@testable import DiskStewardApp
import Foundation
import XCTest

/// TASK-642: get_storage_summary returns live capacity with an explicit
/// detail status for every evidence-store fault, and never throws for one.
final class StorageSummaryDetailFaultTests: XCTestCase {
    private enum Fault: String, CaseIterable { case missing, corrupt, summaryRefused, overCap, locked }

    func testSummaryKeepsLiveCapacityForEveryDetailFault() async throws {
        for fault in Fault.allCases {
            let root = URL(fileURLWithPath: "/tmp/ds-detail-\(fault.rawValue)-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let database = root.appending(path: "evidence.sqlite")
            var policy = try EvidenceStoreRetentionPolicy()
            var lock: SQLiteConnection?
            switch fault {
            case .missing:
                break
            case .corrupt:
                try Data(repeating: 0x5A, count: 8_192).write(to: database)
            case .summaryRefused:
                try await Self.recordObservation(at: root, database: database)
                let fixture = try SQLiteConnection(url: database)
                try fixture.execute("UPDATE retention_runs SET limitations = zeroblob(600000)")
                fixture.close()
            case .overCap:
                let store = try EvidenceStore(url: database)
                await store.close()
                let fixture = try SQLiteConnection(url: database)
                try fixture.execute("INSERT INTO snapshots (snapshot_id, observed_at, payload) VALUES ('ballast', 1, zeroblob(11534336))")
                fixture.close()
                policy = try EvidenceStoreRetentionPolicy(maxDatabaseBytes: 10 * 1_024 * 1_024)
            case .locked:
                let store = try EvidenceStore(url: database)
                await store.close()
            }
            if fault == .locked {
                // An exclusive-mode writer holds the database while the backend
                // opens it and while the summary is read.
                let holder = try SQLiteConnection(url: database)
                try holder.execute("PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE; INSERT INTO snapshots (snapshot_id, observed_at, payload) VALUES ('lock', 1, x'00');")
                lock = holder
            }
            let fixedPolicy = policy
            let backend = try AppEvidenceQueryBackend(databaseURL: database, retentionPolicyProvider: { fixedPolicy })
            let socket = root.appending(path: "ipc/service.sock").path
            let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
            try server.start()
            defer { server.stop() }
            let summary = try UnixSocketDiskStewardIPCClient(socketPath: socket)
                .call(tool: "get_storage_summary", arguments: [:], isCancelled: { false })
            if let lock { try? lock.execute("ROLLBACK"); lock.close() }
            let object = try XCTUnwrap(summary.objectValue, "\(fault)")
            guard case let .array(volumes)? = object["volumes"], case let .array(reasons)? = object["detail_reasons"] else {
                return XCTFail("\(fault): volumes and detail_reasons are arrays")
            }
            XCTAssertFalse(volumes.isEmpty, "\(fault): live capacity is answered")
            XCTAssertNotNil(object[StorageSummaryContract.liveVolumeObservedAt]?.stringValue, "\(fault)")
            let reasonText = reasons.compactMap(\.stringValue).joined(separator: "; ")
            switch fault {
            case .missing:
                XCTAssertEqual(object["detail_status"], .string("available"))
                XCTAssertEqual(object[StorageSummaryContract.persistedStateAsOf], .null, "nothing observed yet")
            case .overCap:
                XCTAssertEqual(object["detail_status"], .string("available"))
                XCTAssertEqual(object["storage_admission"], .string("retention-required"))
            case .corrupt:
                XCTAssertEqual(object["detail_status"], .string("unavailable"))
                XCTAssertTrue(reasonText.contains("detail_unavailable"), reasonText)
                XCTAssertEqual(object["coverage"], .string("unavailable"))
            case .summaryRefused:
                XCTAssertEqual(object["detail_status"], .string("unavailable"))
                XCTAssertTrue(reasonText.contains("lifecycle metadata exceeds the summary budget"), reasonText)
                XCTAssertNotEqual(object[StorageSummaryContract.persistedStateAsOf], .null, "freshness survives a refused summary")
            case .locked:
                XCTAssertEqual(object["detail_status"], .string("unavailable"), reasonText)
                XCTAssertFalse(reasons.isEmpty)
            }
            XCTAssertFalse(reasonText.contains(root.path), "\(fault): reasons carry no paths")
        }
    }

    static func recordObservation(at root: URL, database: URL) async throws {
        let watched = root.appending(path: "watch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try Data([1]).write(to: watched.appending(path: "recorded.bin"))
        let observedAt = Date()
        let policy = MonitoringPolicy(watchedRoots: [watched])
        let store = try EvidenceStore(url: database)
        _ = try await store.recordObservation(
            snapshot: .init(snapshotID: "detail-fault", observedAt: EvidenceTimestamp.format(observedAt), volumes: []),
            metadata: DirectoryMetadataScanner().scan(policy: policy, at: observedAt),
            scope: policy.scopeVersion(at: observedAt), trigger: .scheduled)
        _ = try await store.applyRetention(try .init(), trigger: .manual)
        await store.close()
    }
}
