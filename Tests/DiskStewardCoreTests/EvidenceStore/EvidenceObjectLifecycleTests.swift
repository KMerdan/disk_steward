import Foundation
import XCTest
@testable import DiskStewardCore

final class EvidenceObjectLifecycleTests: XCTestCase, @unchecked Sendable {
    func testCompleteABCObservationRecordsDeletionAndReplayIsIdempotent() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])

        _ = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [
                Self.file("A", path: "/watch/A", bytes: 10),
                Self.file("B", path: "/watch/B", bytes: 20),
                Self.file("C", path: "/watch/C", bytes: 30),
            ]),
            scope: scope,
            trigger: .scheduled
        )
        let result = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [
                Self.file("A", path: "/watch/A", bytes: 10),
                Self.file("C", path: "/watch/C", bytes: 30),
            ]),
            scope: scope,
            trigger: .scheduled
        )

        XCTAssertEqual(result.events.map(\.operation), [.delete])
        XCTAssertEqual(result.events.first?.path, "/watch/B")
        XCTAssertEqual(result.currentFiles.map(\.path).sorted(), ["/watch/A", "/watch/C"])
        let countBeforeReplay = try await store.eventCount()

        let replay = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [
                Self.file("A", path: "/watch/A", bytes: 10),
                Self.file("C", path: "/watch/C", bytes: 30),
            ]),
            scope: scope,
            trigger: .scheduled
        )
        XCTAssertTrue(replay.events.isEmpty)
        let countAfterReplay = try await store.eventCount()
        XCTAssertEqual(countAfterReplay, countBeforeReplay)
        await store.close()
    }

    func testPartialABCObservationKeepsBUnknownUntilCompleteRecovery() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        _ = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [
                Self.file("A", path: "/watch/A", bytes: 10),
                Self.file("B", path: "/watch/B", bytes: 20),
                Self.file("C", path: "/watch/C", bytes: 30),
            ]),
            scope: scope,
            trigger: .scheduled
        )

        let partial = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-2"),
            metadata: Self.metadata(
                id: "O2",
                scope: scope,
                files: [Self.file("A", path: "/watch/A", bytes: 10), Self.file("C", path: "/watch/C", bytes: 30)],
                coverage: .partial,
                limitations: ["Detailed scan stopped at the configured entry limit."]
            ),
            scope: scope,
            trigger: .scheduled
        )

        XCTAssertFalse(partial.events.contains { $0.operation == .delete })
        let unknownB = try XCTUnwrap(partial.currentFiles.first { $0.objectID == "B" })
        XCTAssertEqual(unknownB.presence, .unknown)
        XCTAssertFalse(unknownB.actionable)
        XCTAssertEqual(unknownB.stateAsOfObservationID, "O1")
        XCTAssertEqual(partial.coverageGaps.map(\.reason), ["entry-cap"])

        let recovered = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-3"),
            metadata: Self.metadata(id: "O3", scope: scope, files: [
                Self.file("A", path: "/watch/A", bytes: 10),
                Self.file("C", path: "/watch/C", bytes: 30),
            ]),
            scope: scope,
            trigger: .recovery
        )
        XCTAssertEqual(recovered.events.map(\.operation), [.delete])
        let allGaps = try await store.coverageGaps()
        XCTAssertNotNil(allGaps.first { $0.observationID == "O2" }?.endedAt)
        await store.close()
    }

    func testHardLinkedPathsRemainOnePhysicalObjectAndNeverCrashReconciliation() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])

        let first = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [
                Self.file("shared-inode", path: "/watch/a", bytes: 64, linkCount: 2),
                Self.file("shared-inode", path: "/watch/b", bytes: 64, linkCount: 2),
            ]),
            scope: scope,
            trigger: .startup
        )

        XCTAssertEqual(first.events.map(\.operation), [.baseline])
        XCTAssertEqual(first.currentFiles.count, 1)
        XCTAssertEqual(first.currentFiles.first?.path, "/watch/a")
        XCTAssertEqual(first.currentFiles.first?.allocatedBytes, 64)
        XCTAssertFalse(first.currentFiles.first?.actionable == true)
        let actionableWhileLinked = try await store.currentFiles()
        XCTAssertTrue(actionableWhileLinked.isEmpty)

        let repeated = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [
                Self.file("shared-inode", path: "/watch/b", bytes: 64, linkCount: 2),
                Self.file("shared-inode", path: "/watch/a", bytes: 64, linkCount: 2),
            ], seconds: 1),
            scope: scope,
            trigger: .scheduled
        )
        XCTAssertTrue(repeated.events.isEmpty)
        XCTAssertEqual(repeated.currentFiles.first?.path, "/watch/a")

        let oneLinkRemaining = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-3"),
            metadata: Self.metadata(id: "O3", scope: scope, files: [
                Self.file("shared-inode", path: "/watch/b", bytes: 64),
            ], seconds: 2),
            scope: scope,
            trigger: .scheduled
        )
        XCTAssertTrue(oneLinkRemaining.events.isEmpty)
        XCTAssertEqual(oneLinkRemaining.currentFiles.first?.path, "/watch/b")
        XCTAssertTrue(oneLinkRemaining.currentFiles.first?.actionable == true)

        let deleted = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-4"),
            metadata: Self.metadata(id: "O4", scope: scope, files: [], seconds: 3),
            scope: scope,
            trigger: .scheduled
        )
        XCTAssertEqual(deleted.events.map(\.operation), [.delete])
        XCTAssertTrue(deleted.currentFiles.isEmpty)
        await store.close()
    }

    func testModifyTruncateRenameAndReplacementHaveDistinctIdentityAwareEvents() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])

        let observations: [(String, FileMetadata, EvidenceStoreEvent.Operation?)] = [
            ("O1", Self.file("object-1", path: "/watch/item", bytes: 100), .baseline),
            ("O2", Self.file("object-1", path: "/watch/item", bytes: 150), .modify),
            ("O3", Self.file("object-1", path: "/watch/item", bytes: 50), .truncate),
            ("O4", Self.file("object-1", path: "/watch/renamed", bytes: 50), .rename),
            ("O5", Self.file("object-2", path: "/watch/renamed", bytes: 75), .replace),
        ]

        for (offset, item) in observations.enumerated() {
            let result = try await store.recordObservation(
                snapshot: Self.volumeSnapshot(id: "volume-\(offset + 1)"),
                metadata: Self.metadata(id: item.0, scope: scope, files: [item.1], seconds: offset),
                scope: scope,
                trigger: .scheduled
            )
            XCTAssertEqual(result.events.map(\.operation), [item.2].compactMap { $0 })
        }
        let current = try await store.currentFiles(includeNonActionable: true)
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.objectID, "object-2")
        XCTAssertEqual(current.first?.path, "/watch/renamed")
        await store.close()
    }

    func testScopeChangeEmitsEnterAndExitWithoutClaimingDeletion() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let oldScope = Self.scope(id: "scope-old", roots: ["/watch"])
        let newScope = Self.scope(id: "scope-new", roots: ["/other"])
        _ = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-1"),
            metadata: Self.metadata(id: "O1", scope: oldScope, files: [Self.file("B", path: "/watch/B", bytes: 20)]),
            scope: oldScope,
            trigger: .scheduled
        )

        let result = try await store.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-2"),
            metadata: Self.metadata(id: "O2", scope: newScope, files: [Self.file("D", path: "/other/D", root: "/other", bytes: 40)]),
            scope: newScope,
            trigger: .scheduled
        )

        XCTAssertEqual(Set(result.events.map(\.operation)), Set([.scopeEnter, .scopeExit]))
        XCTAssertFalse(result.events.contains { $0.operation == .delete })
        let old = try XCTUnwrap(result.currentFiles.first { $0.objectID == "B" })
        XCTAssertEqual(old.presence, .outOfScope)
        XCTAssertFalse(old.actionable)
        await store.close()
    }

    func testRestartRecordsOfflineIntervalAndStillReconcilesCompleteDeletion() async throws {
        let fixture = try LifecycleFixture()
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        var store: EvidenceStore? = try EvidenceStore(url: fixture.databaseURL)
        _ = try await store!.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-1"),
            metadata: Self.metadata(id: "O1", scope: scope, files: [Self.file("B", path: "/watch/B", bytes: 20)]),
            scope: scope,
            trigger: .scheduled
        )
        await store!.close()
        store = nil

        let reopened = try EvidenceStore(url: fixture.databaseURL)
        let result = try await reopened.recordObservation(
            snapshot: Self.volumeSnapshot(id: "volume-2"),
            metadata: Self.metadata(id: "O2", scope: scope, files: [], seconds: 60),
            scope: scope,
            trigger: .startup
        )
        XCTAssertEqual(result.events.map(\.operation), [.delete])
        XCTAssertTrue(result.coverageGaps.contains { $0.reason == "app-offline" && $0.endedAt != nil })
        await reopened.close()
    }

    func testObservationTransactionRollsBackOnScopeMismatch() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        let wrong = MetadataSnapshot(
            observationID: "O1",
            scopeVersionID: "different-scope",
            observedAt: Self.start,
            entries: [:],
            rootCoverage: [.init(rootPath: "/watch", coverage: .complete)],
            limitations: []
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await store.recordObservation(
                snapshot: Self.volumeSnapshot(id: "volume-1"),
                metadata: wrong,
                scope: scope,
                trigger: .manual
            )
        }
        let diagnostics = try await store.diagnostics()
        XCTAssertEqual(diagnostics.observationCount, 0)
        XCTAssertEqual(diagnostics.eventCount, 0)
        await store.close()
    }

    func testDuplicateRootCoverageIsRejectedWithoutWritingAnObservation() async throws {
        let fixture = try LifecycleFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let scope = Self.scope(id: "scope-watch", roots: ["/watch"])
        let duplicateCoverage = MetadataSnapshot(
            observationID: "O1",
            scopeVersionID: scope.scopeVersionID,
            observedAt: Self.start,
            entries: [:],
            rootCoverage: [
                .init(rootPath: "/watch", coverage: .complete),
                .init(rootPath: "/watch", coverage: .partial, limitations: ["duplicate"]),
            ],
            limitations: []
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await store.recordObservation(
                snapshot: Self.volumeSnapshot(id: "volume-1"),
                metadata: duplicateCoverage,
                scope: scope,
                trigger: .manual
            )
        }
        let diagnostics = try await store.diagnostics()
        XCTAssertEqual(diagnostics.observationCount, 0)
        XCTAssertEqual(diagnostics.eventCount, 0)
        await store.close()
    }

    private static let start = Date(timeIntervalSince1970: 2_000_000_000)

    private static func scope(id: String, roots: [String]) -> EvidenceScopeVersion {
        EvidenceScopeVersion(
            scopeVersionID: id,
            effectiveAt: start,
            rootPaths: roots,
            excludedPaths: [],
            maximumEntries: 10_000,
            maximumDepth: 10
        )
    }

    private static func file(
        _ id: String,
        path: String,
        root: String = "/watch",
        bytes: Int64,
        linkCount: Int = 1
    ) -> FileMetadata {
        FileMetadata(
            objectID: id,
            identityMethod: .volumeFileGeneration,
            rootPath: root,
            path: path,
            logicalBytes: bytes,
            allocatedBytes: bytes,
            modifiedAt: start.addingTimeInterval(Double(bytes)),
            linkCount: linkCount
        )
    }

    private static func metadata(
        id: String,
        scope: EvidenceScopeVersion,
        files: [FileMetadata],
        coverage: ObservationCoverage = .complete,
        limitations: [String] = [],
        seconds: Int = 0
    ) -> MetadataSnapshot {
        MetadataSnapshot(
            observationID: id,
            scopeVersionID: scope.scopeVersionID,
            observedAt: start.addingTimeInterval(Double(seconds)),
            entries: Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) }),
            rootCoverage: scope.rootPaths.map { .init(rootPath: $0, coverage: coverage, limitations: limitations) },
            limitations: limitations
        )
    }

    private static func volumeSnapshot(id: String) -> StorageSnapshot {
        StorageSnapshot(
            snapshotID: id,
            observedAt: "2033-05-18T03:33:20.000Z",
            volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)]
        )
    }
}

private final class LifecycleFixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "evidence.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
