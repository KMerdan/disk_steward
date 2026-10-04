@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-622: ranking is reproducible from recorded inputs, idleness comes from
/// the owning project (never the object's own timestamp), every item carries
/// a rebuild command or an explicit unknown, and every item stays review-required.
final class ReviewRankingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_200_000)
    private let gib: Int64 = 1_073_741_824
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/ds-rank-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func days(_ value: Double) -> TimeInterval { now.timeIntervalSince1970 - value * 86_400 }

    private func object(_ path: String, _ bytes: Int64, project: String?, kind: ClassifiedObjectKind = .artifact,
                        recreate: RecreateClass = .rebuild, touched: TimeInterval? = nil) -> ReviewObject {
        ReviewObject(path: path, kind: kind, rule: .manifest, reason: "a manifest beside it expects this output location",
                     projectPath: project, recreateClass: recreate, allocatedBytes: bytes, fileCount: 10,
                     lastActivity: touched ?? now.timeIntervalSince1970)
    }

    private func report(_ objects: [ReviewObject], projects: [ReviewProject]) -> ReviewReport {
        ReviewReport(reportID: "r", scope: "/s", startedAt: now, completedAt: now, status: .completed, entriesVisited: 1, directoriesVisited: 1,
                     scopeAllocatedBytes: 0, objects: objects, projects: projects, unresolved: [], unresolvedCount: 0, unreadableDirectories: 0,
                     unreadableEntries: 0, skippedMounts: [], excluded: [], coveredTopLevel: [], uncoveredTopLevel: [], classifierCalls: 0,
                     repositoryQueries: 0, repositoryQuerySeconds: 0, repositoryProcesses: 0)
    }

    func testRankingIsReproducibleFromRecordedInputs() {
        let projects = [
            ReviewProject(path: "/s/old", marker: "Cargo.toml", lastSourceActivity: days(200), tools: ["cargo"]),
            ReviewProject(path: "/s/mid", marker: "package.json", lastSourceActivity: days(45), tools: ["node", "pnpm"]),
            ReviewProject(path: "/s/live", marker: ".git", lastSourceActivity: days(0.1), tools: ["node", "npm"]),
        ]
        let input = report([
            object("/s/old/target", 3 * gib, project: "/s/old"),
            // Scores: target 3 x 1.0 x 0.92 = 2.76; idle node_modules 3 x 0.4 = 1.2;
            // active node_modules 4 x 0.2004 = 0.80; .next 1 x 0.4 x 0.92 = 0.37.
            object("/s/mid/node_modules", 3 * gib, project: "/s/mid", recreate: .redownload),
            object("/s/live/node_modules", 4 * gib, project: "/s/live", recreate: .redownload),
            object("/s/live/.git", 9 * gib, project: "/s/live", kind: .repository, recreate: .liveState),
            object("/s/mid/.next", 1 * gib, project: "/s/mid"),
        ], projects: projects)
        let first = ReviewRanking.rank(input, now: now)
        let second = ReviewRanking.rank(input, now: now)
        XCTAssertEqual(first, second, "the same recorded inputs give the same ranking")
        XCTAssertEqual(first.map(\.object.path), ["/s/old/target", "/s/mid/node_modules", "/s/live/node_modules", "/s/mid/.next"])
        XCTAssertEqual(first.map(\.rank), [1, 2, 3, 4])
    }

    func testAFreshlyRebuiltObjectNeverOutranksAnEquallySizedLongIdleOne() {
        // The idle project's object was rebuilt this morning: its own timestamp is fresh,
        // but its project has not changed for 40 days. Project activity decides.
        let projects = [
            ReviewProject(path: "/s/a-active", marker: "Cargo.toml", lastSourceActivity: days(0.1), tools: ["cargo"]),
            ReviewProject(path: "/s/b-idle", marker: "Cargo.toml", lastSourceActivity: days(40), tools: ["cargo"]),
        ]
        let ranked = ReviewRanking.rank(report([
            object("/s/a-active/target", 5 * gib, project: "/s/a-active", touched: days(30)),
            object("/s/b-idle/target", 5 * gib, project: "/s/b-idle", touched: days(0)),
        ], projects: projects), now: now)
        XCTAssertEqual(ranked.first?.object.path, "/s/b-idle/target")
        XCTAssertEqual(ranked.first?.projectIdleDays ?? 0, 40, accuracy: 0.01)

        // Every pairing of a project changed within a day against one idle 30 days or more.
        for fresh in [0.0, 0.5, 1.0] {
            for idle in [30.0, 90.0, 365.0] {
                for freshClass in [RecreateClass.rebuild, .redownload] {
                    for idleClass in [RecreateClass.rebuild, .redownload] {
                        let pair = ReviewRanking.rank(report([
                            object("/s/a/out", gib, project: "/s/a", recreate: freshClass),
                            object("/s/b/out", gib, project: "/s/b", recreate: idleClass),
                        ], projects: [
                            ReviewProject(path: "/s/a", marker: "package.json", lastSourceActivity: days(fresh)),
                            ReviewProject(path: "/s/b", marker: "package.json", lastSourceActivity: days(idle)),
                        ]), now: now)
                        XCTAssertEqual(pair.first?.object.path, "/s/b/out", "fresh \(fresh) d \(freshClass) vs idle \(idle) d \(idleClass)")
                    }
                }
            }
        }
    }

    func testEveryItemCarriesACommandOrAnExplicitUnknownAndStaysReviewRequired() {
        let projects = [
            ReviewProject(path: "/s/web", marker: "package.json", lastSourceActivity: days(10), tools: ["node", "pnpm"]),
            ReviewProject(path: "/s/rust", marker: "Cargo.toml", lastSourceActivity: days(10), tools: ["cargo"]),
            ReviewProject(path: "/s/py", marker: "pyproject.toml", lastSourceActivity: days(10), tools: ["python", "uv"]),
            ReviewProject(path: "/s/misc", marker: ".git", lastSourceActivity: days(10)),
        ]
        let ranked = ReviewRanking.rank(report([
            object("/s/web/node_modules", 5 * gib, project: "/s/web", recreate: .redownload),
            object("/s/rust/target", 4 * gib, project: "/s/rust"),
            object("/s/py/.venv", 3 * gib, project: "/s/py"),
            object("/s/py/__pycache__", gib, project: "/s/py"),
            object("/s/misc/build", gib, project: "/s/misc"),
            object("/s/misc/.cache", gib, project: "/s/misc", kind: .cache, recreate: .redownload),
            object("/s/misc/.git", 20 * gib, project: "/s/misc", kind: .repository, recreate: .liveState),
        ], projects: projects), now: now)
        let commands = Dictionary(uniqueKeysWithValues: ranked.map { ($0.object.path, $0) })
        XCTAssertNil(commands["/s/misc/.git"], "a repository is measured, never ranked")
        XCTAssertEqual(commands["/s/web/node_modules"]?.rebuildCommand, "pnpm install")
        XCTAssertEqual(commands["/s/rust/target"]?.rebuildCommand, "cargo build")
        XCTAssertEqual(commands["/s/py/.venv"]?.rebuildCommand, "uv sync")
        XCTAssertEqual(commands["/s/misc/build"]?.rebuildCommandKnown, false)
        XCTAssertTrue(commands["/s/misc/build"]?.rebuildCommand.hasPrefix("Unknown:") == true, "an unknown command is said, not guessed")
        for item in ranked {
            XCTAssertFalse(item.rebuildCommand.isEmpty, item.object.path)
            XCTAssertEqual(item.state, .reviewRequired, "never a delete verdict")
            XCTAssertTrue(item.reasons.contains { $0.contains("last changed 10 days ago") }, "\(item.reasons)")
        }
    }

    func testAMonorepoLockfileAboveThePackageNamesTheManager() {
        let ranked = ReviewRanking.rank(report([object("/s/repo/packages/web/node_modules", gib, project: "/s/repo/packages/web", recreate: .redownload)], projects: [
            ReviewProject(path: "/s/repo", marker: ".git", lastSourceActivity: days(5), tools: ["pnpm"]),
            ReviewProject(path: "/s/repo/packages/web", marker: "package.json", lastSourceActivity: days(5), tools: ["node"]),
        ]), now: now)
        XCTAssertEqual(ranked.first?.rebuildCommand, "pnpm install")
    }

    func testRevalidationMarksItemsThatAreGone() throws {
        let present = root.appending(path: "p/target")
        let gone = root.appending(path: "q/target")
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let ranked = ReviewRanking.rank(report([object(present.path, gib, project: nil), object(gone.path, gib / 2, project: nil)], projects: []), now: now)
        try FileManager.default.removeItem(at: gone)
        let later = now.addingTimeInterval(3_600)
        let checked = Dictionary(uniqueKeysWithValues: ReviewRanking.revalidate(ranked, at: later).map { ($0.object.path, $0) })
        XCTAssertEqual(checked[present.path]?.state, .reviewRequired)
        XCTAssertEqual(checked[gone.path]?.state, .missing)
        XCTAssertEqual(checked[present.path]?.verifiedAt, later)
    }

    func testTheReviewStoresRankedItemsWithTheirCommands() async throws {
        let scope = root.appending(path: "scope").path
        func write(_ relative: String, bytes: Int = 4_096) throws {
            let url = URL(fileURLWithPath: scope + "/" + relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }
        try write("web/package.json", bytes: 100)
        try write("web/pnpm-lock.yaml", bytes: 100)
        try write("web/src/index.ts", bytes: 2_000)
        try write("web/node_modules/.modules.yaml", bytes: 100)
        try write("web/node_modules/a/package.json", bytes: 100)
        try write("web/node_modules/a/index.js", bytes: 90_000)
        try write("rust/Cargo.toml", bytes: 100)
        try write("rust/target/debug/app", bytes: 400_000)
        let index = try ReviewIndex(url: root.appending(path: "steward.sqlite"))
        let service = ReviewService(index: index, stateURL: root.appending(path: "review-state.json"), makeWalker: { previous, cancelled in
            ReviewWalker(decider: ClassifierObjectDecider(oracle: SilentRepositoryOracle()), previousCompleteEntries: previous, isCancelled: cancelled)
        })
        let report = try await service.review(scope: scope)
        XCTAssertEqual(report.projects.first { $0.path.hasSuffix("/web") }?.tools, ["node", "pnpm"], "the walker records the project's tools")
        let items = try await index.items(reportID: report.reportID, limit: 10)
        XCTAssertEqual(items.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["target", "node_modules"])
        XCTAssertEqual(items.map(\.rank), [1, 2])
        XCTAssertEqual(items.first?.detail.command, "cargo build")
        XCTAssertEqual(items.last?.detail.command, "pnpm install")
        XCTAssertTrue(items.allSatisfy { $0.state == "review-required" })
        XCTAssertFalse(items.first?.detail.reasons.isEmpty ?? true)
        await index.close()
    }
}
