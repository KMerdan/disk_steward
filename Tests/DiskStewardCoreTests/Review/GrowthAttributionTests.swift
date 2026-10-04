import CoreServices
@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-661: the dirty objects are re-measured within a budget and the
/// volume delta is attributed to them, with the rest stated as unexplained.
final class GrowthAttributionTests: XCTestCase {
    private var root: URL!
    private var scope: String!
    private let mib: Int64 = 1_048_576

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/ds-attribution-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scope = DirectoryChangeStream.canonicalPath(root.path + "/scope")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ relative: String, bytes: Int) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    private func du(_ path: String) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (Int64(String(decoding: data, as: UTF8.self).split(separator: "\t").first ?? "") ?? -1) * 1_024
    }

    /// Two projects with one object each, reviewed so their sizes are stored.
    private func reviewedScope() throws -> ReviewIndex {
        try write("scope/web/package.json", bytes: 100)
        try write("scope/web/pnpm-lock.yaml", bytes: 100)
        try write("scope/web/node_modules/.modules.yaml", bytes: 100)
        try write("scope/web/node_modules/a/index.js", bytes: 2 * Int(mib))
        try write("scope/engine/Cargo.toml", bytes: 100)
        try write("scope/engine/target/debug/app", bytes: 3 * Int(mib))
        let report = ReviewWalker(decider: ClassifierObjectDecider(oracle: SilentRepositoryOracle())).review(scope: scope)
        XCTAssertEqual(Set(report.objects.map { URL(fileURLWithPath: $0.path).lastPathComponent }), ["node_modules", "target"])
        let index = try ReviewIndex(url: root.appending(path: "steward.sqlite"))
        return index
    }

    private func record(_ index: ReviewIndex) async throws {
        let report = ReviewWalker(decider: ClassifierObjectDecider(oracle: SilentRepositoryOracle())).review(scope: scope)
        try await index.record(report)
    }

    /// Journal changes for real directories under the scope, as FSEvents reports them.
    /// `aboveProjects` journals from the folder above the scope, so changes
    /// collapse two levels down to the project folders, as from a home root.
    private func journal(_ paths: [String], at date: Date, aboveProjects: Bool = false) async throws -> ChangeJournal {
        let journal = try ChangeJournal(url: root.appending(path: "steward.sqlite"))
        let modified = UInt32(kFSEventStreamEventFlagItemModified)
        let events = paths.enumerated().map { (scope + "/" + $0.element, modified, UInt64(100 + $0.offset)) }
        try await journal.record(DirectoryChangeBatch.interpret(events), roots: [aboveProjects ? root.path : scope], at: date)
        return journal
    }

    private func ring(used before: Int64, after: Int64, from: Date, through: Date) async throws -> URL {
        let url = root.appending(path: "capacity.sqlite")
        let ring = try CapacityRing(url: url)
        let total: Int64 = 1_000 * 1_024 * mib
        try await ring.record(volumeUUID: "UUID-data", mountPath: "/System/Volumes/Data", totalBytes: total, availableBytes: total - before, at: from)
        try await ring.record(volumeUUID: "UUID-data", mountPath: "/System/Volumes/Data", totalBytes: total, availableBytes: total - after, at: through)
        await ring.close()
        return url
    }

    // MARK: The join

    func testChangesJoinToObjectsAtAboveAndBelowThem() {
        func object(_ path: String, activity: TimeInterval = 0) -> IndexedObject {
            IndexedObject(objectID: path, projectID: "", path: path, kind: "artifact", recreateClass: "rebuild", allocatedBytes: 10,
                          fileCount: 1, measuredAt: Date(timeIntervalSince1970: 0), lastActivity: Date(timeIntervalSince1970: activity))
        }
        let modules = object("/h/code/web/node_modules", activity: 5)
        let target = object("/h/code/engine/target", activity: 9)
        let changes = [
            JournalChange(path: "/h/code/web/node_modules", changes: 4, firstInterval: Date(), lastInterval: Date()),  // at an object
            JournalChange(path: "/h/code/engine", changes: 2, firstInterval: Date(), lastInterval: Date()),            // collapsed above one
            JournalChange(path: "/h/code/api/.venv", changes: 3, firstInterval: Date(), lastInterval: Date()),         // object-named, unknown
            JournalChange(path: "/h/Documents/notes", changes: 7, firstInterval: Date(), lastInterval: Date()),        // no object
        ]
        let plan = GrowthAttributor.plan(changes: changes, containing: ["/h/code/web/node_modules": modules],
                                         under: ["/h/code/engine": [target]])
        XCTAssertEqual(plan.targets.map(\.path), ["/h/code/web/node_modules", "/h/code/api/.venv", "/h/code/engine/target"])
        XCTAssertEqual(plan.targets.map(\.changes), [4, 3, 0], "an object found under a changed directory carries no changes of its own")
        XCTAssertNil(plan.targets[1].baseline)
        XCTAssertEqual(plan.unmatched.map(\.path), ["/h/Documents/notes"])
    }

    /// Stored objects can nest (a reviewed project inside an opted-in cache);
    /// the walker stops at a revisit, so only the outer one is measured.
    func testATargetInsideAnotherIsMeasuredOnce() {
        func object(_ path: String) -> IndexedObject {
            IndexedObject(objectID: path, projectID: "", path: path, kind: "cache", recreateClass: "redownload",
                          allocatedBytes: 1, fileCount: 1, measuredAt: Date(), lastActivity: Date())
        }
        let outer = object("/h/.cache/uv")
        let inner = object("/h/.cache/uv/sdists/pkg/.venv")
        let plan = GrowthAttributor.plan(changes: [JournalChange(path: "/h/.cache", changes: 1, firstInterval: Date(), lastInterval: Date())],
                                         containing: [:], under: ["/h/.cache": [inner, outer]])
        XCTAssertEqual(plan.targets.map(\.path), ["/h/.cache/uv"])
    }

    // MARK: AC-02

    /// Growth in two objects and outside the scope: the in-scope delta is
    /// attributed within 5% and the rest is unexplained.
    func testGrowthInTwoObjectsAndOutsideTheScopeIsAttributedAndTheRestUnexplained() async throws {
        let index = try reviewedScope()
        try await record(index)
        let before = try du(scope + "/web/node_modules") + du(scope + "/engine/target")
        // From the folder above, both changes collapse to their project folders;
        // the objects are found under them.
        let journal = try await journal(["web/node_modules/b", "engine/target/debug"], at: Date().addingTimeInterval(-600), aboveProjects: true)
        let changed = try await journal.changes(from: .distantPast, through: Date(), limit: 10).changes.items.map(\.path)
        XCTAssertEqual(Set(changed), [scope + "/web", scope + "/engine"])
        let coverage = try await journal.coverageStart()
        let start = try XCTUnwrap(coverage).addingTimeInterval(1)
        try write("scope/web/node_modules/b/big.js", bytes: 6 * Int(mib))
        try write("scope/engine/target/debug/incremental/x.o", bytes: 9 * Int(mib))
        try write("outside/download.dmg", bytes: 20 * Int(mib))
        let inScope = try du(scope + "/web/node_modules") + du(scope + "/engine/target") - before
        let outside = try du(root.path + "/outside")
        let through = Date()
        let ringURL = try await ring(used: 400_000 * mib, after: 400_000 * mib + inScope + outside, from: start, through: through.addingTimeInterval(-1))
        let service = GrowthAttributionService(journal: journal, index: index, ringURL: ringURL, fileURL: root.appending(path: "growth-attributions.json"))
        await service.observe(usedBytes: 0, volumeUUID: "UUID-data", thresholdBytes: .max)
        let attribution = try await service.attribute(trigger: .request, budget: .default)

        XCTAssertEqual(Set(attribution.objects.map(\.path)), [scope + "/web/node_modules", scope + "/engine/target"])
        XCTAssertTrue(attribution.objects.allSatisfy { $0.basis == .measured })
        XCTAssertEqual(Double(attribution.attributedBytes), Double(inScope), accuracy: Double(inScope) * 0.05, "the in-scope delta within 5%")
        let unexplained = try XCTUnwrap(attribution.unexplainedBytes)
        XCTAssertEqual(Double(unexplained), Double(outside), accuracy: Double(outside) * 0.05, "the growth outside the scope is unexplained")
        XCTAssertEqual(attribution.volume?.deltaBytes, inScope + outside)
        XCTAssertEqual(attribution.objects.first?.path, scope + "/engine/target", "largest change first")
        XCTAssertTrue(GrowthAttribution.remainderCovers.contains("System Data"))
        await journal.close()
        await index.close()
    }

    /// Each attribution advances the stored sizes, so the next one counts
    /// only what changed after it.
    func testASecondAttributionCountsOnlyTheNewGrowth() async throws {
        let index = try reviewedScope()
        try await record(index)
        let journal = try await journal(["web/node_modules/b"], at: Date().addingTimeInterval(-600))
        try write("scope/web/node_modules/b/one.js", bytes: 4 * Int(mib))
        let service = GrowthAttributionService(journal: journal, index: index, ringURL: root.appending(path: "none.sqlite"),
                                               fileURL: root.appending(path: "growth-attributions.json"))
        let first = try await service.attribute(trigger: .threshold, budget: .default)
        XCTAssertEqual(Double(first.attributedBytes), Double(4 * mib), accuracy: Double(mib) * 0.2)
        let stored = try await index.objectsContaining([scope + "/web/node_modules"])[scope + "/web/node_modules"]
        XCTAssertEqual(stored?.allocatedBytes, try du(scope + "/web/node_modules"), "the measured size is the next baseline")

        try write("scope/web/node_modules/b/two.js", bytes: 2 * Int(mib))
        try await journal.record(DirectoryChangeBatch.interpret([(scope + "/web/node_modules/b", UInt32(kFSEventStreamEventFlagItemModified), 900)]),
                                 roots: [scope], at: Date())
        let second = try await service.attribute(trigger: .threshold, budget: .default)
        XCTAssertEqual(second.from, first.through, "windows are contiguous")
        XCTAssertEqual(Double(second.attributedBytes), Double(2 * mib), accuracy: Double(mib) * 0.2, "not the 6 MiB since the review")
        XCTAssertNil(second.unexplainedBytes, "no capacity samples, so the remainder is unknown, not zero")
        XCTAssertTrue(second.limitations.contains { $0.contains("No capacity samples") })
        await journal.close()
        await index.close()
    }

    /// A removed object shrinks by its last size; a new object-named
    /// directory created in the window counts in full; an older one without a
    /// stored size is measured for next time but not attributed.
    func testGoneCreatedAndUnknownObjects() async throws {
        let index = try reviewedScope()
        try await record(index)
        let targetBytes = try du(scope + "/engine/target")
        try write("scope/legacy/.venv/lib/old.py", bytes: Int(mib))
        let old = Date().addingTimeInterval(-3 * 86_400)
        let journal = try await journal(["engine/target", "web/.venv", "legacy/.venv"], at: Date().addingTimeInterval(-600))
        try FileManager.default.removeItem(atPath: scope + "/engine/target")
        try write("scope/web/.venv/lib/site.py", bytes: 3 * Int(mib))
        // The first window starts at the journal's first interval; the old
        // environment predates it.
        let coverage = try await journal.coverageStart()
        XCTAssertNotNil(coverage)
        try setBirth(scope + "/legacy/.venv", to: old)
        let service = GrowthAttributionService(journal: journal, index: index, ringURL: root.appending(path: "none.sqlite"),
                                               fileURL: root.appending(path: "growth-attributions.json"))
        let attribution = try await service.attribute(trigger: .request, budget: .default)
        let byPath = Dictionary(uniqueKeysWithValues: attribution.objects.map { ($0.path, $0) })
        XCTAssertEqual(byPath[scope + "/engine/target"]?.basis, .gone)
        XCTAssertEqual(byPath[scope + "/engine/target"]?.deltaBytes, -targetBytes)
        XCTAssertEqual(byPath[scope + "/web/.venv"]?.basis, .created)
        XCTAssertEqual(byPath[scope + "/web/.venv"]?.deltaBytes, try du(scope + "/web/.venv"))
        XCTAssertEqual(byPath[scope + "/legacy/.venv"]?.basis, .noBaseline)
        XCTAssertNil(byPath[scope + "/legacy/.venv"]?.deltaBytes, "an unknown earlier size is never taken as zero")
        XCTAssertEqual(attribution.attributedBytes, try du(scope + "/web/.venv") - targetBytes)
        let gone = try await index.objectsContaining([scope + "/engine/target"])
        XCTAssertNil(gone[scope + "/engine/target"], "a gone object leaves the index")
        let recorded = try await index.objectsContaining([scope + "/legacy/.venv"])
        XCTAssertNotNil(recorded[scope + "/legacy/.venv"], "its size is recorded for next time")
        await journal.close()
        await index.close()
    }

    /// The request budget stops the measurement; what was not measured is
    /// stated, never counted.
    func testABudgetStopLeavesObjectsNotMeasured() async throws {
        let index = try reviewedScope()
        try await record(index)
        let journal = try await journal(["web/node_modules/b", "engine/target/debug"], at: Date().addingTimeInterval(-600))
        let service = GrowthAttributionService(journal: journal, index: index, ringURL: root.appending(path: "none.sqlite"),
                                               fileURL: root.appending(path: "growth-attributions.json"),
                                               attributor: GrowthAttributor(makeWalker: { _ in ReviewWalker(budget: ReviewBudget(wallSeconds: 60, maximumEntries: 1)) }))
        let attribution = try await service.attribute(trigger: .request, budget: GrowthAttributor.requestBudget)
        XCTAssertEqual(attribution.stopReason, .entries)
        XCTAssertFalse(attribution.isComplete)
        let unmeasured = attribution.objects.filter { $0.basis == .notMeasured }
        XCTAssertFalse(unmeasured.isEmpty)
        XCTAssertTrue(unmeasured.allSatisfy { $0.deltaBytes == nil && $0.currentBytes == nil })
        XCTAssertEqual(attribution.attributedBytes, attribution.objects.compactMap(\.deltaBytes).reduce(0, +))
        XCTAssertTrue(attribution.limitations.contains { $0.contains("Measurement stopped (entries)") })
        await journal.close()
        await index.close()
    }

    // MARK: Triggers

    func testTheThresholdTriggersOnceFromTheLowestPoint() async throws {
        let index = try reviewedScope()
        try await record(index)
        let journal = try await journal(["web/node_modules/b"], at: Date().addingTimeInterval(-600))
        let pause = PauseBox()
        let service = GrowthAttributionService(journal: journal, index: index, ringURL: root.appending(path: "none.sqlite"),
                                               fileURL: root.appending(path: "growth-attributions.json"), paused: { pause.value })
        let gib: Int64 = 1_024 * mib
        let threshold = 5 * gib
        var fired: [Bool] = []
        for used in [100 * gib, 103 * gib, 98 * gib, 102 * gib, 103 * gib, 104 * gib, 108 * gib] {
            fired.append(await service.observe(usedBytes: used, volumeUUID: "UUID-data", thresholdBytes: threshold) != nil)
        }
        XCTAssertEqual(fired, [false, false, false, false, true, false, true], "5 GiB above the low point of 98 GiB, then 5 GiB above 103 GiB")
        pause.value = true
        let paused = await service.observe(usedBytes: 120 * gib, volumeUUID: "UUID-data", thresholdBytes: threshold)
        XCTAssertNil(paused, "not while a review runs")
        pause.value = false
        let resumed = await service.observe(usedBytes: 121 * gib, volumeUUID: "UUID-data", thresholdBytes: threshold)
        XCTAssertNotNil(resumed)
        let triggers = await service.attributions.map(\.trigger)
        XCTAssertEqual(triggers, [.threshold, .threshold, .threshold])
        await journal.close()
        await index.close()
    }

    func testAQuestionReusesARecentAttributionAndMeasuresAfterIt() async throws {
        let index = try reviewedScope()
        try await record(index)
        let journal = try await journal(["web/node_modules/b"], at: Date().addingTimeInterval(-600))
        let clock = ClockBox(Date())
        let budgets = BudgetBox()
        let service = GrowthAttributionService(journal: journal, index: index, ringURL: root.appending(path: "none.sqlite"),
                                               fileURL: root.appending(path: "growth-attributions.json"),
                                               attributor: GrowthAttributor(makeWalker: { budget in budgets.append(budget); return ReviewWalker(budget: budget) }),
                                               now: { clock.value })
        let first = try await service.current()
        XCTAssertEqual(first.trigger, .request)
        XCTAssertEqual(budgets.values, [GrowthAttributor.requestBudget], "a question is answered within the request budget")
        XCTAssertLessThan(GrowthAttributor.requestBudget.wallSeconds, 10, "inside the IPC deadline")
        clock.value = clock.value.addingTimeInterval(60)
        let reused = try await service.current()
        XCTAssertEqual(reused.attributionID, first.attributionID, "within two minutes the answer is reused")
        clock.value = clock.value.addingTimeInterval(120)
        let fresh = try await service.current()
        XCTAssertNotEqual(fresh.attributionID, first.attributionID)
        XCTAssertEqual(fresh.from, first.through)
        await journal.close()
        await index.close()
    }

    func testAttributionsPersistBoundedBesideTheStewardFile() async throws {
        let index = try reviewedScope()
        try await record(index)
        let journal = try await journal(["web/node_modules/b"], at: Date().addingTimeInterval(-600))
        let file = root.appending(path: "growth-attributions.json")
        let clock = ClockBox(Date())
        let service = GrowthAttributionService(journal: journal, index: index, ringURL: root.appending(path: "none.sqlite"), fileURL: file, now: { clock.value })
        for _ in 0..<11 {
            clock.value = clock.value.addingTimeInterval(300)
            _ = try await service.attribute(trigger: .threshold, budget: .default)
        }
        let reopened = GrowthAttributionService(journal: journal, index: index, ringURL: root.appending(path: "none.sqlite"), fileURL: file)
        let kept = await reopened.attributions
        XCTAssertEqual(kept.count, GrowthAttributionService.storedAttributions)
        XCTAssertEqual(try XCTUnwrap(kept.first).through.timeIntervalSince1970, clock.value.timeIntervalSince1970, accuracy: 0.001, "newest first")
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, GrowthAttributionService.fileByteLimit)
        let overlapping = await reopened.attributions(overlapping: clock.value.addingTimeInterval(-400), through: clock.value)
        XCTAssertEqual(overlapping.count, 2, "the window touches the last two")
        await journal.close()
        await index.close()
    }

    private func setBirth(_ path: String, to date: Date) throws {
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: path)
    }
}

private final class PauseBox: @unchecked Sendable { var value = false }
private final class BudgetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ReviewBudget] = []
    var values: [ReviewBudget] { lock.withLock { recorded } }
    func append(_ budget: ReviewBudget) { lock.withLock { recorded.append(budget) } }
}
private final class ClockBox: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}
