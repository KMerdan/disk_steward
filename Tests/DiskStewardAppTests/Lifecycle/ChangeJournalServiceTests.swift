@testable import DiskStewardApp
import DiskStewardCore
import Foundation
import XCTest

/// TASK-652: the service resumes the journal from its stored event ID across a
/// relaunch, and states a first start or a journal reset as a gap.
@MainActor
final class ChangeJournalServiceTests: XCTestCase {
    private var directory: URL!
    private var root: String!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp/ds-journal-service-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appending(path: "watched"), withIntermediateDirectories: true)
        root = DirectoryChangeStream.canonicalPath(directory.appending(path: "watched").path)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func everything(_ journal: ChangeJournal) async throws -> JournalWindow {
        try await journal.changes(from: .distantPast, through: .distantFuture, limit: 100)
    }

    func testRelaunchReplaysFromTheStoredCursorWithoutANewGap() async throws {
        let journal = try ChangeJournal(url: directory.appending(path: "steward.sqlite"))
        let first = ChangeJournalService(journal: journal, latency: 0.1)
        // Requested through the /tmp symlink; recorded under the real path.
        await first.restart(roots: [directory.appending(path: "watched").path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")])
        XCTAssertEqual(first.roots, [root])
        let uuid = try XCTUnwrap(first.journalUUID)
        let started = try await journal.cursor(journalUUID: uuid)
        XCTAssertNotNil(started, "the cursor starts before the stream")
        let startGaps = try await everything(journal).gaps.map(\.reason)
        XCTAssertEqual(startGaps, ["journal-started"])

        try FileManager.default.createDirectory(atPath: root + "/live/one", withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: root + "/live/one/file.txt"))
        // Recorded, then checkpointed, then noted: wait for the last step.
        try await eventually {
            try await self.everything(journal).changes.items.contains { $0.path == self.root + "/live/one" } && first.recordedEventID != nil
        }
        await first.checkpoint()
        let recorded = try XCTUnwrap(first.recordedEventID)
        let stored = try await journal.cursor(journalUUID: uuid)
        let persisted = try XCTUnwrap(stored)
        XCTAssertGreaterThanOrEqual(persisted, recorded, "the sample checkpoint persists at least the newest recorded event")
        first.stop()

        // Changes while the app is not running.
        try FileManager.default.createDirectory(atPath: root + "/offline/two", withIntermediateDirectories: true)
        try Data([2]).write(to: URL(fileURLWithPath: root + "/offline/two/file.txt"))
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let relaunched = ChangeJournalService(journal: journal, latency: 0.1)
        await relaunched.restart(roots: [root])
        defer { relaunched.stop() }
        try await eventually(seconds: 20) { relaunched.historyDone }
        try await eventually(seconds: 20) { try await self.everything(journal).changes.items.contains { $0.path == self.root + "/offline/two" } }
        let gaps = try await everything(journal).gaps.map(\.reason)
        XCTAssertEqual(gaps, ["journal-started"], "a replayed relaunch leaves no blind interval")
    }

    func testANewJournalIdentityIsReportedAsAReset() async throws {
        let journal = try ChangeJournal(url: directory.appending(path: "steward.sqlite"))
        try await journal.checkpoint(journalUUID: "A-VOLUME-THAT-WAS-ERASED", eventID: 42, at: Date())
        let service = ChangeJournalService(journal: journal, latency: 0.1)
        await service.restart(roots: [root])
        defer { service.stop() }
        let gaps = try await everything(journal).gaps.map(\.reason)
        XCTAssertEqual(gaps, ["journal-reset"], "earlier history is unknown, not unchanged")
    }

    private func eventually(seconds: TimeInterval = 10, _ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("condition not reached within \(seconds) s")
    }
}
