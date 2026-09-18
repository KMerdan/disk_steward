import Darwin
import Foundation
import XCTest
@testable import DiskStewardCore

final class BoundedTraversalScaleTests: XCTestCase {
    func testOptInBoundedPrototype() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DISK_STEWARD_SCALE_BENCHMARK"] == "supervised-v1" else {
            throw XCTSkip("Requires explicit scale supervisor")
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
        let mode = try XCTUnwrap(BoundedTraversalPrototype.Mode(rawValue: env["DISK_STEWARD_SCALE_VARIANT"] ?? ""))
        let expected = try XCTUnwrap(Int(env["DISK_STEWARD_SCALE_FILES"] ?? ""))
        let expectedDirectories = try XCTUnwrap(Int(env["DISK_STEWARD_SCALE_DIRECTORIES"] ?? ""))
        let generations = try XCTUnwrap(Int(env["DISK_STEWARD_SCALE_GENERATIONS"] ?? "1"))
        let seconds = try XCTUnwrap(Double(env["DISK_STEWARD_SCALE_SECONDS"] ?? ""))
        guard (0...1_000_000).contains(expected), (1...1_000_001).contains(expectedDirectories), (1...2).contains(generations), seconds > 0, seconds <= 120 else {
            throw BoundedTraversalPrototype.Failure.capacity
        }
        let database = root.appending(path: "baseline/evidence.sqlite")
        guard !FileManager.default.fileExists(atPath: database.path) else { throw BoundedTraversalPrototype.Failure.corrupt }
        let prototype = try BoundedTraversalPrototype(database: database, mode: mode)
        defer { prototype.close() }
        let started = ProcessInfo.processInfo.systemUptime
        let resources = LiveResourceMeasurementSource()
        var peakRSS: Int64 = 0, peakWAL: Int64 = 0, peakFamily: Int64 = 0
        var status = "running", failure = "", published = 0, batches = 0
        var publicationSeconds = 0.0, gcSeconds = 0.0, maxBatchSeconds = 0.0
        var telemetrySeconds = 0.0, maxIterationSeconds = 0.0, oracleSeconds = 0.0
        var lastReport = started
        var lastFrontier = started - 1

        func sample() throws {
            let value = resources.measure(databaseURL: database, underLoad: true)
            peakRSS = max(peakRSS, value.residentBytes)
            peakFamily = max(peakFamily, value.databaseBytes)
            peakWAL = max(peakWAL, (try? FileManager.default.attributesOfItem(atPath: database.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0)
            if value.residentBytes > 150 * 1_024 * 1_024 { throw PrototypeStop.rss }
            if value.databaseBytes > 512 * 1_024 * 1_024 { throw PrototypeStop.storage }
            if ProcessInfo.processInfo.systemUptime - started >= seconds { throw PrototypeStop.time }
        }
        func emit(_ kind: String) throws {
            let c = prototype.counters
            let row: [String: Any] = [
                "schema": "disk-steward-scale-prototype-v1", "kind": kind, "variant": mode.rawValue,
                "status": status, "error": failure, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "expectedFilesPerGeneration": expected, "requestedGenerations": generations, "publishedGenerations": published,
                "expectedDirectoriesPerGeneration": expectedDirectories,
                "batches": batches, "directoryEntriesInspected": c.enumerated, "processedEntries": c.processed,
                "enumerationPasses": c.enumerationPasses, "peakRetainedNames": c.peakNames,
                "spoolRowsWritten": c.spoolRowsWritten, "peakPendingDirectoryRows": c.peakPendingRows,
                "peakPendingDirectoryPayloadBytes": c.peakPendingPayloadBytes,
                "peakInProcessRSSBytes": peakRSS, "peakSampledWALBytes": peakWAL,
                "peakSampledDatabaseFamilyBytes": peakFamily, "publicationSeconds": publicationSeconds,
                "scratchReclamationSeconds": gcSeconds, "maxBatchSeconds": maxBatchSeconds,
                "frontierTelemetrySeconds": telemetrySeconds, "maxFullIterationSeconds": maxIterationSeconds,
                "maximumQueueVMSteps": c.maximumQueueVMSteps, "oracleSeconds": oracleSeconds,
                "frontierSampling": "once-per-second-and-ready; sampled lower bound",
                "productEquivalent": false,
            ]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
        }
        try emit("start")
        do {
            for _ in 0..<generations {
                let gcStarted = ProcessInfo.processInfo.systemUptime
                while try autoreleasepool(invoking: { try prototype.reclaimPublishedNames() }) > 0 {
                    try sample()
                }
                gcSeconds += ProcessInfo.processInfo.systemUptime - gcStarted
                try prototype.begin(root: root.appending(path: "fixture"))
                while true {
                    let batchStart = ProcessInfo.processInfo.systemUptime
                    defer { maxIterationSeconds = max(maxIterationSeconds, ProcessInfo.processInfo.systemUptime - batchStart) }
                    let ready = try autoreleasepool { try prototype.step() }
                    maxBatchSeconds = max(maxBatchSeconds, ProcessInfo.processInfo.systemUptime - batchStart)
                    batches += 1
                    try sample()
                    if ready || ProcessInfo.processInfo.systemUptime - lastFrontier >= 1 {
                        let telemetryStart = ProcessInfo.processInfo.systemUptime
                        try autoreleasepool { try prototype.sampleFrontier() }
                        lastFrontier = ProcessInfo.processInfo.systemUptime
                        telemetrySeconds += lastFrontier - telemetryStart
                    }
                    if ready { break }
                    if ProcessInfo.processInfo.systemUptime - lastReport >= 1 {
                        try emit("progress")
                        lastReport = ProcessInfo.processInfo.systemUptime
                    }
                }
                let publishStarted = ProcessInfo.processInfo.systemUptime
                try prototype.publish()
                publicationSeconds += ProcessInfo.processInfo.systemUptime - publishStarted
                published += 1
                try sample()
                let oracleStart = ProcessInfo.processInfo.systemUptime
                guard try prototype.visibleCount() == Int64(expected),
                      try prototype.connection.scalarInt("SELECT COUNT(*) FROM directories d JOIN visible v ON d.generation=v.generation WHERE d.phase=4") == Int64(expectedDirectories),
                      try prototype.connection.scalarInt("SELECT COUNT(*) FROM directories d JOIN visible v ON d.generation=v.generation WHERE d.phase<>4") == 0 else {
                    throw BoundedTraversalPrototype.Failure.corrupt
                }
                oracleSeconds += ProcessInfo.processInfo.systemUptime - oracleStart
                try emit("published")
            }
            status = "completed"
        } catch PrototypeStop.time { status = "time-limit" }
        catch PrototypeStop.rss { status = "product-rss-limit" }
        catch PrototypeStop.storage { status = "product-storage-limit" }
        catch { status = "error"; failure = String(describing: error) }
        do {
            let oracleStart = ProcessInfo.processInfo.systemUptime
            guard try prototype.visibleCount() == (published == 0 ? 0 : Int64(expected)),
                  try prototype.connection.scalarText("PRAGMA quick_check") == "ok" else {
                throw BoundedTraversalPrototype.Failure.corrupt
            }
            oracleSeconds += ProcessInfo.processInfo.systemUptime - oracleStart
        } catch { status = "error"; failure = String(describing: error) }
        try emit("result")
        if status == "error" { throw BoundedTraversalPrototype.Failure.corrupt }
    }
}

private enum PrototypeStop: Error { case time, rss, storage }
