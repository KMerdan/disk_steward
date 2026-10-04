import CoreServices
@testable import DiskStewardApp
import DiskStewardCore
import Foundation
import XCTest

/// TASK-661: `explain_growth` reports per-object deltas from the last measured
/// size, the attributed total, the unexplained remainder and journal gaps.
final class ExplainGrowthAttributionTests: XCTestCase {
    private var directory: URL!
    private var scope: String!
    private let mib: Int64 = 1_048_576

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp/ds-explain-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scope = DirectoryChangeStream.canonicalPath(directory.path + "/scope")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func write(_ relative: String, bytes: Int) throws {
        let url = directory.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 9, count: bytes).write(to: url)
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

    /// A reviewed project whose node_modules then grows by 5 MiB, with a
    /// journal change for it and 12 MiB of growth elsewhere on the volume.
    private func fixture() async throws -> (service: GrowthAttributionService, growth: Int64, outside: Int64, journal: ChangeJournal, index: ReviewIndex) {
        try write("scope/web/package.json", bytes: 100)
        try write("scope/web/pnpm-lock.yaml", bytes: 100)
        try write("scope/web/node_modules/.modules.yaml", bytes: 100)
        try write("scope/web/node_modules/a/index.js", bytes: Int(mib))
        let steward = directory.appending(path: "steward.sqlite")
        let index = try ReviewIndex(url: steward)
        try await index.record(ReviewWalker(decider: ClassifierObjectDecider(oracle: SilentRepositoryOracle())).review(scope: scope))
        let before = try du(scope + "/web/node_modules")
        let journal = try ChangeJournal(url: steward)
        let modified = UInt32(kFSEventStreamEventFlagItemModified)
        try await journal.record(DirectoryChangeBatch.interpret([(scope + "/web/node_modules/b", modified, 50)]), roots: [directory.path], at: Date().addingTimeInterval(-600))
        try await journal.recordGap(reason: "MustScanSubDirs", path: scope, at: Date().addingTimeInterval(-300))
        try write("scope/web/node_modules/b/big.js", bytes: 5 * Int(mib))
        let growth = try du(scope + "/web/node_modules") - before
        let outside = 12 * mib
        let coverage = try await journal.coverageStart()
        let ringURL = directory.appending(path: "capacity.sqlite")
        let ring = try CapacityRing(url: ringURL)
        let total: Int64 = 1_000 * 1_024 * mib
        try await ring.record(volumeUUID: "UUID-data", mountPath: "/System/Volumes/Data", totalBytes: total, availableBytes: total - 300_000 * mib,
                              at: try XCTUnwrap(coverage).addingTimeInterval(1))
        try await ring.record(volumeUUID: "UUID-data", mountPath: "/System/Volumes/Data", totalBytes: total, availableBytes: total - 300_000 * mib - growth - outside,
                              at: Date().addingTimeInterval(-1))
        await ring.close()
        let service = GrowthAttributionService(journal: journal, index: index, ringURL: ringURL,
                                               fileURL: GrowthAttributionService.defaultFileURL(beside: steward))
        await service.observe(usedBytes: 0, volumeUUID: "UUID-data", thresholdBytes: .max)
        return (service, growth, outside, journal, index)
    }

