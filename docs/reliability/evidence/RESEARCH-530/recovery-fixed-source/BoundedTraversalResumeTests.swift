import CSQLite
import Darwin
import Foundation
import XCTest
@testable import DiskStewardCore

/// Continuation of a collected synthetic experiment only. Never opens app data.
final class BoundedTraversalResumeTests: XCTestCase {
    func testOptInResumeWithControlledReader() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DISK_STEWARD_SCALE_BENCHMARK"] == "resume-supervised-v1" else {
            throw XCTSkip("Requires the dedicated collected-fixture resume supervisor")
        }
        let path = try XCTUnwrap(env["DISK_STEWARD_SCALE_ROOT"])
        let root = URL(fileURLWithPath: path)
        guard root.deletingLastPathComponent().path == "/private/tmp",
              root.lastPathComponent.hasPrefix("disk-steward-530-scale."),
              let canonical = realpath(path, nil) else { throw BoundedTraversalPrototype.Failure.unavailable }
        defer { free(canonical) }
        guard String(cString: canonical) == path,
              try String(contentsOf: root.appending(path: "owner-token"), encoding: .utf8) == env["DISK_STEWARD_SCALE_TOKEN"] else {
            throw BoundedTraversalPrototype.Failure.unavailable
        }
        let expected = try XCTUnwrap(Int64(env["DISK_STEWARD_SCALE_FILES"] ?? ""))
        let seconds = try XCTUnwrap(Double(env["DISK_STEWARD_SCALE_SECONDS"] ?? ""))
        let mode = try XCTUnwrap(BoundedTraversalPrototype.Mode(rawValue: env["DISK_STEWARD_SCALE_VARIANT"] ?? ""))
        guard ["0", "1"].contains(env["DISK_STEWARD_SCALE_PIN_READER"] ?? "") else { throw BoundedTraversalPrototype.Failure.incomplete }
        let pinReader = env["DISK_STEWARD_SCALE_PIN_READER"] == "1"
        guard (1...1_000_000).contains(expected), seconds > 0, seconds <= 120 else {
            throw BoundedTraversalPrototype.Failure.capacity
        }
        let database = root.appending(path: "baseline/evidence.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { throw BoundedTraversalPrototype.Failure.unavailable }
        let started = ProcessInfo.processInfo.systemUptime
        let reader = try SQLiteConnection(url: database)
        defer { try? reader.execute("ROLLBACK"); reader.close() }
        try reader.execute("PRAGMA query_only=ON")
        if pinReader { try reader.execute("BEGIN") }
        let oldVisible = try reader.scalarInt("SELECT generation FROM visible WHERE singleton=1")
        guard oldVisible == 1,
              try reader.scalarInt("SELECT COUNT(*) FROM generations WHERE status='preparing' AND id=2 AND fenced=0") == 1 else {
            throw BoundedTraversalPrototype.Failure.incomplete
        }
        let prototype = try BoundedTraversalPrototype(database: database, mode: mode)
        defer { prototype.close() }
        guard prototype.generation == 2, try prototype.visibleCount() == expected else { throw BoundedTraversalPrototype.Failure.corrupt }
        let resources = LiveResourceMeasurementSource()
        var peakRSS: Int64 = 0, peakWAL: Int64 = 0, peakFamily: Int64 = 0
        var status = "running", failure = "", batches = 0, published = false
        var maxBatch = 0.0, publicationSeconds = 0.0
        var checkpoint = ResumeCheckpointMetrics()
        var lastReport = started

        func sample() throws {
            let value = resources.measure(databaseURL: database, underLoad: true)
            peakRSS = max(peakRSS, value.residentBytes)
            peakFamily = max(peakFamily, value.databaseBytes)
            peakWAL = max(peakWAL, (try? FileManager.default.attributesOfItem(atPath: database.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0)
            if value.residentBytes > 150 * 1_024 * 1_024 { throw ResumeStop.rss }
            if value.databaseBytes > 512 * 1_024 * 1_024 { throw ResumeStop.storage }
            if ProcessInfo.processInfo.systemUptime - started >= seconds { throw ResumeStop.time }
        }
        func emit(_ kind: String) throws {
            let c = prototype.counters
            var row: [String: Any] = [
                "schema": "disk-steward-scale-resume-v1", "kind": kind, "variant": mode.rawValue,
                "status": status, "error": failure, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "expectedFiles": expected, "oldVisibleGeneration": oldVisible, "resumedGeneration": 2,
                "published": published, "batches": batches, "maxBatchSeconds": maxBatch,
                "directoryEntriesInspected": c.enumerated, "processedEntries": c.processed,
                "restartedDirectories": c.restartedDirectories, "enumerationPasses": c.enumerationPasses,
                "peakRetainedNames": c.peakNames, "maximumQueueVMSteps": c.maximumQueueVMSteps,
                "peakInProcessRSSBytes": peakRSS, "peakSampledWALBytes": peakWAL,
                "peakSampledDatabaseFamilyBytes": peakFamily, "publicationSeconds": publicationSeconds,
                "pinnedReader": pinReader, "productEquivalent": false,
            ]
            row.merge(checkpoint.json) { _, value in value }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
        }
        try emit("start")
        do {
            try sample()
            while true {
                let start = ProcessInfo.processInfo.systemUptime
                let ready = try autoreleasepool { try prototype.step() }
                maxBatch = max(maxBatch, ProcessInfo.processInfo.systemUptime - start)
                batches += 1
                try sample()
                if ready { break }
                if ProcessInfo.processInfo.systemUptime - lastReport >= 1 {
                    try emit("progress")
                    lastReport = ProcessInfo.processInfo.systemUptime
                }
            }
            let publicationStart = ProcessInfo.processInfo.systemUptime
            try prototype.publish()
            publicationSeconds = ProcessInfo.processInfo.systemUptime - publicationStart
            published = true
            guard try reader.scalarInt("SELECT generation FROM visible WHERE singleton=1") == (pinReader ? oldVisible : 2),
                  try prototype.connection.scalarInt("SELECT generation FROM visible WHERE singleton=1") == 2,
                  try prototype.visibleCount() == expected else { throw BoundedTraversalPrototype.Failure.corrupt }
            try sample()
            if pinReader { try reader.execute("ROLLBACK") }
            guard try reader.scalarInt("SELECT generation FROM visible WHERE singleton=1") == 2 else {
                throw BoundedTraversalPrototype.Failure.corrupt
            }
            try checkpoint.measure(before: resources.measure(databaseURL: database, underLoad: true).databaseBytes) {
                try prototype.connection.withStatement("PRAGMA wal_checkpoint(TRUNCATE)") { statement in
                    guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int64(statement, 0) == 0 else {
                        throw BoundedTraversalPrototype.Failure.incomplete
                    }
                }
                return resources.measure(databaseURL: database, underLoad: true).databaseBytes
            }
            guard try prototype.connection.scalarText("PRAGMA quick_check") == "ok" else { throw BoundedTraversalPrototype.Failure.corrupt }
            try sample() // Include the final oracle/checkpoint in cooperative accounting.
            status = "completed"
        } catch ResumeStop.time { status = "time-limit" }
        catch ResumeStop.rss { status = "product-rss-limit" }
        catch ResumeStop.storage { status = "product-storage-limit" }
        catch BoundedTraversalPrototype.Failure.capacity { status = "admission-stop" }
        catch { status = "error"; failure = String(describing: error) }
        guard try prototype.visibleCount() == expected,
              try prototype.connection.scalarInt("SELECT generation FROM visible WHERE singleton=1") == (published ? 2 : oldVisible) else {
            throw BoundedTraversalPrototype.Failure.corrupt
        }
        try emit("result")
        if status == "error" { throw BoundedTraversalPrototype.Failure.corrupt }
    }

    func testStopsBeforeCheckpointReportUnmeasuredNotZero() throws {
        for error: Error in [ResumeStop.time, BoundedTraversalPrototype.Failure.capacity] {
            var checkpoint = ResumeCheckpointMetrics()
            do {
                try { () throws in throw error }()
                try checkpoint.measure(before: 100) { XCTFail("Must not checkpoint after stop"); return 0 }
            } catch { }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: checkpoint.json)) as? [String: Any])
            XCTAssertEqual(json["checkpointState"] as? String, "not-attempted")
            for key in ["checkpointSeconds", "familyBytesBeforeCheckpoint", "familyBytesAfterCheckpoint"] {
                XCTAssertTrue(json[key] is NSNull, key)
            }
        }
    }

    func testFailedCheckpointPreservesOnlyMeasuredValues() throws {
        var checkpoint = ResumeCheckpointMetrics()
        XCTAssertThrowsError(try checkpoint.measure(before: 123) { throw ResumeStop.storage })
        XCTAssertEqual(checkpoint.json["checkpointState"] as? String, "failed")
        XCTAssertEqual(checkpoint.json["familyBytesBeforeCheckpoint"] as? Int64, 123)
        XCTAssertTrue(checkpoint.json["familyBytesAfterCheckpoint"] is NSNull)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(checkpoint.json["checkpointSeconds"] as? Double), 0)
    }

    func testSuccessfulCheckpointReportsMeasuredValues() throws {
        var checkpoint = ResumeCheckpointMetrics()
        try checkpoint.measure(before: 123) { 100 }
        XCTAssertEqual(checkpoint.json["checkpointState"] as? String, "completed")
        XCTAssertEqual(checkpoint.json["familyBytesBeforeCheckpoint"] as? Int64, 123)
        XCTAssertEqual(checkpoint.json["familyBytesAfterCheckpoint"] as? Int64, 100)
    }
}

private enum ResumeStop: Error { case time, rss, storage }

private struct ResumeCheckpointMetrics {
    private var state = "not-attempted"
    private var seconds: Double?
    private var before: Int64?
    private var after: Int64?

    mutating func measure(before bytes: Int64, operation: () throws -> Int64) throws {
        before = bytes
        state = "failed"
        let start = ProcessInfo.processInfo.systemUptime
        defer { seconds = ProcessInfo.processInfo.systemUptime - start }
        after = try operation()
        state = "completed"
    }

    var json: [String: Any] {
        ["checkpointState": state,
         "checkpointSeconds": seconds.map { $0 as Any } ?? NSNull(),
         "familyBytesBeforeCheckpoint": before.map { $0 as Any } ?? NSNull(),
         "familyBytesAfterCheckpoint": after.map { $0 as Any } ?? NSNull()]
    }
}
