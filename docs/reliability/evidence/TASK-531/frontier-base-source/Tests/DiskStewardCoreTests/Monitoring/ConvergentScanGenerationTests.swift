import Foundation
import XCTest
@testable import DiskStewardCore

final class DirectoryMetadataScannerConvergentScanGenerationTests: XCTestCase, @unchecked Sendable {
    func testGenerationScopeReentryUsesFreshBaselineWithoutPhantomChanges() async throws {
        for reentry in ["same", "replacement", "absent"] {
            let fixture = try ConvergentScanFixture()
            try fixture.write("A", bytes: 3)
            let other = fixture.directory.appending(path: "other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let watchPolicy = fixture.policy(maximumEntries: 1)
            let otherPolicy = MonitoringPolicy(watchedRoots: [other], maximumEntries: 1, maximumDepth: 8)
            let start = Date(timeIntervalSince1970: 2_100_015_500)
            var store = try EvidenceStore(url: fixture.databaseURL)
            let baseline = try await Self.completeGeneration(store: store, policy: watchPolicy, start: start, snapshotBase: 4500)
            let old = try XCTUnwrap(baseline.currentFiles.first)
            let exit = try await Self.completeGeneration(store: store, policy: otherPolicy, start: start.addingTimeInterval(100), snapshotBase: 4510)
            XCTAssertEqual(exit.events.map(\.operation), [.scopeExit])
            if reentry != "same" {
                try FileManager.default.moveItem(at: fixture.root.appending(path: "A"), to: fixture.directory.appending(path: "retired-A"))
                if reentry == "replacement" { try fixture.write("A", bytes: 7) }
            } else {
                let file = try FileHandle(forWritingTo: fixture.root.appending(path: "A"))
                try file.truncate(atOffset: 7)
                try file.close()
            }
            await store.close()
            store = try EvidenceStore(url: fixture.databaseURL)
            for index in 0...1 {
                let result = try await Self.completeGeneration(store: store, policy: watchPolicy,
                    start: start.addingTimeInterval(Double(200 + index * 100)), snapshotBase: 4530 + index * 10)
                XCTAssertEqual(result.events.map(\.operation), index == 0 && reentry != "absent" ? [.scopeEnter] : [], reentry)
                XCTAssertEqual(result.events.reduce(0) { $0 + $1.logicalDelta }, 0, reentry)
                let present = result.currentFiles.filter { $0.presence == .present }
                XCTAssertEqual(present.count, reentry == "absent" ? 0 : 1)
                if reentry == "same" { XCTAssertEqual(present.first?.objectID, old.objectID) }
                if reentry == "replacement" {
                    XCTAssertNotEqual(present.first?.objectID, old.objectID)
                    XCTAssertFalse(result.currentFiles.contains { $0.objectID == old.objectID })
                }
            }
            if reentry == "replacement" {
                // The old object is still alive outside scope. Once its old
                // current row yielded the occupied path, history must still
                // prevent a later sighting from becoming invented creation.
                try FileManager.default.moveItem(at: fixture.directory.appending(path: "retired-A"), to: fixture.root.appending(path: "B"))
                let returned = try await Self.completeGeneration(store: store, policy: watchPolicy,
                    start: start.addingTimeInterval(400), snapshotBase: 4570)
                XCTAssertEqual(returned.events.map(\.operation), [.scopeEnter])
                XCTAssertEqual(returned.events.reduce(0) { $0 + $1.logicalDelta }, 0)
                XCTAssertEqual(returned.currentFiles.first { $0.objectID == old.objectID }?.path, fixture.root.appending(path: "B").path)
            }
            let db = try SQLiteConnection(url: fixture.databaseURL)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM file_objects WHERE lifecycle_state = 'deleted'"), 0)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM change_events WHERE operation IN ('replace','delete','modify','truncate')"), 0)
            db.close()
            await store.close()
        }
    }

    func testAllFailedRootsPublishUncertaintyAndRecoverWithoutFalseDeletion() async throws {
        for rootCount in [1, 2] {
            for checkpoint in [nil, "after-observation", "after-present-objects", "after-missing-objects", "before-finalize"] {
                try await assertAllFailedRoots(rootCount: rootCount, interruptedAt: checkpoint)
            }
        }
    }

    private func assertAllFailedRoots(rootCount: Int, interruptedAt: String?) async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 3)
        var roots = [fixture.root]
        if rootCount == 2 {
            let second = fixture.directory.appending(path: "second")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try Data([1]).write(to: second.appending(path: "B"))
            roots.append(second)
        }
        let policy = MonitoringPolicy(watchedRoots: roots, maximumEntries: 4, maximumDepth: 8)
        let start = Date(timeIntervalSince1970: 2_100_015_000)
        let arm = ReconciliationCheckpointArm()
        var store = try EvidenceStore(url: fixture.databaseURL, reconciliationCheckpoint: arm.check)
        let baseline = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 4400)
        let old = try XCTUnwrap(baseline.currentFiles.first)
        for root in roots { try FileManager.default.moveItem(at: root, to: root.appendingPathExtension("offline")) }
        let scope = policy.scopeVersion(at: start)
        let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start.addingTimeInterval(100))
        let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(101))
        if let interruptedAt {
            arm.value = interruptedAt
            do {
                _ = try await store.recordScanSlice(snapshot: Self.snapshot(4410), slice: slice, scope: scope, trigger: .scheduled)
                XCTFail("Expected injected publication interruption.")
            } catch ReconciliationCheckpointFailure.injected {}
            let current = try await store.currentFiles(includeNonActionable: true)
            XCTAssertEqual(current, baseline.currentFiles)
            let db = try SQLiteConnection(url: fixture.databaseURL)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM observation_runs WHERE observation_id = '\(generation.generationID)'"), 0)
            db.close()
        }
        let result = try await store.recordScanSlice(snapshot: Self.snapshot(4410), slice: slice, scope: scope, trigger: .scheduled)
        XCTAssertEqual(result.generation.status, .completed, "Traversal ended; failed coverage must still publish its uncertainty.")
        XCTAssertNotNil(result.observation)
        XCTAssertTrue(result.observation?.events.isEmpty == true)
        let failedGaps = result.observation?.coverageGaps ?? []
        XCTAssertTrue(failedGaps.contains { $0.rootPath == fixture.root.path && $0.endedAt == nil })
        for reopen in [false, true] {
            if reopen { await store.close(); store = try EvidenceStore(url: fixture.databaseURL) }
            let rows = try await store.currentFiles(includeNonActionable: true)
            XCTAssertEqual(rows.count, rootCount)
            XCTAssertTrue(rows.allSatisfy { $0.presence == .unknown && !$0.actionable })
            let retained = try XCTUnwrap(rows.first { $0.objectID == old.objectID })
            XCTAssertEqual(retained.presence, .unknown)
            XCTAssertFalse(retained.actionable)
            XCTAssertEqual(retained.observedAt, old.observedAt)
            XCTAssertEqual(retained.stateAsOfObservationID, old.stateAsOfObservationID)
            let actionable = try await store.currentFiles()
            XCTAssertTrue(actionable.isEmpty)
            let coverage = try await store.scanCoverageStatus()
            XCTAssertEqual(coverage?.detailCoverage, "unavailable")
        }
        for root in roots { try FileManager.default.moveItem(at: root.appendingPathExtension("offline"), to: root) }
        let recovered = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(200), snapshotBase: 4420)
        XCTAssertEqual(recovered.currentFiles.count, rootCount)
        XCTAssertEqual(recovered.currentFiles.first?.presence, .present)
        XCTAssertTrue(recovered.currentFiles.first?.actionable == true)
        XCTAssertFalse(recovered.events.contains { $0.operation == .delete })
        XCTAssertFalse(recovered.coverageGaps.contains { $0.rootPath == fixture.root.path && $0.endedAt == nil })
        await store.close()
    }

    func testNewestHardLinkSampleWinsOverPreferredPathAcrossSlicesAndRestart() async throws {
        for reopen in [false, true] {
            let fixture = try ConvergentScanFixture()
            try fixture.write("A", bytes: 3)
            try FileManager.default.linkItem(at: fixture.root.appending(path: "A"), to: fixture.root.appending(path: "B"))
            let policy = fixture.policy(maximumEntries: 1)
            let baselinePolicy = fixture.policy(maximumEntries: 10)
            let start = Date(timeIntervalSince1970: 2_100_014_000)
            let scope = policy.scopeVersion(at: start)
            var store = try EvidenceStore(url: fixture.databaseURL)
            let sampledBaseline = DirectoryMetadataScanner().scan(policy: baselinePolicy, at: start)
            let baseline = MetadataSnapshot(observationID: "alias-baseline", scopeVersionID: scope.scopeVersionID,
                observedAt: start, entries: sampledBaseline.entries,
                rootCoverage: [.init(rootPath: fixture.root.path, coverage: .complete)], limitations: [])
            let first = try await store.recordObservation(snapshot: Self.snapshot(4100), metadata: baseline, scope: scope, trigger: .startup)
            XCTAssertEqual(first.currentFiles.first?.path, fixture.root.appending(path: "A").path)
            let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start.addingTimeInterval(100))
            let aSlice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(100))
            XCTAssertEqual(aSlice.entries.map(\.logicalBytes), [3])
            let aCommit = try await store.recordScanSlice(snapshot: Self.snapshot(4101), slice: aSlice, scope: scope, trigger: .scheduled)
            let handle = try FileHandle(forWritingTo: fixture.root.appending(path: "A"))
            try handle.truncate(atOffset: 8)
            try handle.close()
            let bSlice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: aCommit.generation, at: start.addingTimeInterval(110))
            let latest = try XCTUnwrap(bSlice.entries.first)
            XCTAssertEqual(latest.path, fixture.root.appending(path: "B").path)
            XCTAssertEqual(latest.objectID, aSlice.entries.first?.objectID)
            XCTAssertEqual(latest.logicalBytes, 8)
            _ = try await store.recordScanSlice(snapshot: Self.snapshot(4102), slice: bSlice, scope: scope, trigger: .scheduled)
            if reopen { await store.close(); store = try EvidenceStore(url: fixture.databaseURL) }
            let result = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(120), snapshotBase: 4110)
            let current = try XCTUnwrap(result.currentFiles.first)
            XCTAssertEqual(current.path, latest.path)
            XCTAssertEqual(current.logicalBytes, 8)
            XCTAssertEqual(current.observedAt, latest.observedAt)
            XCTAssertFalse(current.actionable)
            XCTAssertEqual(result.events.map(\.operation), [.modify])
            XCTAssertEqual(result.events.first?.logicalDelta, 5)
            XCTAssertEqual(result.events.first?.observedAt, latest.observedAt)
            let db = try SQLiteConnection(url: fixture.databaseURL)
            XCTAssertEqual(try db.scalarInt("SELECT observed_at FROM file_state_observations WHERE observation_id = '\(result.observationID)'"), Int64(latest.observedAt!.timeIntervalSince1970))
            XCTAssertEqual(try db.scalarInt("SELECT first_observed_at FROM file_objects"), Int64(start.timeIntervalSince1970))
            XCTAssertEqual(try db.scalarInt("SELECT last_observed_at FROM file_objects"), Int64(latest.observedAt!.timeIntervalSince1970))
            db.close()
            await store.close()
        }
    }

    func testRenameAndGrowthRetainDistinctPositiveAndAbsenceBounds() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 3)
        try fixture.write("Z", bytes: 1)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_014_200)
        let store = try EvidenceStore(url: fixture.databaseURL)
        let baseline = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 4200)
        let old = try XCTUnwrap(baseline.currentFiles.first { $0.path == fixture.root.appending(path: "A").path })
        try FileManager.default.moveItem(at: fixture.root.appending(path: "A"), to: fixture.root.appending(path: "B"))
        let handle = try FileHandle(forWritingTo: fixture.root.appending(path: "B"))
        try handle.truncate(atOffset: 8)
        try handle.close()
        let scope = policy.scopeVersion(at: start)
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start.addingTimeInterval(100))
        var sample: FileMetadata?
        var proof: MetadataScanDirectoryPass?
        var published: ObservationCommitResult?
        for index in 0..<20 {
            let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(Double(100 + index * 10)))
            sample = slice.entries.first { $0.objectID == old.objectID } ?? sample
            proof = slice.directoryPasses.first { $0.directoryPath == fixture.root.path } ?? proof
            let commit = try await store.recordScanSlice(snapshot: Self.snapshot(4230 + index), slice: slice, scope: scope, trigger: .scheduled)
            generation = commit.generation
            if let result = commit.observation { published = result; break }
        }
        let result = try XCTUnwrap(published)
        let sampledAt = try XCTUnwrap(sample?.observedAt)
        let absenceAt = try XCTUnwrap(proof?.completedAt)
        let rename = try XCTUnwrap(result.events.first { $0.operation == .rename })
        let growth = try XCTUnwrap(result.events.first { $0.operation == .modify })
        XCTAssertEqual(rename.observedAt, max(sampledAt, absenceAt))
        XCTAssertEqual(growth.observedAt, sampledAt)
        XCTAssertGreaterThan(rename.observedAt, growth.observedAt)
        XCTAssertEqual(growth.logicalDelta, 5)
        let db = try SQLiteConnection(url: fixture.databaseURL)
        for event in [rename, growth] {
            XCTAssertEqual(try db.scalarInt("SELECT occurred_start FROM change_events WHERE event_id = '\(event.eventID)'"), Int64(old.observedAt.timeIntervalSince1970))
            XCTAssertEqual(try db.scalarInt("SELECT occurred_end FROM change_events WHERE event_id = '\(event.eventID)'"), Int64(event.observedAt.timeIntervalSince1970))
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM file_state_observations WHERE observation_id = '\(result.observationID)'"), 1)
        db.close()
        await store.close()
    }

    func testSampleTimesSurviveDelayedPublicationAcrossEvidenceTables() async throws {
        let fixture = try ConvergentScanFixture()
        for name in ["A", "B", "C"] { try fixture.write(name, bytes: 1) }
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_012_000)
        let scope = policy.scopeVersion(at: start)
        let store = try EvidenceStore(url: fixture.databaseURL)
        let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start)
        let sampled = try XCTUnwrap(slice.entries.first)
        _ = try await store.recordScanSlice(snapshot: Self.snapshot(3100), slice: slice, scope: scope, trigger: .startup)
        let result = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(100), snapshotBase: 3110)
        XCTAssertEqual(result.currentFiles.first { $0.objectID == sampled.objectID }?.observedAt, start)
        XCTAssertEqual(result.events.first { $0.path == sampled.path }?.observedAt, start)
        let db = try SQLiteConnection(url: fixture.databaseURL)
        let object = sampled.objectID
        let t = Int64(start.timeIntervalSince1970)
        XCTAssertEqual(try db.scalarInt("SELECT first_observed_at FROM file_objects WHERE object_id = '\(object)'"), t)
        XCTAssertEqual(try db.scalarInt("SELECT last_observed_at FROM file_objects WHERE object_id = '\(object)'"), t)
        XCTAssertEqual(try db.scalarInt("SELECT valid_from FROM path_bindings WHERE object_id = '\(object)'"), t)
        XCTAssertEqual(try db.scalarInt("SELECT observed_at FROM file_state_observations WHERE object_id = '\(object)'"), t)
        XCTAssertEqual(try db.scalarInt("SELECT occurred_end FROM change_events WHERE object_id = '\(object)'"), t)
        XCTAssertGreaterThan(try db.scalarInt("SELECT detected_at FROM change_events WHERE object_id = '\(object)'"), t)
        db.close()
        await store.close()
    }

    func testAbsenceTimeComesFromCoveringPassNotLaterPublication() async throws {
        for removeParent in [false, true] {
            let fixture = try ConvergentScanFixture()
            for name in ["a", "z"] {
                try FileManager.default.createDirectory(at: fixture.root.appending(path: name), withIntermediateDirectories: true)
                try fixture.write("\(name)/file", bytes: 1)
            }
            let policy = fixture.policy(maximumEntries: 1)
            let start = Date(timeIntervalSince1970: 2_100_012_200)
            let store = try EvidenceStore(url: fixture.databaseURL)
            let baseline = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 3200)
            let old = try XCTUnwrap(baseline.currentFiles.first { $0.path == fixture.root.appending(path: "a/file").path })
            try FileManager.default.removeItem(at: fixture.root.appending(path: removeParent ? "a" : "a/file"))
            let scope = policy.scopeVersion(at: start.addingTimeInterval(100))
            var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start.addingTimeInterval(100))
            let coveringDirectory = removeParent ? fixture.root.path : fixture.root.appending(path: "a").path
            var absencePass: MetadataScanDirectoryPass?
            var published: ObservationCommitResult?
            for index in 0 ..< 40 {
                let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(Double(100 + index * 10)))
                if let pass = slice.directoryPasses.first(where: { $0.directoryPath == coveringDirectory }) { absencePass = pass }
                let commit = try await store.recordScanSlice(snapshot: Self.snapshot(3230 + index), slice: slice, scope: scope, trigger: .scheduled)
                generation = commit.generation
                if let observation = commit.observation { published = observation; break }
            }
            let result = try XCTUnwrap(published)
            let proof = try XCTUnwrap(absencePass)
            let event = try XCTUnwrap(result.events.first { $0.operation == .delete && $0.path == old.path })
            XCTAssertLessThan(proof.completedAt, try XCTUnwrap(generation.completedAt))
            XCTAssertEqual(event.observedAt, proof.completedAt)
            let db = try SQLiteConnection(url: fixture.databaseURL)
            let t = Int64(proof.completedAt.timeIntervalSince1970)
            XCTAssertEqual(try db.scalarInt("SELECT valid_through FROM path_bindings WHERE object_id = '\(old.objectID)'"), t)
            XCTAssertEqual(try db.scalarInt("SELECT last_observed_at FROM file_objects WHERE object_id = '\(old.objectID)'"), t)
            XCTAssertEqual(try db.scalarInt("SELECT occurred_end FROM change_events WHERE event_id = '\(event.eventID)'"), t)
            XCTAssertEqual(try db.scalarInt("SELECT occurred_start FROM change_events WHERE event_id = '\(event.eventID)'"), Int64(old.observedAt.timeIntervalSince1970))
            XCTAssertGreaterThan(try db.scalarInt("SELECT detected_at FROM change_events WHERE event_id = '\(event.eventID)'"), t)
            db.close()
            await store.close()
        }
    }

    func testFinalDirectoryBatchIsRevalidatedBeforePublishingStagedMembership() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 1)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_008_000)
        let scope = policy.scopeVersion(at: start)
        let store = try EvidenceStore(url: fixture.databaseURL)
        let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start)
        XCTAssertEqual(slice.entries.map(\.path), fixture.paths(["A"]))
        let first = try await store.recordScanSlice(snapshot: Self.snapshot(1100), slice: slice, scope: scope, trigger: .startup)
        XCTAssertNil(first.observation)
        try FileManager.default.removeItem(at: fixture.root.appending(path: "A"))
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(5)], ofItemAtPath: fixture.root.path)
        let result = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(10), snapshotBase: 1101)
        XCTAssertTrue(result.currentFiles.isEmpty, "The last staged name was deleted before completion.")
        await store.close()
    }

    func testCompletedNestedDirectoryIsRevalidatedWhileAnotherDirectoryIsStillScanning() async throws {
        let fixture = try ConvergentScanFixture()
        for name in ["a", "z"] {
            try FileManager.default.createDirectory(at: fixture.root.appending(path: name), withIntermediateDirectories: true)
        }
        try fixture.write("a/A", bytes: 1)
        for name in ["B", "C", "D"] { try fixture.write("z/\(name)", bytes: 1) }
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_008_100)
        let scope = policy.scopeVersion(at: start)
        let store = try EvidenceStore(url: fixture.databaseURL)
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        var reachedOtherDirectory = false
        for index in 0 ..< 20 {
            let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(Double(index)))
            let commit = try await store.recordScanSlice(snapshot: Self.snapshot(1200 + index), slice: slice, scope: scope, trigger: .startup)
            generation = commit.generation
            if slice.entries.contains(where: { $0.path == fixture.root.appending(path: "z/B").path }) {
                XCTAssertNil(commit.observation)
                reachedOtherDirectory = true
                break
            }
        }
        XCTAssertTrue(reachedOtherDirectory)
        try FileManager.default.removeItem(at: fixture.root.appending(path: "a/A"))
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(30)], ofItemAtPath: fixture.root.appending(path: "a").path)
        let result = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(40), snapshotBase: 1230)
        XCTAssertEqual(result.currentFiles.map(\.path).sorted(), fixture.paths(["z/B", "z/C", "z/D"]))
        await store.close()
    }

    func testInterruptedPublicationDoesNotReplayCompletedStagingWithoutRevalidation() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 1)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_008_200)
        let arm = ReconciliationCheckpointArm()
        arm.value = "before-finalize"
        let store = try EvidenceStore(url: fixture.databaseURL, reconciliationCheckpoint: { try arm.check($0) })
        do {
            _ = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 1300)
            XCTFail("Expected publication to be interrupted.")
        } catch ReconciliationCheckpointFailure.injected {}
        await store.close()
        try FileManager.default.removeItem(at: fixture.root.appending(path: "A"))
        try fixture.write("B", bytes: 2)
        let reopened = try EvidenceStore(url: fixture.databaseURL)
        let result = try await Self.completeGeneration(store: reopened, policy: policy, start: start.addingTimeInterval(100), snapshotBase: 1330)
        XCTAssertEqual(result.currentFiles.map(\.path), fixture.paths(["B"]))
        await reopened.close()
    }

    func testLegacyCursorWithoutSignatureRestartsRatherThanSkippingEarlierNames() throws {
        let fixture = try ConvergentScanFixture()
        for name in ["A", "B", "C"] { try fixture.write(name, bytes: 1) }
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_008_300)
        let scope = policy.scopeVersion(at: start)
        let generation = MetadataScanGeneration(
            generationID: "legacy-unproven-pass", scopeVersionID: scope.scopeVersionID,
            rootPaths: scope.rootPaths, excludedPaths: scope.excludedPaths, status: .active,
            roots: [.init(rootPath: fixture.root.path, status: .active,
                          frontier: [.init(directoryPath: fixture.root.path, depth: 0, afterName: "B")])],
            processedEntryCount: 1, stagedFileCount: 1, startedAt: start, updatedAt: start
        )
        let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(1))
        XCTAssertEqual(slice.entries.map(\.path), fixture.paths(["A"]))
        XCTAssertEqual(slice.invalidatedDirectories, [fixture.root.path])
    }

    func testPassValidationRestartsFromTheBeginningAfterDatabaseReopen() async throws {
        let fixture = try ConvergentScanFixture()
        for name in ["a", "z"] {
            try FileManager.default.createDirectory(at: fixture.root.appending(path: name), withIntermediateDirectories: true)
            try fixture.write("\(name)/file", bytes: 1)
        }
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_009_000)
        let scope = policy.scopeVersion(at: start)
        let store = try EvidenceStore(url: fixture.databaseURL)
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        var validationSlices = 0
        for index in 0 ..< 30 {
            let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(Double(index)))
            let commit = try await store.recordScanSlice(snapshot: Self.snapshot(1500 + index), slice: slice, scope: scope, trigger: .startup)
            generation = commit.generation
            if generation.status == .active, generation.roots.allSatisfy({ $0.status == .completed }) {
                validationSlices += 1
                if validationSlices == 2 { break } // root, then a, were validated; z remains.
            }
        }
        XCTAssertEqual(validationSlices, 2)
        await store.close()
        try FileManager.default.removeItem(at: fixture.root.appending(path: "a/file"))
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(40)], ofItemAtPath: fixture.root.appending(path: "a").path)
        let reopened = try EvidenceStore(url: fixture.databaseURL)
        let result = try await Self.completeGeneration(store: reopened, policy: policy, start: start.addingTimeInterval(50), snapshotBase: 1540)
        XCTAssertEqual(result.currentFiles.map(\.path), fixture.paths(["z/file"]))
        await reopened.close()
    }

    func testDirtySignalDuringValidationFencesInflightSliceAndSurvivesRestart() async throws {
        for reopen in [false, true] {
            let fixture = try ConvergentScanFixture()
            for name in ["a", "z"] {
                try FileManager.default.createDirectory(at: fixture.root.appending(path: name), withIntermediateDirectories: true)
                try fixture.write("\(name)/file", bytes: 1)
            }
            let policy = fixture.policy(maximumEntries: 1)
            let start = Date(timeIntervalSince1970: 2_100_012_600)
            let scope = policy.scopeVersion(at: start)
            var store = try EvidenceStore(url: fixture.databaseURL)
            // Earlier loss must remain the gap start even when a repeated
            // coalesced signal arrives while this generation is finishing.
            try await store.recordReconciliationInvalidation(at: start.addingTimeInterval(-10))
            var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
            var validationSlices = 0
            for index in 0 ..< 30 {
                let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(Double(index)))
                let commit = try await store.recordScanSlice(snapshot: Self.snapshot(3400 + index), slice: slice, scope: scope, trigger: .scheduled)
                generation = commit.generation
                if generation.status == .active, generation.roots.allSatisfy({ $0.status == .completed }) {
                    validationSlices += 1
                    if validationSlices == 2 { break }
                }
            }
            XCTAssertEqual(validationSlices, 2, "a was already validated; only z is left.")
            let inflight = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(40))
            try FileManager.default.removeItem(at: fixture.root.appending(path: "a/file"))
            try await store.recordReconciliationInvalidation(at: start.addingTimeInterval(41))
            let lateCommit = try await store.recordScanSlice(snapshot: Self.snapshot(3440), slice: inflight, scope: scope, trigger: .scheduled)
            XCTAssertNil(lateCommit.observation, "A slice captured before new dirty evidence cannot publish or resolve that evidence.")
            let pending = try await store.hasPendingReconciliation()
            XCTAssertTrue(pending)
            if reopen {
                await store.close()
                store = try EvidenceStore(url: fixture.databaseURL)
            }
            let result = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(50), snapshotBase: 3450)
            XCTAssertEqual(result.currentFiles.map(\.path), fixture.paths(["z/file"]))
            XCTAssertEqual(result.coverageGaps.first { $0.reason == "event-drop" }?.startedAt, start.addingTimeInterval(-10))
            let pendingAfter = try await store.hasPendingReconciliation()
            XCTAssertFalse(pendingAfter)
            await store.close()
        }
    }

    func testUnsignalledMutationAfterValidationRetainsOriginalSampleTimeAndNextScanCorrectsIt() async throws {
        let fixture = try ConvergentScanFixture()
        for name in ["a", "z"] {
            try FileManager.default.createDirectory(at: fixture.root.appending(path: name), withIntermediateDirectories: true)
            try fixture.write("\(name)/file", bytes: 1)
        }
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_012_800)
        let scope = policy.scopeVersion(at: start)
        let store = try EvidenceStore(url: fixture.databaseURL)
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        var validationSlices = 0
        var sampledAt: Date?
        for index in 0 ..< 30 {
            let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(Double(index)))
            if let file = slice.entries.first(where: { $0.path == fixture.root.appending(path: "a/file").path }) { sampledAt = file.observedAt }
            let commit = try await store.recordScanSlice(snapshot: Self.snapshot(3500 + index), slice: slice, scope: scope, trigger: .scheduled)
            generation = commit.generation
            if generation.status == .active, generation.roots.allSatisfy({ $0.status == .completed }) {
                validationSlices += 1
                if validationSlices == 2 { break }
            }
        }
        XCTAssertEqual(validationSlices, 2)
        try FileManager.default.removeItem(at: fixture.root.appending(path: "a/file"))
        let result = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(50), snapshotBase: 3540)
        let priorPresence = try XCTUnwrap(result.currentFiles.first { $0.path == fixture.root.appending(path: "a/file").path })
        XCTAssertEqual(priorPresence.observedAt, try XCTUnwrap(sampledAt), "An interval scan cannot promise an atomic filesystem snapshot.")
        XCTAssertEqual(result.events.first { $0.path == priorPresence.path }?.observedAt, sampledAt)
        let next = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(100), snapshotBase: 3560)
        XCTAssertEqual(next.currentFiles.map(\.path), fixture.paths(["z/file"]))
        XCTAssertEqual(next.events.filter { $0.operation == .delete }.map(\.path), [priorPresence.path])
        await store.close()
    }

    func testRootSpecificDirtySignalPreservesIndependentStagingAndFencesEqualTimestampSlice() async throws {
        let fixture = try ConvergentScanFixture()
        let dirty = fixture.root.appending(path: "a")
        let healthy = fixture.root.appending(path: "z")
        for root in [dirty, healthy] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data([1]).write(to: root.appending(path: "file"))
        }
        let policy = MonitoringPolicy(watchedRoots: [dirty, healthy], maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_013_000)
        let scope = policy.scopeVersion(at: start)
        let store = try EvidenceStore(url: fixture.databaseURL)
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        var sampledRoots: Set<String> = []
        for index in 0 ..< 4 {
            let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start)
            sampledRoots.formUnion(slice.entries.map(\.rootPath))
            let commit = try await store.recordScanSlice(snapshot: Self.snapshot(3600 + index), slice: slice, scope: scope, trigger: .scheduled)
            generation = commit.generation
            if sampledRoots.count == 2 { break }
        }
        XCTAssertEqual(sampledRoots, Set([dirty.path, healthy.path]))
        let inflight = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start)
        try FileManager.default.removeItem(at: dirty.appending(path: "file"))
        try await store.recordReconciliationInvalidation(rootPath: dirty.path, reason: "changed", at: start)
        let db = try SQLiteConnection(url: fixture.databaseURL)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM scan_generation_entries WHERE root_path = '\(healthy.path)'"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM scan_generation_entries WHERE root_path = '\(dirty.path)'"), 0)
        let fenced = try await store.recordScanSlice(snapshot: Self.snapshot(3610), slice: inflight, scope: scope, trigger: .scheduled)
        XCTAssertNil(fenced.observation)
        XCTAssertNotEqual(fenced.generation.reconciliationToken, generation.reconciliationToken)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM scan_generation_entries WHERE root_path = '\(healthy.path)'"), 1)
        db.close()
        let result = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(100), snapshotBase: 3620)
        XCTAssertEqual(result.currentFiles.map(\.path), [healthy.appending(path: "file").path])
        let pending = try await store.hasPendingReconciliation()
        XCTAssertFalse(pending)
        await store.close()
    }

    func testPartialGenerationDoesNotResolveGlobalDirtyCoverage() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 1)
        let missing = fixture.directory.appending(path: "unavailable")
        let policy = MonitoringPolicy(watchedRoots: [fixture.root, missing], maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_013_100)
        let store = try EvidenceStore(url: fixture.databaseURL)
        try await store.recordReconciliationInvalidation(at: start)
        let result = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(1), snapshotBase: 3700)
        XCTAssertEqual(result.currentFiles.map(\.path), fixture.paths(["A"]))
        let pending = try await store.hasPendingReconciliation()
        XCTAssertTrue(pending)
        XCTAssertNil(try XCTUnwrap(result.coverageGaps.first { $0.reason == "event-drop" }).endedAt)
        await store.close()
    }

    func testAncestorDirtySignalResolvesOnlyWhenAllIntersectingRootsComplete() async throws {
        for secondRootAvailable in [true, false] {
            let fixture = try ConvergentScanFixture()
            let first = fixture.root.appending(path: "a")
            let second = fixture.root.appending(path: "z")
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            try Data([1]).write(to: first.appending(path: "file"))
            if secondRootAvailable {
                try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
                try Data([1]).write(to: second.appending(path: "file"))
            }
            let policy = MonitoringPolicy(watchedRoots: [first, second], maximumEntries: 1)
            let start = Date(timeIntervalSince1970: 2_100_013_200)
            let store = try EvidenceStore(url: fixture.databaseURL)
            _ = try await store.beginOrResumeScanGeneration(scope: policy.scopeVersion(at: start), at: start)
            try await store.recordReconciliationInvalidation(rootPath: fixture.root.path, at: start)
            _ = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(1), snapshotBase: 3800)
            let pending = try await store.hasPendingReconciliation()
            XCTAssertEqual(pending, !secondRootAvailable, "Resolution must cover the same intersecting root set as invalidation.")
            await store.close()
        }
    }

    func testReplayedFSEventGapDoesNotResetProgressOrReopenResolvedGap() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 1)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_013_300)
        let store = try EvidenceStore(url: fixture.databaseURL)
        let baseline = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 3900)
        let scope = policy.scopeVersion(at: start)
        _ = try await store.beginOrResumeScanGeneration(scope: scope, at: start.addingTimeInterval(100))
        let hint = TargetedChangeHint(path: fixture.root.appending(path: "A").path, eventID: 77,
            observedAt: start.addingTimeInterval(101), kind: .modified, requiresRescan: true)
        let batch = TargetedChangeBatch(hints: [hint], eventGap: true, limitations: ["delivery gap"])
        try await store.recordFSEvents(.init(hints: [hint], eventGap: false, limitations: batch.limitations), observationID: baseline.observationID)
        let beforeGap = try await store.hasPendingReconciliation()
        XCTAssertFalse(beforeGap)
        try await store.recordFSEvents(batch, observationID: baseline.observationID)
        let afterGap = try await store.hasPendingReconciliation()
        XCTAssertTrue(afterGap, "A newly declared gap cannot be ignored just because its hint was stored earlier.")
        let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start.addingTimeInterval(102))
        let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(102))
        let commit = try await store.recordScanSlice(snapshot: Self.snapshot(3930), slice: slice, scope: scope, trigger: .scheduled)
        XCTAssertNil(commit.observation)
        try await store.recordFSEvents(batch, observationID: baseline.observationID)
        let afterReplay = try await store.beginOrResumeScanGeneration(scope: scope, at: start.addingTimeInterval(103))
        XCTAssertEqual(afterReplay.reconciliationToken, commit.generation.reconciliationToken)
        XCTAssertEqual(afterReplay.stagedFileCount, 1)
        _ = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(104), snapshotBase: 3940)
        try await store.recordFSEvents(batch, observationID: baseline.observationID)
        let pending = try await store.hasPendingReconciliation()
        XCTAssertFalse(pending, "Replaying already persisted evidence is not a new dirty signal.")
        await store.close()
    }

    func testOverlappingRootsSharePhysicalDirectoryProofWithoutLosingCoverage() async throws {
        let fixture = try ConvergentScanFixture()
        let nested = fixture.root.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try fixture.write("nested/A", bytes: 1)
        let policy = MonitoringPolicy(watchedRoots: [fixture.root, nested], maximumEntries: 1)
        let store = try EvidenceStore(url: fixture.databaseURL)
        let result = try await Self.completeGeneration(store: store, policy: policy, start: Date(timeIntervalSince1970: 2_100_009_100), snapshotBase: 1600)
        XCTAssertEqual(result.currentFiles.map(\.path), fixture.paths(["nested/A"]))
        let coverage = try await store.scanCoverageStatus()
        XCTAssertEqual(coverage?.detailCoverage, "complete")
        await store.close()
    }

    func testFreshOverlappingPassCannotInheritSupersededMembership() async throws {
        let fixture = try ConvergentScanFixture()
        let nested = fixture.root.appending(path: "a")
        for name in ["a", "z"] {
            try FileManager.default.createDirectory(at: fixture.root.appending(path: name), withIntermediateDirectories: true)
        }
        try fixture.write("a/A", bytes: 1)
        let policy = MonitoringPolicy(watchedRoots: [fixture.root, nested], maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_009_400)
        let scope = policy.scopeVersion(at: start)
        let store = try EvidenceStore(url: fixture.databaseURL)
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        var descendantStagedFirst = false
        for index in 0 ..< 10 {
            let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(Double(index)))
            let commit = try await store.recordScanSlice(snapshot: Self.snapshot(1800 + index), slice: slice, scope: scope, trigger: .startup)
            generation = commit.generation
            if slice.entries.contains(where: { $0.rootPath == nested.path && $0.path == nested.appending(path: "A").path }) {
                descendantStagedFirst = true
                break
            }
        }
        XCTAssertTrue(descendantStagedFirst)
        try FileManager.default.removeItem(at: nested.appending(path: "A"))
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(30)], ofItemAtPath: nested.path)
        let result = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(40), snapshotBase: 1830)
        XCTAssertTrue(result.currentFiles.isEmpty, "A new empty pass must not authorize A from the superseded overlapping pass.")
        await store.close()
    }

    func testCompletedGenerationsDoNotRetainTransientDirectoryProofs() async throws {
        let fixture = try ConvergentScanFixture()
        for index in 0 ..< 12 {
            try FileManager.default.createDirectory(at: fixture.root.appending(path: "empty-\(index)"), withIntermediateDirectories: true)
        }
        let policy = fixture.policy(maximumEntries: 3)
        let start = Date(timeIntervalSince1970: 2_100_009_500)
        let store = try EvidenceStore(url: fixture.databaseURL)
        for cycle in 0 ..< 10 {
            _ = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(Double(cycle * 100)), snapshotBase: 1900 + cycle * 100)
            let inspection = try SQLiteConnection(url: fixture.databaseURL)
            XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM scan_directory_passes"), 0,
                "Directory membership proofs are temporary publication inputs, not per-scan retained history.")
            inspection.close()
        }
        await store.close()
    }

    func testFailedAncestorDoesNotEraseSuccessfulDescendantContribution() async throws {
        let fixture = try ConvergentScanFixture()
        let nested = fixture.root.appending(path: "a")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "z/too-deep"), withIntermediateDirectories: true)
        try fixture.write("a/A", bytes: 3)
        let policy = MonitoringPolicy(watchedRoots: [fixture.root, nested], maximumEntries: 1, maximumDepth: 1)
        let start = Date(timeIntervalSince1970: 2_100_010_000)
        let scope = policy.scopeVersion(at: start)
        let store = try EvidenceStore(url: fixture.databaseURL)
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        var emittingRoots: [String] = []
        var result: ObservationCommitResult?
        for index in 0 ..< 50 {
            let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(Double(index)))
            emittingRoots.append(contentsOf: slice.entries.filter { $0.path == nested.appending(path: "A").path }.map(\.rootPath))
            let commit = try await store.recordScanSlice(snapshot: Self.snapshot(2000 + index), slice: slice, scope: scope, trigger: .startup)
            generation = commit.generation
            if let observation = commit.observation { result = observation; break }
        }
        XCTAssertEqual(emittingRoots, [nested.path, fixture.root.path], "The failed ancestor must have been the last writer of the shared path.")
        let published = try XCTUnwrap(result)
        XCTAssertEqual(published.currentFiles.map(\.path), fixture.paths(["a/A"]))
        XCTAssertEqual(published.currentFiles.first?.rootPath, nested.path)
        XCTAssertEqual(generation.roots.first { $0.rootPath == fixture.root.path }?.status, .failed)
        XCTAssertEqual(generation.roots.first { $0.rootPath == nested.path }?.status, .completed)
        await store.close()
    }

    func testReplacingOneHardLinkPreservesOtherHealthyPathInBothObjectOrders() async throws {
        for originalComesFirst in [true, false] {
            for replaceCanonical in [true, false] {
                let fixture = try ConvergentScanFixture()
                try fixture.write("first", bytes: 3)
                try fixture.write("second", bytes: 5)
                let policy = fixture.policy(maximumEntries: 1)
                let identities = DirectoryMetadataScanner().scan(policy: fixture.policy(maximumEntries: 10)).entries.values.sorted { $0.objectID < $1.objectID }
                let original = identities[originalComesFirst ? 0 : 1]
                let incoming = identities[originalComesFirst ? 1 : 0]
                let held = fixture.directory.appending(path: "incoming")
                try FileManager.default.moveItem(atPath: incoming.path, toPath: held.path)
                try FileManager.default.moveItem(atPath: original.path, toPath: fixture.root.appending(path: "A").path)
                try FileManager.default.linkItem(at: fixture.root.appending(path: "A"), to: fixture.root.appending(path: "B"))
                let start = Date(timeIntervalSince1970: 2_100_010_100)
                let store = try EvidenceStore(url: fixture.databaseURL)
                _ = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 2100)
                let replacedPath = fixture.root.appending(path: replaceCanonical ? "A" : "B")
                try FileManager.default.removeItem(at: replacedPath)
                try FileManager.default.moveItem(at: held, to: replacedPath)
                let result = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(100), snapshotBase: 2130)
                XCTAssertEqual(result.currentFiles.count, 2)
                XCTAssertEqual(result.currentFiles.first { $0.objectID == original.objectID }?.path, fixture.root.appending(path: replaceCanonical ? "B" : "A").path)
                XCTAssertEqual(result.currentFiles.first { $0.objectID == incoming.objectID }?.path, replacedPath.path)
                XCTAssertTrue(result.currentFiles.allSatisfy { $0.presence == .present })
                XCTAssertFalse(result.events.contains { $0.operation == .delete })
                XCTAssertEqual(result.currentFiles.reduce(0) { $0 + $1.logicalBytes }, original.logicalBytes + incoming.logicalBytes)
                XCTAssertEqual(result.events.filter { $0.operation == .replace }.count, 1)
                XCTAssertEqual(result.events.reduce(0) { $0 + $1.logicalDelta }, incoming.logicalBytes,
                    "The original object still exists through its other hard link; replacement must not subtract its bytes.")
                let inspection = try SQLiteConnection(url: fixture.databaseURL)
                let recordedPath = try inspection.scalarText("SELECT path_before FROM change_events WHERE after_observation_id = '\(result.observationID)' AND object_id = '\(incoming.objectID)' AND operation = 'replace'")
                XCTAssertEqual(recordedPath, replacedPath.path, "Replacement provenance must name the replaced binding, not the old object's surviving canonical alias.")
                XCTAssertEqual(try inspection.scalarText("SELECT path_after FROM change_events WHERE after_observation_id = '\(result.observationID)' AND object_id = '\(incoming.objectID)' AND operation = 'replace'"), replacedPath.path)
                inspection.close()
                await store.close()
            }
        }
    }

    func testSwappedObjectPathsPublishAtomicallyWithoutUniquePathCollision() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 3)
        try fixture.write("B", bytes: 5)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_010_200)
        let store = try EvidenceStore(url: fixture.databaseURL)
        let baseline = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 2200)
        let held = fixture.directory.appending(path: "held")
        try FileManager.default.moveItem(at: fixture.root.appending(path: "A"), to: held)
        try FileManager.default.moveItem(at: fixture.root.appending(path: "B"), to: fixture.root.appending(path: "A"))
        try FileManager.default.moveItem(at: held, to: fixture.root.appending(path: "B"))
        let result = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(100), snapshotBase: 2230)
        XCTAssertEqual(result.currentFiles.count, 2)
        for old in baseline.currentFiles {
            let newName = old.path.hasSuffix("/A") ? "B" : "A"
            XCTAssertEqual(result.currentFiles.first { $0.objectID == old.objectID }?.path, fixture.root.appending(path: newName).path)
        }
        XCTAssertFalse(result.events.contains { $0.operation == .delete })
        await store.close()
    }

    func testOneOldHardLinkedObjectReplacedByTwoObjectsIsDebitedOnlyOnce() async throws {
        try await assertReplacementCardinality(oldHasTwoObjects: false)
    }

    func testTwoOldObjectsReplacedByOneHardLinkedObjectAreBothDebited() async throws {
        try await assertReplacementCardinality(oldHasTwoObjects: true)
    }

    private func assertReplacementCardinality(oldHasTwoObjects: Bool) async throws {
        for reversePlacement in [false, true] {
            let fixture = try ConvergentScanFixture()
            try fixture.write("A", bytes: 10)
            if oldHasTwoObjects { try fixture.write("B", bytes: 20) }
            else { try FileManager.default.linkItem(at: fixture.root.appending(path: "A"), to: fixture.root.appending(path: "B")) }
            let incoming1 = fixture.directory.appending(path: "incoming-1")
            let incoming2 = fixture.directory.appending(path: "incoming-2")
            try Data(repeating: 1, count: oldHasTwoObjects ? 30 : 20).write(to: incoming1)
            if oldHasTwoObjects { try FileManager.default.linkItem(at: incoming1, to: incoming2) }
            else { try Data(repeating: 2, count: 30).write(to: incoming2) }
            let policy = fixture.policy(maximumEntries: 1)
            let start = Date(timeIntervalSince1970: 2_100_010_300)
            let store = try EvidenceStore(url: fixture.databaseURL)
            let before = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 2300)
            for name in ["A", "B"] { try FileManager.default.removeItem(at: fixture.root.appending(path: name)) }
            try FileManager.default.moveItem(at: incoming1, to: fixture.root.appending(path: reversePlacement ? "B" : "A"))
            try FileManager.default.moveItem(at: incoming2, to: fixture.root.appending(path: reversePlacement ? "A" : "B"))
            let after = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(100), snapshotBase: 2330)
            XCTAssertEqual(before.currentFiles.count, oldHasTwoObjects ? 2 : 1)
            XCTAssertEqual(after.currentFiles.count, oldHasTwoObjects ? 1 : 2)
            XCTAssertTrue(Set(before.currentFiles.map(\.objectID)).isDisjoint(with: Set(after.currentFiles.map(\.objectID))))
            let physicalDelta = after.currentFiles.reduce(0) { $0 + $1.logicalBytes } - before.currentFiles.reduce(0) { $0 + $1.logicalBytes }
            XCTAssertEqual(after.events.reduce(0) { $0 + $1.logicalDelta }, physicalDelta,
                "Replacement cardinality must not multiply or omit a physical object's byte change.")
            let allocatedDelta = after.currentFiles.reduce(0) { $0 + $1.allocatedBytes } - before.currentFiles.reduce(0) { $0 + $1.allocatedBytes }
            XCTAssertEqual(after.events.reduce(0) { $0 + $1.allocatedDelta }, allocatedDelta)
            let inspection = try SQLiteConnection(url: fixture.databaseURL)
            XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM change_events WHERE after_observation_id = '\(after.observationID)' AND operation = 'replace' AND path_after IS NULL"), Int64(before.currentFiles.count),
                "Each retired object must have its own traceable replacement record, not only an aggregate byte correction.")
            inspection.close()
            await store.close()
        }
    }

    func testRenameOverExistingObjectAccountsForDisplacedBytes() async throws {
        for reverse in [false, true] {
            let fixture = try ConvergentScanFixture()
            try fixture.write("A", bytes: 10)
            try fixture.write("B", bytes: 20)
            let policy = fixture.policy(maximumEntries: 1)
            let start = Date(timeIntervalSince1970: 2_100_010_400)
            let store = try EvidenceStore(url: fixture.databaseURL)
            let before = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 2400)
            let source = fixture.root.appending(path: reverse ? "B" : "A")
            let destination = fixture.root.appending(path: reverse ? "A" : "B")
            let original = try XCTUnwrap(before.currentFiles.first { $0.path == source.path })
            let displaced = try XCTUnwrap(before.currentFiles.first { $0.path == destination.path })
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: source, to: destination)
            let after = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(100), snapshotBase: 2430)
            XCTAssertEqual(after.currentFiles.map(\.objectID), [original.objectID])
            XCTAssertEqual(after.currentFiles.first?.path, destination.path)
            XCTAssertEqual(after.events.reduce(0) { $0 + $1.logicalDelta }, -displaced.logicalBytes)
            XCTAssertEqual(after.events.reduce(0) { $0 + $1.allocatedDelta }, -displaced.allocatedBytes)
            await store.close()
        }
    }

    func testMoveAndGrowthRetainBothIdentityAndByteChange() async throws {
        try await assertPathChangeAndGrowth(hardLinked: false)
    }

    func testSurvivingHardLinkRebaseAndGrowthDoesNotLoseByteChange() async throws {
        try await assertPathChangeAndGrowth(hardLinked: true)
    }

    private func assertPathChangeAndGrowth(hardLinked: Bool) async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 10)
        if hardLinked { try FileManager.default.linkItem(at: fixture.root.appending(path: "A"), to: fixture.root.appending(path: "B")) }
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_010_500)
        let store = try EvidenceStore(url: fixture.databaseURL)
        let before = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 2500)
        if hardLinked { try FileManager.default.removeItem(at: fixture.root.appending(path: "A")) }
        else { try FileManager.default.moveItem(at: fixture.root.appending(path: "A"), to: fixture.root.appending(path: "B")) }
        let handle = try FileHandle(forWritingTo: fixture.root.appending(path: "B"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(repeating: 1, count: 30))
        try handle.close()
        let after = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(100), snapshotBase: 2530)
        XCTAssertEqual(after.currentFiles.map(\.objectID), before.currentFiles.map(\.objectID))
        XCTAssertEqual(after.currentFiles.first?.path, fixture.root.appending(path: "B").path)
        XCTAssertEqual(after.currentFiles.first?.logicalBytes, 30)
        XCTAssertEqual(after.events.reduce(0) { $0 + $1.logicalDelta }, 20)
        if hardLinked { XCTAssertFalse(after.events.contains { $0.operation == .rename }) }
        await store.close()
    }

    func testEmptyDirectoryPassOutputIsBoundedBySliceBudget() throws {
        let fixture = try ConvergentScanFixture()
        for index in 0 ..< 30 {
            try FileManager.default.createDirectory(at: fixture.root.appending(path: "empty-\(index)"), withIntermediateDirectories: true)
        }
        let policy = fixture.policy(maximumEntries: 3)
        let start = Date(timeIntervalSince1970: 2_100_009_200)
        let scope = policy.scopeVersion(at: start)
        var generation = MetadataScanGeneration(generationID: "empty-directories", scopeVersionID: scope.scopeVersionID,
            rootPaths: scope.rootPaths, excludedPaths: scope.excludedPaths, status: .active,
            roots: [.init(rootPath: fixture.root.path)], processedEntryCount: 0, stagedFileCount: 0, startedAt: start, updatedAt: start)
        var passCount = 0
        for index in 0 ..< 50 where generation.status == .active {
            let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(Double(index)))
            XCTAssertLessThanOrEqual(slice.directoryPasses.count, 3)
            passCount += slice.directoryPasses.count
            generation = slice.generation
        }
        XCTAssertEqual(generation.status, .completed)
        XCTAssertEqual(passCount, 31)
    }

    func testLegacyUnpublishedGenerationIsAbandonedWithoutChangingCommittedTruth() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 1)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_009_300)
        let scope = policy.scopeVersion(at: start)
        let store = try EvidenceStore(url: fixture.databaseURL)
        let baseline = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 1700)
        let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start.addingTimeInterval(50))
        let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(51))
        _ = try await store.recordScanSlice(snapshot: Self.snapshot(1710), slice: slice, scope: scope, trigger: .scheduled)
        await store.close()
        // This is an old progress-payload compatibility test, not a substitute
        // for a genuine v5/v6 database migration fixture.
        let connection = try SQLiteConnection(url: fixture.databaseURL)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(slice.generation)) as? [String: Any])
        payload.removeValue(forKey: "passProvenanceVersion")
        payload.removeValue(forKey: "reconciliationToken")
        let legacy = try JSONSerialization.data(withJSONObject: payload)
        try connection.withStatement("UPDATE scan_generations SET progress = ? WHERE generation_id = ?") { statement in
            try connection.bind(legacy, at: 1, in: statement)
            try connection.bind(generation.generationID, at: 2, in: statement)
            try connection.stepDone(statement)
        }
        connection.close()
        let reopened = try EvidenceStore(url: fixture.databaseURL)
        let fresh = try await reopened.beginOrResumeScanGeneration(scope: scope, at: start.addingTimeInterval(100))
        XCTAssertNotEqual(fresh.generationID, generation.generationID)
        let current = try await reopened.currentFiles(includeNonActionable: true)
        XCTAssertEqual(current, baseline.currentFiles)
        let history = try await reopened.scanGenerations()
        XCTAssertEqual(history.first { $0.generationID == generation.generationID }?.status, .abandoned)
        await reopened.close()
    }

    func testHealthyHardLinkDoesNotCloseBindingInFailedRoot() async throws {
        try await assertFailedRootHardLink(removeHealthy: false, replaceHealthy: false)
    }

    func testMissingHealthyHardLinkDoesNotDeleteObjectWithFailedRootBinding() async throws {
        try await assertFailedRootHardLink(removeHealthy: true, replaceHealthy: false)
    }

    func testReplacingHealthyHardLinkDoesNotDeleteObjectWithFailedRootBinding() async throws {
        try await assertFailedRootHardLink(removeHealthy: true, replaceHealthy: true)
    }

    private func assertFailedRootHardLink(removeHealthy: Bool, replaceHealthy: Bool) async throws {
        // Exercise both choices of the canonical old path, not just the easy
        // case where old.rootPath happens to be the unavailable root.
        for offlineIsFirst in [false, true] {
            let fixture = try ConvergentScanFixture()
            let second = fixture.directory.appending(path: offlineIsFirst ? "a-offline" : "z-offline")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try fixture.write("A", bytes: 1)
            let healthy = fixture.root.appending(path: "A")
            let offlineLink = second.appending(path: "B")
            try FileManager.default.linkItem(at: healthy, to: offlineLink)
            let policy = MonitoringPolicy(watchedRoots: [fixture.root, second], maximumEntries: 1)
            let start = Date(timeIntervalSince1970: 2_100_008_400)
            let store = try EvidenceStore(url: fixture.databaseURL)
            let baseline = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 1400)
            let original = try XCTUnwrap(baseline.currentFiles.first)
            XCTAssertEqual(baseline.currentFiles.count, 1)
            // Roots are visited lexically; the later alias carries the
            // newest sample. Both healthy/failed canonical choices remain covered.
            XCTAssertEqual(original.path, offlineIsFirst ? healthy.path : offlineLink.path)
            let movedRoot = second.appendingPathExtension("offline")
            try FileManager.default.moveItem(at: second, to: movedRoot)
            if removeHealthy { try FileManager.default.removeItem(at: healthy) }
            if replaceHealthy { try fixture.write("A", bytes: 2) }
            let partial = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(100), snapshotBase: 1430)
            let retained = partial.currentFiles.first { $0.objectID == original.objectID }
            XCTAssertNotNil(retained, "A failed-root binding cannot prove object deletion (offline first: \(offlineIsFirst)).")
            XCTAssertEqual(retained?.presence, removeHealthy ? .unknown : .present)
            XCTAssertEqual(retained?.actionable, false)
            XCTAssertFalse(partial.events.contains { $0.operation == .delete })
            if replaceHealthy {
                XCTAssertEqual(partial.events.reduce(0) { $0 + $1.logicalDelta }, 2,
                    "A replacement cannot debit an old object's bytes while its remaining binding is unavailable.")
            }
            if removeHealthy { XCTAssertEqual(retained?.path, offlineLink.path) }
            let inspection = try SQLiteConnection(url: fixture.databaseURL)
            let escapedID = original.objectID.replacingOccurrences(of: "'", with: "''")
            XCTAssertEqual(try inspection.scalarInt("SELECT COUNT(*) FROM path_bindings WHERE object_id = '\(escapedID)' AND path LIKE '%/B' AND valid_through IS NULL"), 1)
            inspection.close()
            try FileManager.default.moveItem(at: movedRoot, to: second)
            let recovered = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(200), snapshotBase: 1460)
            XCTAssertEqual(recovered.currentFiles.first { $0.objectID == original.objectID }?.presence, .present)
            XCTAssertEqual(recovered.currentFiles.count, replaceHealthy ? 2 : 1)
            await store.close()
        }
    }

    func testUnavailableRootDoesNotBlockHealthyRootOrProveDeletion() async throws {
        let fixture = try ConvergentScanFixture()
        let second = fixture.root.deletingLastPathComponent().appending(path: "second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data([1]).write(to: second.appending(path: "B"))
        try fixture.write("A", bytes: 1)
        let policy = MonitoringPolicy(watchedRoots: [fixture.root, second], maximumEntries: 1)
        let start = Date()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let baseline = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 1000)
        let baselineCoverage = try await store.scanCoverageStatus()
        XCTAssertEqual(baseline.currentFiles.count, 2)
        try FileManager.default.moveItem(at: second, to: second.appendingPathExtension("offline"))
        try fixture.write("C", bytes: 2)
        let partial = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(100), snapshotBase: 1050)
        XCTAssertEqual(partial.currentFiles.filter { $0.presence == .present }.map(\.path).sorted(), fixture.paths(["A", "C"]))
        XCTAssertEqual(partial.currentFiles.first { $0.path == second.appending(path: "B").path }?.presence, .unknown)
        XCTAssertFalse(partial.events.contains { $0.operation == .delete })
        let coverage = try await store.scanCoverageStatus()
        XCTAssertEqual(coverage?.detailCoverage, "partial")
        XCTAssertEqual(coverage?.lastCompleteGenerationAt, baselineCoverage?.lastCompleteGenerationAt)
        XCTAssertTrue(partial.coverageGaps.contains { $0.rootPath == second.path })
        await store.close()
    }
    func testRestartedDirectoryDoesNotPublishDeletedStagedFile() async throws {
        let fixture = try ConvergentScanFixture()
        for name in ["A", "B", "C"] { try fixture.write(name, bytes: 1) }
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date()
        let scope = policy.scopeVersion(at: start)
        let store = try EvidenceStore(url: fixture.databaseURL)
        let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: start)
        let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start)
        XCTAssertEqual(slice.entries.map(\.path), fixture.paths(["A"]))
        _ = try await store.recordScanSlice(snapshot: Self.snapshot(950), slice: slice, scope: scope, trigger: .startup)
        try FileManager.default.removeItem(at: fixture.root.appending(path: "A"))
        // Force a different directory signature, independent of filesystem clock granularity.
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(5)], ofItemAtPath: fixture.root.path)
        let committed = try await Self.completeGeneration(store: store, policy: policy, start: start.addingTimeInterval(10), snapshotBase: 951)
        XCTAssertEqual(committed.currentFiles.map(\.path).sorted(), fixture.paths(["B", "C"]))
        let integrity = try await store.diagnostics().integrity
        XCTAssertEqual(integrity, "ok")
        await store.close()
    }
    func testUnchangedCompletedGenerationsDoNotMultiplyFileHistory() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 10)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_004_000)
        let store = try EvidenceStore(url: fixture.databaseURL)

        _ = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 400)
        let replay = try await Self.completeGeneration(
            store: store,
            policy: policy,
            start: start.addingTimeInterval(60),
            snapshotBase: 450
        )
        let diagnostics = try await store.diagnostics()

        XCTAssertEqual(replay.persistedEventCount, 0)
        XCTAssertEqual(diagnostics.observationCount, 2)
        XCTAssertEqual(diagnostics.currentFileCount, 1)
        XCTAssertEqual(diagnostics.fileStateObservationCount, 1)
        await store.close()
    }

    func testCompletedGenerationReconcilesLargeStateWithBoundedInlineResult() async throws {
        let fixture = try ConvergentScanFixture()
        let policy = fixture.policy(maximumEntries: 512)
        let start = Date(timeIntervalSince1970: 2_100_005_000)
        let store = try EvidenceStore(url: fixture.databaseURL)
        // Exercise the real scanner and pass validation, not fabricated completed
        // staging that bypasses the membership contract being tested.
        for index in 0 ..< 2_500 {
            try fixture.write(String(format: "item-%05d", index), bytes: 1)
        }
        let result = try await Self.completeGeneration(store: store, policy: policy, start: start, snapshotBase: 500)
        XCTAssertEqual(result.persistedEventCount, 2_500)
        XCTAssertEqual(result.events.count, 2_048)
        XCTAssertEqual(result.currentFileCount, 2_500)
        XCTAssertEqual(result.currentFiles.count, 2_048)
        XCTAssertTrue(result.resultWindowTruncated)
        let allCurrentFiles = try await store.currentFiles(includeNonActionable: true)
        XCTAssertEqual(allCurrentFiles.count, 2_500)
        await store.close()
    }

    func testReconciliationIsAtomicAcrossEveryInjectedInterruptionBoundary() async throws {
        for checkpoint in ["after-observation", "after-present-objects", "after-missing-objects", "before-finalize"] {
            let fixture = try ConvergentScanFixture()
            try fixture.write("A", bytes: 10)
            try fixture.write("B", bytes: 20)
            let policy = fixture.policy(maximumEntries: 1)
            let start = Date(timeIntervalSince1970: 2_100_006_000)
            let arm = ReconciliationCheckpointArm()
            var store: EvidenceStore? = try EvidenceStore(
                url: fixture.databaseURL,
                reconciliationCheckpoint: { try arm.check($0) }
            )
            _ = try await Self.completeGeneration(store: store!, policy: policy, start: start, snapshotBase: 600)
            try FileManager.default.removeItem(at: fixture.root.appending(path: "B"))
            arm.value = checkpoint

            do {
                _ = try await Self.completeGeneration(
                    store: store!,
                    policy: policy,
                    start: start.addingTimeInterval(100),
                    snapshotBase: 700
                )
                XCTFail("Expected injected interruption at \(checkpoint)")
            } catch ReconciliationCheckpointFailure.injected {
                // Expected. SQLite must have rolled the entire reconciliation back.
            }
            let retainedPaths = try await store!.currentFiles(includeNonActionable: true).map(\.path).sorted()
            XCTAssertEqual(
                retainedPaths,
                fixture.paths(["A", "B"]),
                "Last-known-good state changed at \(checkpoint)"
            )
            await store!.close()
            store = nil

            store = try EvidenceStore(url: fixture.databaseURL)
            let recovered = try await Self.completeGeneration(
                store: store!,
                policy: policy,
                start: start.addingTimeInterval(200),
                snapshotBase: 800
            )
            XCTAssertEqual(recovered.currentFiles.map(\.path), fixture.paths(["A"]))
            XCTAssertEqual(recovered.events.filter { $0.operation == .delete }.map(\.path), fixture.paths(["B"]))
            await store!.close()
        }
    }

    func testEventGapPersistsAcrossRestartUntilCompleteReconciliation() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 1)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_007_000)
        var store: EvidenceStore? = try EvidenceStore(url: fixture.databaseURL)
        try await store!.recordReconciliationInvalidation(at: start)
        let pendingBeforeRestart = try await store!.hasPendingReconciliation()
        XCTAssertTrue(pendingBeforeRestart)
        await store!.close()
        store = nil

        store = try EvidenceStore(url: fixture.databaseURL)
        let pendingAfterRestart = try await store!.hasPendingReconciliation()
        XCTAssertTrue(pendingAfterRestart)
        let result = try await Self.completeGeneration(store: store!, policy: policy, start: start.addingTimeInterval(1), snapshotBase: 900)

        let pendingAfterCompletion = try await store!.hasPendingReconciliation()
        XCTAssertFalse(pendingAfterCompletion)
        let eventGap = try XCTUnwrap(result.coverageGaps.first { $0.reason == "event-drop" })
        XCTAssertEqual(eventGap.startedAt, start)
        XCTAssertNotNil(eventGap.endedAt)
        await store!.close()
    }

    func testRepeatedEventGapsCoalesceUntilReconciliationAndCanReopen() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 1)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_007_100)
        let store = try EvidenceStore(url: fixture.databaseURL)

        try await store.recordReconciliationInvalidation(at: start.addingTimeInterval(10))
        try await store.recordReconciliationInvalidation(at: start)
        try await store.recordReconciliationInvalidation(at: start.addingTimeInterval(20))
        let pendingBeforeCompletion = try await store.pendingReconciliationCount()
        XCTAssertEqual(pendingBeforeCompletion, 1)

        let first = try await Self.completeGeneration(
            store: store,
            policy: policy,
            start: start.addingTimeInterval(30),
            snapshotBase: 950
        )
        XCTAssertEqual(first.coverageGaps.first { $0.reason == "event-drop" }?.startedAt, start)
        let pendingAfterCompletion = try await store.pendingReconciliationCount()
        XCTAssertEqual(pendingAfterCompletion, 0)

        try await store.recordReconciliationInvalidation(at: start.addingTimeInterval(40))
        let pendingAfterReopen = try await store.pendingReconciliationCount()
        XCTAssertEqual(pendingAfterReopen, 1)
        await store.close()
    }

    func testLegacyPersistedGenerationDecodesWithoutNewCursorFields() throws {
        let generation = MetadataScanGeneration(
            generationID: "legacy",
            scopeVersionID: "scope",
            rootPaths: ["/tmp/watch"],
            excludedPaths: [],
            status: .active,
            roots: [.init(
                rootPath: "/tmp/watch",
                status: .active,
                frontier: [.init(directoryPath: "/tmp/watch", depth: 0, afterName: "B")]
            )],
            processedEntryCount: 1,
            stagedFileCount: 1,
            startedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let encoded = try JSONEncoder().encode(generation)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "schedulerCursor")
        object.removeValue(forKey: "reconciliationToken")
        var roots = try XCTUnwrap(object["roots"] as? [[String: Any]])
        var frontier = try XCTUnwrap(roots[0]["frontier"] as? [[String: Any]])
        frontier[0].removeValue(forKey: "directorySignature")
        roots[0]["frontier"] = frontier
        object["roots"] = roots

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MetadataScanGeneration.self, from: legacyData)

        XCTAssertNil(decoded.schedulerCursor)
        XCTAssertNil(decoded.reconciliationToken)
        XCTAssertNil(decoded.roots[0].frontier[0].directorySignature)
        XCTAssertEqual(decoded.roots[0].frontier[0].afterName, "B")
    }

    func testHighFanoutSliceUsesOneStreamingPassAndRetainsOnlyItsBudget() throws {
        let fixture = try ConvergentScanFixture()
        for index in 0 ..< 2_000 {
            try fixture.write(String(format: "entry-%05d", index), bytes: 1)
        }
        let policy = fixture.policy(maximumEntries: 64)
        let start = Date(timeIntervalSince1970: 2_100_002_000)
        let scope = policy.scopeVersion(at: start)
        let generation = MetadataScanGeneration(
            generationID: "high-fanout",
            scopeVersionID: scope.scopeVersionID,
            rootPaths: scope.rootPaths,
            excludedPaths: scope.excludedPaths,
            status: .active,
            roots: scope.rootPaths.map { .init(rootPath: $0) },
            processedEntryCount: 0,
            stagedFileCount: 0,
            startedAt: start,
            updatedAt: start
        )

        let slice = DirectoryMetadataScanner().scanSlice(
            policy: policy,
            generation: generation,
            at: start.addingTimeInterval(1)
        )

        XCTAssertEqual(slice.entries.count, 64)
        XCTAssertEqual(slice.diagnostics.directoryEnumerationPasses, 1)
        XCTAssertEqual(slice.diagnostics.directoryEntriesInspected, 2_000)
        XCTAssertEqual(slice.diagnostics.peakRetainedDirectoryNames, 64)
        XCTAssertEqual(slice.generation.status, .active)
    }

    func testBoundedSelectorKeepsOnlyFirstBatchAcrossOneHundredThousandNames() {
        var selector = BoundedMaxNameHeap(capacity: 512)
        for index in (0 ..< 100_000).reversed() {
            selector.insert(String(format: "entry-%06d", index))
        }

        XCTAssertEqual(selector.retainedCount, 512)
        XCTAssertEqual(selector.sortedValues().first, "entry-000000")
        XCTAssertEqual(selector.sortedValues().last, "entry-000511")
    }

    func testDirectoryChangeBeforeResumeResetsCursorAndDoesNotSkipEarlierName() throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("B", bytes: 2)
        try fixture.write("C", bytes: 3)
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_003_000)
        let scope = policy.scopeVersion(at: start)
        var generation = MetadataScanGeneration(
            generationID: "mutation-resume",
            scopeVersionID: scope.scopeVersionID,
            rootPaths: scope.rootPaths,
            excludedPaths: scope.excludedPaths,
            status: .active,
            roots: scope.rootPaths.map { .init(rootPath: $0) },
            processedEntryCount: 0,
            stagedFileCount: 0,
            startedAt: start,
            updatedAt: start
        )
        let scanner = DirectoryMetadataScanner()
        var seen = Set<String>()

        var slice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(1))
        seen.formUnion(slice.entries.map(\.path))
        generation = slice.generation
        XCTAssertEqual(slice.entries.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["B"])

        // Ensure a distinct directory timestamp even on coarse filesystems.
        Thread.sleep(forTimeInterval: 0.01)
        try fixture.write("A", bytes: 1)
        slice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(2))
        XCTAssertEqual(slice.diagnostics.directoryChangeRestarts, 1)
        XCTAssertEqual(slice.entries.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["A"])
        seen.formUnion(slice.entries.map(\.path))
        generation = slice.generation

        var attempts = 0
        while generation.status == .active, attempts < 10 {
            slice = scanner.scanSlice(
                policy: policy,
                generation: generation,
                at: start.addingTimeInterval(Double(3 + attempts))
            )
            seen.formUnion(slice.entries.map(\.path))
            generation = slice.generation
            attempts += 1
        }

        XCTAssertEqual(generation.status, .completed)
        XCTAssertEqual(seen, Set(fixture.paths(["A", "B", "C"])))
    }

    func testMultipleRootsReceiveWorkInTheSameBoundedSlice() throws {
        let fixture = try ConvergentScanFixture()
        let secondRoot = fixture.directory.appending(path: "watch-two", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        for index in 0 ..< 10 {
            try fixture.write("first-\(index)", bytes: 1)
            try Data([1]).write(to: secondRoot.appending(path: "second-\(index)"))
        }
        let policy = MonitoringPolicy(watchedRoots: [fixture.root, secondRoot], maximumEntries: 4, maximumDepth: 8)
        let start = Date(timeIntervalSince1970: 2_100_004_000)
        let scope = policy.scopeVersion(at: start)
        let generation = MetadataScanGeneration(
            generationID: "fair-roots",
            scopeVersionID: scope.scopeVersionID,
            rootPaths: scope.rootPaths,
            excludedPaths: scope.excludedPaths,
            status: .active,
            roots: scope.rootPaths.map { .init(rootPath: $0) },
            processedEntryCount: 0,
            stagedFileCount: 0,
            startedAt: start,
            updatedAt: start
        )

        let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(1))
        XCTAssertEqual(slice.entries.count, 4)
        XCTAssertEqual(Set(slice.entries.map(\.rootPath)), Set(scope.rootPaths))
        XCTAssertEqual(slice.diagnostics.directoryEnumerationPasses, 2)
        XCTAssertLessThanOrEqual(slice.diagnostics.peakRetainedDirectoryNames, 2)
    }

    func testSmallSlicesResumeReconcileOnlyWhenCompleteAndDeleteBAfterFullSecondGeneration() async throws {
        let fixture = try ConvergentScanFixture()
        try fixture.write("A", bytes: 10)
        try fixture.write("B", bytes: 20)
        try fixture.write("C", bytes: 30)
        let policy = fixture.policy(maximumEntries: 2)
        let scanner = DirectoryMetadataScanner()
        let start = Date(timeIntervalSince1970: 2_100_000_000)

        var store: EvidenceStore? = try EvidenceStore(url: fixture.databaseURL)
        var generation = try await store!.beginOrResumeScanGeneration(scope: policy.scopeVersion(at: start), at: start)
        let firstSlice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(1))
        let firstCommit = try await store!.recordScanSlice(
            snapshot: Self.snapshot(1),
            slice: firstSlice,
            scope: policy.scopeVersion(at: start),
            trigger: .startup
        )
        XCTAssertNil(firstCommit.observation)
        XCTAssertEqual(firstCommit.generation.status, .active)
        XCTAssertLessThanOrEqual(firstCommit.generation.processedEntryCount, 2)
        let currentBeforeRestart = try await store!.currentFiles(includeNonActionable: true)
        XCTAssertTrue(currentBeforeRestart.isEmpty, "An incomplete generation must not become authoritative current state")
        let generationID = firstCommit.generation.generationID
        await store!.close()
        store = nil

        store = try EvidenceStore(url: fixture.databaseURL)
        generation = try await store!.beginOrResumeScanGeneration(scope: policy.scopeVersion(at: start), at: start.addingTimeInterval(2))
        XCTAssertEqual(generation.generationID, generationID)
        XCTAssertEqual(generation.processedEntryCount, firstCommit.generation.processedEntryCount)

        var baseline: ObservationCommitResult?
        var baselineSlices = 1
        while baseline == nil, baselineSlices < 20 {
            let now = start.addingTimeInterval(Double(baselineSlices + 2))
            let slice = scanner.scanSlice(policy: policy, generation: generation, at: now)
            let commit = try await store!.recordScanSlice(
                snapshot: Self.snapshot(baselineSlices + 1),
                slice: slice,
                scope: policy.scopeVersion(at: start),
                trigger: .startup
            )
            generation = commit.generation
            baseline = commit.observation
            baselineSlices += 1
        }
        let completedBaseline = try XCTUnwrap(baseline)
        XCTAssertGreaterThan(baselineSlices, 1)
        XCTAssertEqual(completedBaseline.currentFiles.map(\.path).sorted(), fixture.paths(["A", "B", "C"]))
        XCTAssertEqual(generation.stagedFileCount, 3)
        let baselineCoverage = try await store!.scanCoverageStatus()
        XCTAssertEqual(baselineCoverage?.detailCoverage, "complete")

        try FileManager.default.removeItem(at: fixture.root.appending(path: "B"))
        generation = try await store!.beginOrResumeScanGeneration(
            scope: policy.scopeVersion(at: start),
            at: start.addingTimeInterval(100)
        )
        var deletion: ObservationCommitResult?
        var deletionSlices = 0
        while deletion == nil, deletionSlices < 20 {
            let now = start.addingTimeInterval(Double(101 + deletionSlices))
            let slice = scanner.scanSlice(policy: policy, generation: generation, at: now)
            let commit = try await store!.recordScanSlice(
                snapshot: Self.snapshot(100 + deletionSlices),
                slice: slice,
                scope: policy.scopeVersion(at: start),
                trigger: .scheduled
            )
            generation = commit.generation
            deletion = commit.observation
            deletionSlices += 1
            if deletion == nil {
                let current = try await store!.currentFiles(includeNonActionable: true)
                XCTAssertNotNil(current.first { $0.path == fixture.root.appending(path: "B").path })
                let retainedEvents = try await store!.events(from: start, through: now, limit: 100)
                XCTAssertFalse(retainedEvents.contains { $0.operation == .delete })
            }
        }
        let completedDeletion = try XCTUnwrap(deletion)
        XCTAssertEqual(completedDeletion.events.filter { $0.operation == .delete }.map(\.path), [fixture.root.appending(path: "B").path])
        XCTAssertEqual(completedDeletion.currentFiles.map(\.path).sorted(), fixture.paths(["A", "C"]))
        XCTAssertEqual(Set(completedDeletion.currentFiles.map(\.path)).count, 2)
        await store!.close()
    }

    func testDeletedQueuedDirectoryIsRescannedAndScopeChangeAbandonsOnlyUnpublishedWork() async throws {
        let fixture = try ConvergentScanFixture()
        let nested = fixture.root.appending(path: "0-folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8).write(to: nested.appending(path: "nested"))
        try fixture.write("A", bytes: 10)
        let scanner = DirectoryMetadataScanner()
        let policy = fixture.policy(maximumEntries: 1)
        let start = Date(timeIntervalSince1970: 2_100_001_000)
        let store = try EvidenceStore(url: fixture.databaseURL)

        var generation = try await store.beginOrResumeScanGeneration(scope: policy.scopeVersion(at: start), at: start)
        var slice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(1))
        var commit = try await store.recordScanSlice(
            snapshot: Self.snapshot(200),
            slice: slice,
            scope: policy.scopeVersion(at: start),
            trigger: .startup
        )
        XCTAssertNil(commit.observation)
        try FileManager.default.removeItem(at: nested)

        var attempts = 0
        while commit.generation.status == .active, attempts < 10 {
            generation = commit.generation
            slice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(Double(2 + attempts)))
            commit = try await store.recordScanSlice(
                snapshot: Self.snapshot(201 + attempts),
                slice: slice,
                scope: policy.scopeVersion(at: start),
                trigger: .startup
            )
            attempts += 1
        }
        XCTAssertEqual(commit.generation.status, .completed)
        XCTAssertNotNil(commit.observation)
        let currentAfterInvalidCursor = try await store.currentFiles(includeNonActionable: true)
        XCTAssertEqual(currentAfterInvalidCursor.map(\.path), fixture.paths(["A"]))

        generation = try await store.beginOrResumeScanGeneration(scope: policy.scopeVersion(at: start), at: start.addingTimeInterval(20))
        slice = scanner.scanSlice(policy: policy, generation: generation, at: start.addingTimeInterval(21))
        commit = try await store.recordScanSlice(
            snapshot: Self.snapshot(220),
            slice: slice,
            scope: policy.scopeVersion(at: start),
            trigger: .recovery
        )
        let oldGenerationID = commit.generation.generationID
        let changedPolicy = fixture.policy(maximumEntries: 1, exclusions: [fixture.root.appending(path: "A")])
        let replacement = try await store.beginOrResumeScanGeneration(
            scope: changedPolicy.scopeVersion(at: start.addingTimeInterval(22)),
            at: start.addingTimeInterval(22)
        )
        XCTAssertNotEqual(replacement.generationID, oldGenerationID)
        let history = try await store.scanGenerations()
        let abandoned = try XCTUnwrap(history.first { $0.generationID == oldGenerationID })
        XCTAssertEqual(abandoned.status, .abandoned)
        XCTAssertTrue(abandoned.limitations.contains { $0.contains("Scope version changed") })
        let currentAfterScopeChange = try await store.currentFiles(includeNonActionable: true)
        XCTAssertEqual(currentAfterScopeChange.map(\.path), fixture.paths(["A"]))
        let coverageValue = try await store.scanCoverageStatus()
        let coverage = try XCTUnwrap(coverageValue)
        XCTAssertEqual(coverage.configuredRoots, [fixture.root.path])
        XCTAssertEqual(coverage.excludedPaths, [fixture.root.appending(path: "A").path])
        XCTAssertEqual(coverage.detailCoverage, "partial")
        XCTAssertEqual(coverage.activeGeneration?.generationID, replacement.generationID)
        let lifecycle = try await store.lifecycleStatus(try .init(), at: start.addingTimeInterval(23))
        XCTAssertEqual(lifecycle.scanCoverage?.activeGeneration?.generationID, replacement.generationID)
        XCTAssertTrue(lifecycle.observationGaps.contains {
            $0.observationID == replacement.generationID && $0.reason == "scan-generation-incomplete"
        })
        await store.close()
    }

    private static func snapshot(_ index: Int) -> StorageSnapshot {
        StorageSnapshot(
            snapshotID: "convergent-volume-\(index)",
            observedAt: "2036-07-18T13:20:00.000Z",
            volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)]
        )
    }

    private static func completeGeneration(
        store: EvidenceStore,
        policy: MonitoringPolicy,
        start: Date,
        snapshotBase: Int
    ) async throws -> ObservationCommitResult {
        let scanner = DirectoryMetadataScanner()
        var generation = try await store.beginOrResumeScanGeneration(scope: policy.scopeVersion(at: start), at: start)
        for attempt in 0 ..< 100 {
            let slice = scanner.scanSlice(
                policy: policy,
                generation: generation,
                at: start.addingTimeInterval(Double(attempt + 1))
            )
            let commit = try await store.recordScanSlice(
                snapshot: snapshot(snapshotBase + attempt),
                slice: slice,
                scope: policy.scopeVersion(at: start),
                trigger: .scheduled
            )
            generation = commit.generation
            if let observation = commit.observation { return observation }
        }
        throw ReconciliationCheckpointFailure.didNotComplete
    }
}

private enum ReconciliationCheckpointFailure: Error {
    case injected
    case didNotComplete
}

private final class ReconciliationCheckpointArm: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func check(_ checkpoint: String) throws {
        let shouldThrow = lock.withLock { () -> Bool in
            guard storage == checkpoint else { return false }
            storage = nil
            return true
        }
        if shouldThrow { throw ReconciliationCheckpointFailure.injected }
    }
}

private final class ConvergentScanFixture {
    let directory: URL
    let root: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        root = directory.appending(path: "watch", directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "evidence.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ name: String, bytes: Int) throws {
        try Data(repeating: UInt8(bytes), count: bytes).write(to: root.appending(path: name))
    }

    func paths(_ names: [String]) -> [String] {
        names.map { root.appending(path: $0).path }.sorted()
    }

    func policy(maximumEntries: Int, exclusions: [URL] = []) -> MonitoringPolicy {
        MonitoringPolicy(
            watchedRoots: [root],
            excludedRoots: exclusions,
            maximumEntries: maximumEntries,
            maximumDepth: 8
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