    private func explain(_ backend: AppEvidenceQueryBackend, from: Date, through: Date) throws -> [String: JSONValue] {
        let socket = directory.appending(path: "ipc/s.sock")
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: backend)
        try server.start()
        defer { server.stop() }
        let formatter = ISO8601DateFormatter()
        let value = try UnixSocketDiskStewardIPCClient(socketPath: socket.path).call(tool: "explain_growth", arguments: [
            "from": .string(formatter.string(from: from)), "through": .string(formatter.string(from: through)), "path_detail": .string("full"),
        ], isCancelled: { false })
        return try XCTUnwrap(value.objectValue)
    }

    private func backend(_ service: GrowthAttributionService?) throws -> AppEvidenceQueryBackend {
        try AppEvidenceQueryBackend(databaseURL: directory.appending(path: "evidence.sqlite"), capacityRingURL: directory.appending(path: "capacity.sqlite"),
                                    changeJournalURL: directory.appending(path: "steward.sqlite"), fileDetail: .retired(supportDirectory: directory),
                                    growthAttribution: service)
    }

    private func array(_ value: JSONValue?) -> [JSONValue] {
        if case let .array(values)? = value { return values }
        return []
    }

    func testAQuestionReachingThePresentIsAnsweredWithMeasuredDeltas() async throws {
        let (service, growth, outside, journal, index) = try await fixture()
        let now = Date()
        let object = try explain(try backend(service), from: now.addingTimeInterval(-7_200), through: now)
        let measured = try XCTUnwrap(object["measured_growth"]?.objectValue)
        XCTAssertEqual(measured["status"], .string("measured"))
        XCTAssertEqual(measured["attributed_bytes"], .integer(growth))
        XCTAssertEqual(measured["volume_delta_bytes"], .integer(growth + outside))
        XCTAssertEqual(measured["unexplained_bytes"], .integer(outside), "the growth elsewhere is unexplained")
        XCTAssertTrue(measured["remainder_covers"]?.stringValue?.contains("System Data") == true)
        XCTAssertEqual(measured["complete"], .bool(false), "the journal gap keeps it from being complete")
        let attribution = try XCTUnwrap(array(measured["attributions"]).first?.objectValue)
        XCTAssertEqual(attribution["trigger"], .string("request"))
        let objects = array(attribution["objects"]).compactMap(\.objectValue)
        XCTAssertEqual(objects.first?["path"], .string(scope + "/web/node_modules"))
        XCTAssertEqual(objects.first?["basis"], .string("measured"))
        XCTAssertEqual(objects.first?["delta_bytes"], .integer(growth))
        XCTAssertNotNil(objects.first?["previous_measured_at"]?.stringValue, "the delta says what it is measured from")
        XCTAssertEqual(array(attribution["journal_gaps"]).first?.objectValue?["reason"], .string("MustScanSubDirs"))
        // The changed directory now says it was measured.
        let changed = array(object["changed_directories"]?.objectValue?["items"]).compactMap(\.objectValue)
        let web = try XCTUnwrap(changed.first { $0["path"] == .string(scope + "/web") })
        XCTAssertEqual(web["measured"], .bool(true))
        XCTAssertEqual(web["measured_delta_bytes"], .integer(growth))
        await journal.close()
        await index.close()
    }

    func testAnEarlierWindowUsesOnlyStoredAttributions() async throws {
        let (service, _, _, journal, index) = try await fixture()
        let backend = try backend(service)
        let earlier = Date().addingTimeInterval(-3 * 3_600)
        let none = try XCTUnwrap(try explain(backend, from: earlier.addingTimeInterval(-3_600), through: earlier)["measured_growth"]?.objectValue)
        XCTAssertEqual(none["status"], .string("none"), "a window in the past is not measured now")
        let count = await service.attributions.count
        XCTAssertEqual(count, 0)
        _ = try await service.attribute(trigger: .threshold, budget: .default)
        let stored = try XCTUnwrap(try explain(backend, from: Date().addingTimeInterval(-7_200), through: Date())["measured_growth"]?.objectValue)
        let attribution = try XCTUnwrap(array(stored["attributions"]).first?.objectValue)
        XCTAssertEqual(attribution["trigger"], .string("threshold"), "a recent threshold attribution is reused, not measured again")
        let after = await service.attributions.count
        XCTAssertEqual(after, 1)
        await journal.close()
        await index.close()
    }

    func testWithoutAttributionTheAnswerSaysSo() async throws {
        let (_, _, _, journal, index) = try await fixture()
        let now = Date()
        let object = try explain(try backend(nil), from: now.addingTimeInterval(-7_200), through: now)
        let measured = try XCTUnwrap(object["measured_growth"]?.objectValue)
        XCTAssertEqual(measured["status"], .string("unavailable"))
        let changed = array(object["changed_directories"]?.objectValue?["items"]).compactMap(\.objectValue)
        XCTAssertTrue(changed.allSatisfy { $0["measured"] == .bool(false) })
        await journal.close()
        await index.close()
    }
}
