import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp
@testable import DiskStewardCore

/// TASK-716: with file detail retired, as on every current install, the real
/// helper's `--self-check` takes freshness from Monitoring's newest persisted
/// capacity sample, and the app's verification judges it by that age.
final class SelfCheckCapacityFreshnessIncrementTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/ds-scf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testARecentCapacitySampleVerifies() async throws {
        try await recordSample(at: Date().addingTimeInterval(-180))
        let (report, outcome) = try selfCheck()
        XCTAssertEqual(report.evidence?.persisted, true)
        let age = try XCTUnwrap(report.evidence?.ageSeconds, "the sample's age is reported")
        XCTAssertGreaterThanOrEqual(age, 170)
        XCTAssertLessThan(age, HelperSelfCheck.staleEvidenceThreshold)
        guard case .verified = outcome else { return XCTFail("A sample three minutes old must verify: \(outcome)") }
    }

    func testNoCapacitySampleIsStaleWithNothingPersisted() async throws {
        let (report, outcome) = try selfCheck()
        XCTAssertEqual(report.evidence?.persisted, false)
        XCTAssertEqual(outcome, .stale(evidenceAge: nil))
    }

    func testASampleOlderThanAnHourIsStale() async throws {
        try await recordSample(at: Date().addingTimeInterval(-2 * 3_600))
        let (report, outcome) = try selfCheck()
        let age = try XCTUnwrap(report.evidence?.ageSeconds)
        XCTAssertGreaterThan(age, HelperSelfCheck.staleEvidenceThreshold)
        guard case .stale(evidenceAge: .some) = outcome else { return XCTFail("A two-hour-old sample is stale: \(outcome)") }
    }

    /// One sample for the volume the backend reports on.
    private func recordSample(at date: Date) async throws {
        let selected = try XCTUnwrap(selectedCapacityVolume(in: try VolumeSnapshotService().capture()))
        let ring = try CapacityRing(url: root.appending(path: "capacity.sqlite"))
        try await ring.record(volumeUUID: "UUID-self-check", mountPath: selected.mountPath, totalBytes: selected.totalBytes,
                              availableBytes: selected.availableBytes, at: date)
        await ring.close()
    }

    /// Runs the built helper's self-check against the production backend
    /// configuration (file detail retired) and returns the app's verdict.
    private func selfCheck() throws -> (HelperSelfCheckReport, HelperSelfCheck.Outcome) {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = repository.appending(path: ".build/debug/disk-witness-mcp").resolvingSymlinksInPath()
        // Never invoke an installed or externally overridden helper here.
        guard executable.path.hasPrefix(repository.resolvingSymlinksInPath().path + "/.build/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw CocoaError(.fileNoSuchFile) }

        let backend = try AppEvidenceQueryBackend(databaseURL: root.appending(path: "evidence.sqlite"),
                                                  capacityRingURL: root.appending(path: "capacity.sqlite"),
                                                  fileDetail: .retired(supportDirectory: root))
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
        let outcome = HelperSelfCheck.evaluate(
            AgentCommandResult(exitCode: process.terminationStatus, standardOutput: stdout, standardError: ""),
            expectedIdentity: report.helper.identity, configuredPath: executable.path)
        return (report, outcome)
    }
}
