import CoreServices
import Darwin
@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-672: a session's impact is the change journal's dirty directories at,
/// inside or above its workspace during its window, capped at 200 directories
/// and 500 sessions, with no per-file rows.
final class SessionImpactTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp/ds-sessions-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func change(_ path: String, _ changes: Int64 = 1) -> JournalChange {
        JournalChange(path: path, changes: changes, firstInterval: Date(timeIntervalSince1970: 0), lastInterval: Date(timeIntervalSince1970: 300))
    }

    func testRelationsAtInsideAndAboveTheWorkspace() {
        let roots = ["/h/code/web/packages/api"]
        XCTAssertEqual(SessionRelation.of("/h/code/web/packages/api", roots: roots)?.relation, .at)
        XCTAssertEqual(SessionRelation.of("/h/code/web/packages/api/node_modules", roots: roots)?.relation, .inside)
        XCTAssertEqual(SessionRelation.of("/h/code/web", roots: roots)?.relation, .containsWorkspace)
        XCTAssertNil(SessionRelation.of("/h/code/web/packages/apifoo", roots: roots), "a sibling with the same prefix is outside")
        XCTAssertNil(SessionRelation.of("/h/code/engine", roots: roots))
        XCTAssertEqual(SessionRelation.of("/h/code/web/packages/api/src", roots: ["/h/code/web", "/h/code/web/packages/api"])?.root,
                       "/h/code/web/packages/api", "the closest root wins")
    }

    /// Two sessions in sibling folders of one project: a change collapsed to
    /// the project folder is coarser than either workspace and shared by both;
    /// a change inside one workspace is that session's alone; a change in
    /// another project is neither's.
    func testOverlappingAndDisjointSessions() {
        let api = ["/h/code/web/packages/api"]
        let site = ["/h/code/web/packages/site"]
        let changes = [change("/h/code/web", 9), change("/h/code/web/packages/api/node_modules", 4), change("/h/code/engine", 7), change("/h", 50)]
        let forAPI = SessionImpact.directories(changes: changes, roots: api, watchedRoots: ["/h"], others: [site])
        XCTAssertEqual(forAPI.items.map(\.path), ["/h/code/web", "/h/code/web/packages/api/node_modules"])
        XCTAssertEqual(forAPI.items.map(\.relation), [.containsWorkspace, .inside])
        XCTAssertEqual(forAPI.items.map(\.alsoActiveSessions), [1, 0], "the project folder is shared; the api's own folder is not")
        XCTAssertEqual(forAPI.overflow.map(\.path), ["/h"], "a row at the watched root contains every workspace and is reported apart")
        let forSite = SessionImpact.directories(changes: changes, roots: site, watchedRoots: ["/h"], others: [api])
        XCTAssertEqual(forSite.items.map(\.path), ["/h/code/web"], "the api's node_modules is not the site's")
        XCTAssertEqual(forSite.items.first?.alsoActiveSessions, 1)
    }

    func testAtMost200DirectoriesWithTheTotalStated() {
        let changes = (0..<250).map { change("/w/dir-\($0)", Int64(1_000 - $0)) }
        let directories = SessionImpact.directories(changes: changes, roots: ["/w"], watchedRoots: [], others: [], limit: 500)
        XCTAssertEqual(directories.items.count, 200)
        XCTAssertEqual(directories.total, 250)
        XCTAssertEqual(directories.items.first?.path, "/w/dir-0", "most changes first")
    }

    /// The journal answers for a set of roots without returning unrelated
    /// rows, so a busy volume cannot crowd a session's directories out.
    func testTheJournalReturnsOnlyRowsRelatedToTheRoots() async throws {
        let journal = try ChangeJournal(url: directory.appending(path: "steward.sqlite"))
        let modified = UInt32(kFSEventStreamEventFlagItemModified)
        var events: [(String, UInt32, UInt64)] = [("/r/proj/web/packages/api/src/a", modified, 1), ("/r/other/thing/x", modified, 2)]
        events += (0..<300).map { ("/r/busy/n\($0)/y", modified, UInt64(10 + $0)) }
        try await journal.record(DirectoryChangeBatch.interpret(events), roots: ["/r"], at: Date())
        let window = try await journal.changes(from: Date().addingTimeInterval(-600), through: Date(), relatedTo: ["/r/proj/web/packages/api"], limit: 10)
        XCTAssertEqual(window.changes.items.map(\.path), ["/r/proj/web"], "collapsed two levels below the root, above the workspace")
        XCTAssertEqual(window.changes.total, 1)
        await journal.close()
    }

    func testTheStoreKeepsLongIDsAndManyRootsWithinItsColumns() async throws {
        let store = try SessionStore(url: directory.appending(path: "steward.sqlite"))
        let longID = String(repeating: "x", count: 200)
        XCTAssertEqual(SessionStore.key(longID).utf8.count, 64)
        XCTAssertEqual(SessionStore.key("short"), "short")
        let roots = (0..<32).map { "/Users/someone/projects/a-rather-long-folder-name-for-testing-\($0)" }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.record(sessionID: longID, client: "codex", roots: roots, startedAt: start, endsAt: start.addingTimeInterval(600))
        let kept = try await store.sessions(sessionID: longID)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept[0].rootsTruncated, "32 long roots do not fit 1 KiB")
        XCTAssertFalse(kept[0].roots.isEmpty)
        XCTAssertEqual(kept[0].roots, Array(roots.prefix(kept[0].roots.count)), "whole roots, in order")
        // A refresh replaces the row instead of adding one.
        try await store.record(sessionID: longID, client: "codex", roots: ["/a"], startedAt: start, endsAt: start.addingTimeInterval(900))
        let refreshed = try await store.sessions(sessionID: longID)
        XCTAssertEqual(refreshed.map(\.roots), [["/a"]])
        XCTAssertEqual(refreshed.first?.endsAt, start.addingTimeInterval(900))
        await store.close()
    }

    /// 500 sessions are kept; the oldest goes first and takes its kept
    /// impact with it.
    func testTheOldestSessionLeavesWithItsImpact() async throws {
        let store = try SessionStore(url: directory.appending(path: "steward.sqlite"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.record(sessionID: "first", client: "codex", roots: ["/w"], startedAt: start, endsAt: start.addingTimeInterval(60))
        try await store.freeze(sessionID: "first", startedAt: start, directories: [
            SessionDirectory(path: "/w/a", relation: .inside, root: "/w", changes: 3, firstInterval: nil, lastInterval: nil, alsoActiveSessions: 0),
        ])
        let frozenBefore = try await store.frozen(sessionID: "first", startedAt: start)
        XCTAssertEqual(frozenBefore?.map(\.path), ["/w/a"])
        for index in 1...SessionStore.maximumSessions {
            let at = start.addingTimeInterval(Double(index) * 60)
            try await store.record(sessionID: "s-\(index)", client: "claude", roots: ["/w"], startedAt: at, endsAt: at.addingTimeInterval(60))
        }
        let count = try await store.count()
        XCTAssertEqual(count, SessionStore.maximumSessions)
        let first = try await store.sessions(sessionID: "first")
        XCTAssertTrue(first.isEmpty, "the oldest session left")
        let frozen = try await store.frozen(sessionID: "first", startedAt: start)
        XCTAssertNil(frozen, "and its impact with it")
        await store.close()
    }

    func testTheRegistryKeepsAtMost500SessionsInMemory() async throws {
        let digest = String(repeating: "a", count: 64)
        let registry = AgentSessionRegistry(expectedPeerUID: getuid(), expectedChallengeDigest: digest)
        let proof = SessionAuthenticationProof(peerUID: getuid(), socketMode: 0o600, challengeDigest: digest)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var first: AgentSessionRegistration?
        for index in 0...AgentSessionRegistry.maximumRegistrations {
            let at = now.addingTimeInterval(Double(index))
            let registration = try await registry.register(SessionRegistrationRequest(
                client: .codex, sessionID: "s-\(index)", process: ProcessIdentity(pid: Int32(1_000 + index), startTime: at),
                workspaceRoots: ["/w"], registeredAt: at, expiresAt: at.addingTimeInterval(3_600)), proof: proof, now: at)
            _ = try await registry.end(registrationID: registration.registrationID, proof: proof, now: at)
            if index == 0 { first = registration }
        }
        let all = try await registry.historicalRegistrations(proof: proof, now: now.addingTimeInterval(1_000))
        XCTAssertEqual(all.count, AgentSessionRegistry.maximumRegistrations)
        XCTAssertFalse(all.contains { $0.registrationID == first?.registrationID }, "the oldest ended session went first")
    }
}
