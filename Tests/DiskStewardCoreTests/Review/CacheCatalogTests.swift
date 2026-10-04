@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-631: the catalog names each required cache with how it is recreated
/// and the owning tool's own cleanup command (text, never run), and a cache is
/// read only after the user opts it into review.
final class CacheCatalogTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: "/private/tmp/ds-catalog-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func write(_ relative: String, bytes: Int = 8_192) throws {
        let url = home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: bytes).write(to: url)
    }

    /// A home with every catalog cache present.
    private func makeHome() throws {
        try write(".cache/uv/wheels/a.whl", bytes: 300_000)
        try FileManager.default.linkItem(atPath: home.path + "/.cache/uv/wheels/a.whl", toPath: home.path + "/.cache/uv/wheels/a-link.whl")
        try write(".npm/_cacache/content/x", bytes: 50_000)
        try write("Library/pnpm/store/v3/files/00/y", bytes: 40_000)
        try write("Library/Caches/com.example.app/cache.db", bytes: 70_000)
        try write("Library/Developer/CoreSimulator/Devices/D1/data/app.db", bytes: 500_000)
        try write("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", bytes: 90_000)
        try write("Library/Developer/Xcode/Archives/2026-10-01/App.xcarchive/Info.plist", bytes: 4_000)
        try write(".ollama/models/blobs/sha256-1", bytes: 900_000)
        try write(".docker/config.json", bytes: 100)
        try write(".cache/actcache/cache.json", bytes: 2_000)
    }

    private final class CountingReader: DirectoryReader, @unchecked Sendable {
        private let base = BulkDirectoryReader()
        private let lock = NSLock()
        private(set) var listed: [String] = []
        func identity(of path: String) -> FileIdentity? { base.identity(of: path) }
        func list(_ path: String) throws -> DirectoryListing {
            lock.withLock { listed.append(path) }
            return try base.list(path)
        }
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

    func testTheCatalogNamesEveryRequiredCacheWithAClassAndACommand() {
        let entries = Dictionary(uniqueKeysWithValues: CacheCatalog.entries.map { ($0.id, $0) })
        XCTAssertEqual(Set(entries.keys), ["uv", "npm", "pnpm", "library-caches", "coresimulator", "xcode-deriveddata", "xcode-archives", "ollama", "docker", "actcache"])
        XCTAssertEqual(entries["uv"]?.cleanupCommand, "uv cache prune")
        XCTAssertEqual(entries["npm"]?.cleanupCommand, "npm cache clean --force")
        XCTAssertEqual(entries["pnpm"]?.cleanupCommand, "pnpm store prune")
        XCTAssertEqual(entries["coresimulator"]?.cleanupCommand, "xcrun simctl delete unavailable")
        XCTAssertEqual(entries["ollama"]?.cleanupCommand, "ollama rm <model>")
        XCTAssertEqual(entries["coresimulator"]?.recreateClass, .expensive)
        XCTAssertEqual(entries["xcode-archives"]?.recreateClass, .expensive)
        XCTAssertEqual(entries["ollama"]?.recreateClass, .expensive)
        XCTAssertEqual(entries["xcode-deriveddata"]?.recreateClass, .rebuild)
        XCTAssertEqual(entries["uv"]?.recreateClass, .redownload)
        for entry in entries.values {
            XCTAssertFalse(entry.cleanupCommand.isEmpty, entry.id)
            XCTAssertFalse(entry.note.isEmpty, entry.id)
            XCTAssertNotEqual(entry.recreateClass, .liveState, "a catalog cache is never live state")
        }
    }

    func testOnlyOptedInCachesAreEverRead() throws {
        try makeHome()
        let nothing = CountingReader()
        let none = ReviewWalker(reader: nothing).reviewCatalog(CacheCatalog.targets(optedIn: [], home: home.path))
        XCTAssertTrue(nothing.listed.isEmpty, "with nothing opted in, no cache is read")
        XCTAssertTrue(none.objects.isEmpty)

        let reader = CountingReader()
        let report = ReviewWalker(reader: reader).reviewCatalog(CacheCatalog.targets(optedIn: ["uv", "ollama"], home: home.path))
        XCTAssertEqual(Set(report.objects.map { URL(fileURLWithPath: $0.path).lastPathComponent }), ["uv", ".ollama"])
        let allowed = [home.path + "/.cache/uv", home.path + "/.ollama"]
        XCTAssertFalse(reader.listed.isEmpty)
        for path in reader.listed {
            XCTAssertTrue(allowed.contains { path == $0 || path.hasPrefix($0 + "/") }, "read outside the opted-in caches: \(path)")
        }
        XCTAssertEqual(report.status, .completed)
        XCTAssertEqual(report.scope, CacheCatalog.scope)
    }

    func testCatalogSizesMatchDu() throws {
        try makeHome()
        let all = Set(CacheCatalog.entries.map(\.id))
        let report = ReviewWalker().reviewCatalog(CacheCatalog.targets(optedIn: all, home: home.path))
        XCTAssertEqual(report.objects.count, 10, "every present cache measured once")
        for object in report.objects {
            XCTAssertEqual(object.allocatedBytes, try du(object.path), "\(object.path) like du (hard links once)")
            XCTAssertEqual(object.rule, .catalog)
            XCTAssertNotNil(object.cleanupCommand)
        }
    }

    func testUnreadableFoldersInsideACacheAreStatedNotFatal() throws {
        try makeHome()
        try write("Library/Caches/com.locked.app/secret.db", bytes: 20_000)
        let locked = home.path + "/Library/Caches/com.locked.app"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let report = ReviewWalker().reviewCatalog(CacheCatalog.targets(optedIn: ["library-caches"], home: home.path))
        let caches = try XCTUnwrap(report.objects.first, "a cache with an unreadable folder is still measured")
        XCTAssertEqual(caches.unreadableDirectories, 1)
        XCTAssertEqual(caches.allocatedBytes, try du(home.path + "/Library/Caches"), "the readable rest, as du counts it")
        XCTAssertFalse(report.isComplete, "coverage is partial")
        XCTAssertTrue(ReviewRanking.rank(report, now: Date()).first?.reasons.contains { $0.contains("could not be read") } == true)
    }

    func testCatalogItemsRankByLastUseAndCarryTheToolsCleanupCommand() throws {
        try makeHome()
        let old = Date().addingTimeInterval(-200 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: home.path + "/.npm/_cacache/content/x")
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: home.path + "/.npm/_cacache/content")
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: home.path + "/.npm/_cacache")
        let report = ReviewWalker().reviewCatalog(CacheCatalog.targets(optedIn: ["npm", "coresimulator"], home: home.path))
        let ranked = ReviewRanking.rank(report, now: Date())
        let byName = Dictionary(uniqueKeysWithValues: ranked.map { (URL(fileURLWithPath: $0.object.path).lastPathComponent, $0) })
        XCTAssertEqual(byName[".npm"]?.cleanupCommand, "npm cache clean --force")
        XCTAssertEqual(byName["CoreSimulator"]?.cleanupCommand, "xcrun simctl delete unavailable")
        XCTAssertGreaterThan(byName[".npm"]?.projectIdleDays ?? 0, 150, "idleness of a cache is its own last use")
        XCTAssertTrue(byName[".npm"]?.reasons.contains { $0.hasPrefix("It was last used") } == true)
        XCTAssertTrue(byName["CoreSimulator"]?.rebuildCommand.hasPrefix("Expensive to recreate") == true)
        XCTAssertTrue(ranked.allSatisfy { $0.state == .reviewRequired })
    }

    func testTheServiceStoresCatalogItemsWithTheirCleanupCommands() async throws {
        try makeHome()
        let index = try ReviewIndex(url: home.appending(path: "steward.sqlite"))
        let service = ReviewService(index: index, stateURL: home.appending(path: "review-state.json"))
        let report = try await service.reviewCatalog(optedIn: ["npm", "uv"], home: home.path)
        let items = try await index.items(reportID: report.reportID, limit: 10)
        XCTAssertEqual(Set(items.compactMap(\.detail.cleanup)), ["npm cache clean --force", "uv cache prune"])
        let stored = try await index.objects(under: home.path, limit: 10)
        XCTAssertEqual(stored.total, 2)
        // A second catalog review replaces the rows instead of adding duplicates.
        _ = try await service.reviewCatalog(optedIn: ["npm", "uv"], home: home.path)
        let again = try await index.objects(under: home.path, limit: 10)
        XCTAssertEqual(again.total, 2)
        await index.close()
    }

    /// "Running any cleanup command" is a non-goal: no review source starts a
    /// process except the two repository oracles, which run git read-only.
    func testNoReviewSourceRunsACommand() throws {
        let review = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/DiskStewardCore/Review", directoryHint: .isDirectory)
        for file in try FileManager.default.contentsOfDirectory(atPath: review.path) where file.hasSuffix(".swift") && file != "IndexedRepositoryOracle.swift" {
            let source = try String(contentsOf: review.appending(path: file), encoding: .utf8)
            XCTAssertFalse(source.contains("Process()"), "\(file) starts a process")
            XCTAssertFalse(source.contains("posix_spawn"), "\(file) starts a process")
        }
    }
}
