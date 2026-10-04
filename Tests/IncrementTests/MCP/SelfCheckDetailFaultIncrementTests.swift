import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp
@testable import DiskStewardCore

/// TASK-642: the real helper's `--self-check` connects through a refused
/// lifecycle summary, reports the persisted evidence age, and the app's
/// verification judges it by that age instead of failing.
final class SelfCheckDetailFaultIncrementTests: XCTestCase {
    func testSelfCheckVerifiesThroughARefusedSummary() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = repository.appending(path: ".build/debug/disk-witness-mcp").resolvingSymlinksInPath()
        // Never invoke an installed or externally overridden helper here.
        guard executable.path.hasPrefix(repository.resolvingSymlinksInPath().path + "/.build/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw CocoaError(.fileNoSuchFile) }

        let root = URL(fileURLWithPath: "/private/tmp/ds-selfcheck-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let watched = root.appending(path: "watch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try Data([1]).write(to: watched.appending(path: "recorded.bin"))
        let observedAt = Date()
        let policy = MonitoringPolicy(watchedRoots: [watched])
        let store = try EvidenceStore(url: database)
        _ = try await store.recordObservation(
            snapshot: .init(snapshotID: "self-check", observedAt: EvidenceTimestamp.format(observedAt), volumes: []),
            metadata: DirectoryMetadataScanner().scan(policy: policy, at: observedAt),
            scope: policy.scopeVersion(at: observedAt), trigger: .scheduled)
        _ = try await store.applyRetention(try .init(), trigger: .manual)
        await store.close()
        let fixture = try SQLiteConnection(url: database)
        try fixture.execute("UPDATE retention_runs SET limitations = zeroblob(600000)")
        fixture.close()

        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let server = UnixSocketEvidenceServer(socketPath: root.appending(path: "s").path, handler: backend, timeoutSeconds: 15)
        try server.start()
        defer { server.stop() }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--self-check"]
        process.environment = ["PATH": "/usr/bin:/bin", "DISK_STEWARD_SOCKET_PATH": server.socketPath]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(decoding: data, as: UTF8.self)
        let report = try XCTUnwrap(HelperSelfCheckReport.parse(stdout), stdout)
        XCTAssertEqual(report.app, "connected", stdout)
        XCTAssertNotNil(report.evidence?.ageSeconds, "the persisted age survives the refused summary: \(stdout)")

        let outcome = HelperSelfCheck.evaluate(
            AgentCommandResult(exitCode: process.terminationStatus, standardOutput: stdout, standardError: ""),
            expectedIdentity: report.helper.identity, configuredPath: executable.path)
        switch outcome {
        case .verified, .stale: break
        case let .failed(reason): XCTFail("A refused summary must not fail verification: \(reason)")
        }
    }
}
