@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-621: a bounded review prunes at classified objects, sizes them with a
/// size-only pass, persists only objects, and stops on budget or
/// non-convergence with a partial report and a 24-hour cooldown.
final class ReviewWalkerTests: XCTestCase {
    private var root: URL!
    private var scope: String { root.appending(path: "scope").path }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/ds-review-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appending(path: "scope"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scope + "/locked")
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, bytes: Int = 4_096) throws {
        let url = URL(fileURLWithPath: scope + "/" + relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    /// Projects with build output, environments, caches and a repository,
    /// plus a hard-linked pair, a symlink and a sparse file.
    private func makeFixture() throws {
        try write("app/.git/objects/pack/pack-1.pack", bytes: 200_000)
        try write("app/.git/HEAD", bytes: 30)
        try write("app/package.json", bytes: 200)
        try write("app/src/index.js", bytes: 5_000)
        try write("app/node_modules/.package-lock.json", bytes: 300)
        try write("app/node_modules/left-pad/package.json", bytes: 100)
        try write("app/node_modules/left-pad/index.js", bytes: 70_000)
        try write("app/node_modules/left-pad/node_modules/inner/package.json", bytes: 100)
        try write("app/node_modules/left-pad/node_modules/inner/lib.js", bytes: 40_000)
        // A package store links the same file into node_modules twice: one allocation.
        try FileManager.default.linkItem(atPath: scope + "/app/node_modules/left-pad/index.js", toPath: scope + "/app/node_modules/left-pad/index-copy.js")
        try write("app/dist/bundle.js", bytes: 120_000)
        try write("rust/Cargo.toml", bytes: 100)
        try write("rust/src/main.rs", bytes: 2_000)
        for index in 0..<40 { try write("rust/target/debug/deps/d\(index).rlib", bytes: 30_000) }
        try write("py/pyproject.toml", bytes: 100)
        try write("py/.venv/pyvenv.cfg", bytes: 100)
        try write("py/.venv/lib/python3.12/site-packages/x/__init__.py", bytes: 9_000)
        try write("py/__pycache__/a.cpython-312.pyc", bytes: 3_000)
        try write("py/src/a.py", bytes: 1_000)
        try write("docs/notes.md", bytes: 12_000)
        try write("docs/build/output.html", bytes: 8_000)
        try write("links/a.bin", bytes: 1_048_576)
        try FileManager.default.linkItem(atPath: scope + "/links/a.bin", toPath: scope + "/links/b.bin")
        try FileManager.default.createSymbolicLink(atPath: scope + "/links/to-app", withDestinationPath: scope + "/app")
        let sparse = FileHandle(forWritingAtPath: scope + "/links/sparse.bin") ?? {
            FileManager.default.createFile(atPath: scope + "/links/sparse.bin", contents: nil)
            return FileHandle(forWritingAtPath: scope + "/links/sparse.bin")!
        }()
        try sparse.seek(toOffset: 50 * 1_048_576)
        try sparse.write(contentsOf: Data([1]))
        try sparse.close()
    }

    /// `du -sk` in bytes, the reference the acceptance compares against.
    private func du(_ paths: [String]) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk"] + paths
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").compactMap { Int64($0.split(separator: "\t").first ?? "") }.reduce(0, +) * 1_024
    }

    private func walker(budget: ReviewBudget = .default, previous: Int? = nil,
                        clock: @escaping ReviewWalker.Clock = { ProcessInfo.processInfo.systemUptime },
                        footprint: @escaping ReviewWalker.Footprint = ReviewWalker.physicalFootprint) -> ReviewWalker {
        ReviewWalker(decider: ClassifierObjectDecider(oracle: SilentRepositoryOracle()), budget: budget,
                     previousCompleteEntries: previous, clock: clock, footprint: footprint)
    }

    func testObjectsArePrunedSizedLikeDuAndNothingInsideIsListed() async throws {
        try makeFixture()
        let report = walker().review(scope: scope)
        XCTAssertEqual(report.status, .completed)
        XCTAssertTrue(report.isComplete)
        let objects = Dictionary(uniqueKeysWithValues: report.objects.map { (String($0.path.dropFirst(scope.count + 1)), $0) })
        XCTAssertEqual(Set(objects.keys), ["app/.git", "app/node_modules", "app/dist", "rust/target", "py/.venv", "py/__pycache__"],
                       "outermost objects only; nothing nested inside node_modules is classified")
        XCTAssertEqual(objects["app/.git"]?.kind, .repository)
        XCTAssertEqual(objects["app/.git"]?.recreateClass, .liveState)
        XCTAssertEqual(objects["py/.venv"]?.rule, .selfMarker)
        XCTAssertEqual(objects["app/node_modules"]?.rule, .content)
        XCTAssertEqual(objects["rust/target"]?.rule, .manifest)
        XCTAssertEqual(objects["rust/target"]?.projectPath, scope + "/rust")
        XCTAssertEqual(objects["rust/target"]?.fileCount, 40)
        for (relative, object) in objects {
            let reference = try du([scope + "/" + relative])
            XCTAssertEqual(object.allocatedBytes, reference, "\(relative) sized like du")
        }
        XCTAssertEqual(report.scopeAllocatedBytes, try du([scope]), "scope total like du: hard links once, symlink not followed, sparse file by allocation")
        XCTAssertTrue(report.unresolved.contains { $0.path == scope + "/docs/build" }, "an output name without evidence is reported, not classified")
        XCTAssertEqual(Set(report.projects.map { String($0.path.dropFirst(scope.count + 1)) }), ["app", "rust", "py"])
        XCTAssertTrue(report.projects.allSatisfy { $0.lastSourceActivity > 0 })
        XCTAssertEqual(report.coveredTopLevel.count, 5)
        XCTAssertTrue(report.uncoveredTopLevel.isEmpty)

        let index = try ReviewIndex(url: root.appending(path: "steward.sqlite"))
        let written = try await index.record(report)
        XCTAssertEqual(written.objectsStored, 6)
        let stored = try await index.objects(under: scope, limit: 100)
        XCTAssertEqual(stored.total, 6, "only objects are stored")
        XCTAssertFalse(stored.items.contains { item in stored.items.contains { $0.path != item.path && item.path.hasPrefix($0.path + "/") } })
        let reports = try await index.count("review_reports")
        XCTAssertEqual(reports, 1)
        let latest = try await index.latestReport(scope: scope)
        XCTAssertEqual(latest?.coverage, "complete")
        await index.close()
    }

    func testAnEntryBudgetStopsWithAPartialReportAndACooldownThatSurvivesRelaunch() async throws {
        try makeFixture()
        let stewardURL = root.appending(path: "steward.sqlite")
        let stateURL = ReviewService.defaultStateURL(beside: stewardURL)
        let clock = MutableClock(Date(timeIntervalSince1970: 1_790_000_000))
        let index = try ReviewIndex(url: stewardURL)
        let small = ReviewService(index: index, stateURL: stateURL, now: { clock.now }) { previous, cancelled in
            ReviewWalker(decider: ClassifierObjectDecider(oracle: SilentRepositoryOracle()), budget: ReviewBudget(maximumEntries: 10),
                         previousCompleteEntries: previous, isCancelled: cancelled)
        }
        let report = try await small.review(scope: scope)
        XCTAssertEqual(report.status, .stopped(.entries))
        XCTAssertFalse(report.isComplete)
        XCTAssertFalse(report.uncoveredTopLevel.isEmpty, "a stopped review names what it did not cover")
        XCTAssertTrue(report.limitations.first?.contains("stopped (entries)") == true, "\(report.limitations)")
        let stored = try await index.latestReport(scope: scope)
        XCTAssertEqual(stored?.coverage, "partial")
        XCTAssertEqual(stored?.status, "stopped:entries")
        do { _ = try await small.review(scope: scope); XCTFail("a stopped scope cools down") }
        catch ReviewError.coolingDown(let until) {
            XCTAssertEqual(until.timeIntervalSince1970, report.completedAt.addingTimeInterval(ReviewService.cooldown).timeIntervalSince1970, accuracy: 0.001)
        }

        // A relaunch: a new service over the same files keeps the cooldown and resumes nothing.
        let relaunched = ReviewService(index: index, stateURL: stateURL, now: { clock.now }) { previous, cancelled in
            ReviewWalker(decider: ClassifierObjectDecider(oracle: SilentRepositoryOracle()), previousCompleteEntries: previous, isCancelled: cancelled)
        }
        do { _ = try await relaunched.review(scope: scope); XCTFail("the cooldown survives a relaunch") } catch ReviewError.coolingDown {}
        let afterStop = await relaunched.state(for: scope)
        XCTAssertNil(afterStop?.lastCompleteEntries, "a stop never sets the growth baseline")

        clock.now = clock.now.addingTimeInterval(ReviewService.cooldown + 60)
        let full = try await relaunched.review(scope: scope)
        XCTAssertEqual(full.status, .completed, "after the cooldown a new review starts from the beginning")
        XCTAssertGreaterThan(full.entriesVisited, report.entriesVisited)
        let baseline = await relaunched.state(for: scope)
        XCTAssertEqual(baseline?.lastCompleteEntries, full.entriesVisited)
        await index.close()
    }

    func testMoreThanTwiceThePreviousEntriesStopsTheReview() throws {
        try makeFixture()
        let first = walker().review(scope: scope)
        XCTAssertEqual(first.status, .completed)
        for index in 0..<(first.entriesVisited * 2) { try write("bulk/f\(index).txt", bytes: 10) }
        let second = walker(previous: first.entriesVisited).review(scope: scope)
        XCTAssertEqual(second.status, .stopped(.growth))
    }

    func testWallTimeAndMemoryBudgetsStopTheWalkInsideTheWorker() throws {
        try makeFixture()
        let ticks = Ticker(step: 5)
        let wall = walker(budget: ReviewBudget(wallSeconds: 12), clock: { ticks.next() }).review(scope: scope)
        XCTAssertEqual(wall.status, .stopped(.wallTime))
        let memory = Ticker(step: 300 * 1_024 * 1_024)
        let heavy = walker(footprint: { UInt64(memory.next()) }).review(scope: scope)
        XCTAssertEqual(heavy.status, .stopped(.memory))
    }

    func testARevisitedDirectoryStopsTheReview() throws {
        // A cycle the file system cannot produce: b lists a again.
        let reader = FakeReader(tree: [
            "/r": [.dir("a", 2)], "/r/a": [.dir("b", 3), .file("x", 4)], "/r/a/b": [.dir("a-again", 2)],
        ])
        let report = ReviewWalker(reader: reader, decider: NoObjects(), budget: ReviewBudget(wallSeconds: 5)).review(scope: "/r")
        XCTAssertEqual(report.status, .stopped(.revisit))
        XCTAssertEqual(report.uncoveredTopLevel, ["/r/a"])
    }

    func testUnreadableAndExcludedFoldersAreNamedNotCounted() throws {
        try makeFixture()
        try write("locked/secret.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: scope + "/locked")
        let report = walker().review(scope: scope, excluded: [scope + "/docs"])
        XCTAssertEqual(report.unreadableDirectories, 1)
        XCTAssertFalse(report.isComplete, "an unreadable folder makes coverage partial")
        XCTAssertEqual(report.excluded, [scope + "/docs"])
        XCTAssertFalse(report.unresolved.contains { $0.path.hasPrefix(scope + "/docs") }, "an excluded folder is not walked")
        XCTAssertTrue(report.uncoveredTopLevel.contains(scope + "/locked"))
    }

    func testTheIndexedOracleAnswersLikeGitPerPath() throws {
        let repository = scope + "/repo"
        try write("repo/.gitignore", bytes: 0)
        try Data("build/\nnode_modules\n*.log\ngenerated/\n!generated/keep/\n".utf8).write(to: URL(fileURLWithPath: repository + "/.gitignore"))
        try write("repo/generated/keep/a.txt")
        try write("repo/src/a.swift")
        try write("repo/vendor/lib.go")
        try write("repo/build/out.o")
        try write("repo/build/inner/deep.o")
        try write("repo/node_modules/x/index.js")
        try write("repo/untracked/notes.txt")
        try write("repo/logs/run.log")
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repository, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        }
        try git(["init", "-q"])
        try git(["add", ".gitignore", "src", "vendor"])
        try git(["commit", "-q", "-m", "fixture"])
        let indexed = IndexedRepositoryOracle()
        let perPath = GitRepositoryOracle()
        for relative in ["src", "vendor", "build", "build/inner", "node_modules", "node_modules/x", "untracked", "logs", "generated", "generated/keep"] {
            let path = repository + "/" + relative
            XCTAssertEqual(indexed.tracksContents(ofPath: path, repositoryPath: repository), perPath.tracksContents(ofPath: path, repositoryPath: repository), "tracked: \(relative)")
            XCTAssertEqual(indexed.ignores(path: path, repositoryPath: repository), perPath.ignores(path: path, repositoryPath: repository), "ignored: \(relative)")
        }
        XCTAssertEqual(indexed.processes, 2, "one listing and one ignore checker per repository, however many questions")
        XCTAssertNil(IndexedRepositoryOracle().ignores(path: scope + "/elsewhere", repositoryPath: scope + "/not-a-repo"), "no repository, no verdict")
        // Many repositories: at most a few checkers stay open at once.
        let many = IndexedRepositoryOracle()
        for index in 0..<(IndexedRepositoryOracle.maximumOpenCheckers + 3) {
            let other = scope + "/repo-\(index)"
            try write("repo-\(index)/build/x.o")
            try Data("build/\n".utf8).write(to: URL(fileURLWithPath: other + "/.gitignore"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", other, "init", "-q"]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(many.ignores(path: other + "/build", repositoryPath: other), true)
        }
        XCTAssertEqual(many.peakOpenCheckers, IndexedRepositoryOracle.maximumOpenCheckers)
    }

    func testTheIndexKeepsTheLargestTwentyThousandObjects() async throws {
        var tree: [String: [FakeReader.Item]] = ["/r": []]
        for index in 0..<(ReviewIndex.maximumObjects + 50) {
            tree["/r"]!.append(.dir("c\(index)", UInt64(10 + index)))
            tree["/r/c\(index)"] = [.file("CACHEDIR.TAG", UInt64(1_000_000 + index), bytes: Int64(4_096 * (index + 1)))]
        }
        let report = ReviewWalker(reader: FakeReader(tree: tree), decider: MarkerObjects()).review(scope: "/r")
        XCTAssertEqual(report.objects.count, ReviewIndex.maximumObjects + 50)
        let index = try ReviewIndex(url: root.appending(path: "steward.sqlite"))
        let written = try await index.record(report)
        XCTAssertEqual(written.objectsStored, ReviewIndex.maximumObjects)
        XCTAssertEqual(written.objectsOmitted, 50)
        let stored = try await index.objects(under: "/r", limit: 1)
        XCTAssertEqual(stored.total, ReviewIndex.maximumObjects)
        XCTAssertEqual(stored.items.first?.path, "/r/c\(ReviewIndex.maximumObjects + 49)", "largest first")
        let latest = try await index.latestReport(scope: "/r")
        XCTAssertEqual(latest?.truncated, true)
        XCTAssertTrue(latest?.limitations.first?.contains("largest") == true)
        await index.close()
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    private let step: Double
    init(step: Double) { self.step = step }
    func next() -> Double { lock.withLock { defer { value += step }; return value } }
}

/// A directory tree in memory, keyed by path, with fixed identities.
private struct FakeReader: DirectoryReader {
    enum Item {
        case dir(String, UInt64)
        case file(String, UInt64, bytes: Int64 = 4_096)
    }
    let tree: [String: [Item]]

    func identity(of path: String) -> FileIdentity? { FileIdentity(device: 1, fileID: 1) }

    func list(_ path: String) throws -> DirectoryListing {
        guard let items = tree[path] else { throw DirectoryReadError.unreadable(path: path, errno: ENOENT) }
        return DirectoryListing(entries: items.map { item in
            switch item {
            case let .dir(name, id):
                return DirectoryEntry(name: name, type: .directory, device: 1, fileID: id, linkCount: 1, allocatedBytes: 0, modified: 1)
            case let .file(name, id, bytes):
                return DirectoryEntry(name: name, type: .file, device: 1, fileID: id, linkCount: 1, allocatedBytes: bytes, modified: 1)
            }
        })
    }
}

private struct NoObjects: ReviewObjectDeciding {
    func isCandidateName(_ name: String) -> Bool { false }
    var selfMarkerNames: Set<String> { [] }
    var projectMarkerNames: Set<String> { [] }
    func classify(directoryPath: String, repositoryPath: String?) -> ObjectClassification {
        .unresolved(UnresolvedCandidate(path: directoryPath, name: "", reason: "test"))
    }
}

private struct MarkerObjects: ReviewObjectDeciding {
    func isCandidateName(_ name: String) -> Bool { false }
    var selfMarkerNames: Set<String> { ["CACHEDIR.TAG"] }
    var projectMarkerNames: Set<String> { [] }
    func classify(directoryPath: String, repositoryPath: String?) -> ObjectClassification {
        .object(ClassifiedObject(path: directoryPath, kind: .cache, rule: .selfMarker, confidence: .high, reason: "tagged"))
    }
}
