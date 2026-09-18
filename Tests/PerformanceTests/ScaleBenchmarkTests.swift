import Foundation
import Darwin
import XCTest
@testable import DiskStewardCore

/// Explicitly opt-in: the supervisor creates and owns every input/output path.
/// This measures production scanning + staging + validation + publication, not
/// just enumeration. A time/capacity stop is a measurement, never a completion.
final class ScaleBenchmarkTests: XCTestCase, @unchecked Sendable {
    func testOptInProductionScan() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DISK_STEWARD_SCALE_BENCHMARK"] == "supervised-v1" else {
            throw XCTSkip("Run only through docs/reliability/benchmarks/supervise_scale.py")
        }
        let path = try XCTUnwrap(environment["DISK_STEWARD_SCALE_ROOT"])
        let root = URL(fileURLWithPath: path)
        guard root.deletingLastPathComponent().path == "/private/tmp",
              (root.lastPathComponent.hasPrefix("disk-steward-530-scale.") || root.lastPathComponent.hasPrefix("disk-steward-531-scale.")),
              canonicalPath(path) == path else {
            XCTFail("Benchmark requires a supervisor-owned /private/tmp leaf")
            return
        }
        let token = try String(contentsOf: root.appending(path: "owner-token"), encoding: .utf8)
        XCTAssertEqual(token, environment["DISK_STEWARD_SCALE_TOKEN"])
        guard token == environment["DISK_STEWARD_SCALE_TOKEN"], token.count == 36 else { return }
        let fixture = root.appending(path: "fixture", directoryHint: .isDirectory)
        XCTAssertEqual(canonicalPath(fixture.path), fixture.path)
        guard canonicalPath(fixture.path) == fixture.path else { return }
        let seconds = Double(environment["DISK_STEWARD_SCALE_SECONDS"] ?? "") ?? 30
        guard seconds > 0, seconds <= 1_800 else { XCTFail("Invalid time limit"); return }
        let expectedFiles = Int(environment["DISK_STEWARD_SCALE_FILES"] ?? "") ?? -1
        guard (0...1_000_000).contains(expectedFiles) else { XCTFail("Invalid count"); return }
        let variant = environment["DISK_STEWARD_SCALE_VARIANT"] ?? "baseline"
        guard ["baseline", "path-index"].contains(variant) else { XCTFail("Invalid variant"); return }
        let database = root.appending(path: "baseline/evidence.sqlite")
        guard !FileManager.default.fileExists(atPath: database.path) else {
            XCTFail("Use a fresh benchmark database; never overwrite a prior run")
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let checkpoints = BenchmarkCheckpoints()
        // The product default is 512 MiB. A supervised run may raise the cap to
        // measure what one million files actually cost; the cap used is reported.
        let capMiB = Int64(environment["DISK_STEWARD_SCALE_CAP_MIB"] ?? "") ?? 512
        guard (64...16_384).contains(capMiB) else { XCTFail("Invalid storage cap"); return }
        let store = try EvidenceStore(url: database, reconciliationCheckpoint: checkpoints.record, maximumStorageBytes: capMiB * 1_024 * 1_024)
        let reader = try SQLiteConnection(url: database)
        if variant == "path-index" {
            // Research only: changes the disposable schema, never product migrations.
            // Measures a suspected repeated path-binding table scan independently
            // from enumeration/frontier redesign. Semantics are unchanged.
            try reader.execute("CREATE INDEX research_path_bindings_open_object_path ON path_bindings(object_id, path) WHERE valid_through IS NULL")
        }
        let resources = LiveResourceMeasurementSource()
        // One scanner per run: streams persist across slices in this process,
        // exactly as the product probe holds one scanner instance.
        let scanner = DirectoryMetadataScanner()
        var peakPendingFrontierRows: Int64 = 0, peakOpenStreams = 0
        let policy = MonitoringPolicy(watchedRoots: [fixture], maximumEntries: 512, maximumDepth: 64)
        let scope = policy.scopeVersion(at: Date())
        var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: Date())
        var slices = 0, inspected = 0, passes = 0, retained = 0, restarts = 0
        var peakFrontier = 0, attemptedProcessed = 0
        var peakProgressBytes: Int64 = 0, peakFrontierBytes: Int64 = 0, sampledProgressBytes: Int64 = 0
        var peakRSS: Int64 = 0, peakWAL: Int64 = 0, peakDatabaseFamily: Int64 = 0
        var scanSeconds = 0.0, storeSeconds = 0.0, maxScanSeconds = 0.0, maxStoreSeconds = 0.0
        var finalStoreSeconds = 0.0, lastReport = started
        var status = "running", failure = ""

        func emit(_ kind: String) throws {
            let row: [String: Any] = [
                "schema": "disk-steward-scale-baseline-v1", "kind": kind, "status": status, "variant": variant,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "slices": slices, "processedEntries": generation.processedEntryCount,
                "attemptedProcessedEntries": attemptedProcessed,
                "stagedFiles": generation.stagedFileCount, "expectedFiles": expectedFiles,
                "directoryEntriesInspected": inspected, "directoryEnumerationPasses": passes,
                "directoryChangeRestarts": restarts, "peakRetainedNames": retained,
                "peakFrontierCursors": peakFrontier, "peakPersistedProgressBytes": peakProgressBytes,
                "peakDurableFrontierRows": peakPendingFrontierRows, "peakOpenDirectoryStreams": peakOpenStreams,
                "storageCapBytes": capMiB * 1_024 * 1_024,
                "peakPersistedFrontierJSONBytes": peakFrontierBytes,
                "entriesReenumeratedQuiescentFixture": max(0, inspected - attemptedProcessed),
                // One read per returned commit; this does NOT include internal validation rewrites.
                "sampledPersistedProgressBytesSum": sampledProgressBytes,
                "peakInProcessRSSBytes": peakRSS, "peakSampledWALBytes": peakWAL,
                "peakSampledDatabaseFamilyBytes": peakDatabaseFamily,
                "scanSeconds": scanSeconds, "storeSeconds": storeSeconds,
                "maxScanSliceSeconds": maxScanSeconds, "maxStoreCallSeconds": maxStoreSeconds,
                "finalStoreCallSecondsInclusive": finalStoreSeconds,
                "publicationCheckpointsUptime": checkpoints.values, "error": failure,
            ]
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        }
        try emit("start")
        do {
            while ProcessInfo.processInfo.systemUptime - started < seconds {
                let scanStart = ProcessInfo.processInfo.systemUptime
                let slice = autoreleasepool {
                    scanner.scanSlice(policy: policy, generation: generation, at: Date())
                }
                peakOpenStreams = max(peakOpenStreams, DirectoryStreamRegistry.shared.openStreamCount)
                let scanDuration = ProcessInfo.processInfo.systemUptime - scanStart
                scanSeconds += scanDuration
                maxScanSeconds = max(maxScanSeconds, scanDuration)
                inspected += slice.diagnostics.directoryEntriesInspected
                passes += slice.diagnostics.directoryEnumerationPasses
                retained = max(retained, slice.diagnostics.peakRetainedDirectoryNames)
                restarts += slice.diagnostics.directoryChangeRestarts
                attemptedProcessed = slice.generation.processedEntryCount
                peakFrontier = max(peakFrontier, slice.generation.roots.reduce(0) { $0 + $1.frontier.count })
                let snapshot = StorageSnapshot(snapshotID: "scale-\(slices)", observedAt: "2026-09-17T00:00:00Z",
                    volumes: [.init(mountPath: "/fixture", totalBytes: 1_000_000_000, availableBytes: 500_000_000,
                                    isInternal: true, isReadOnly: false)])
                if slice.generation.status == .completed { try emit("before-validation-publication") }
                let storeStart = ProcessInfo.processInfo.systemUptime
                let commit = try await store.recordScanSlice(snapshot: snapshot, slice: slice, scope: scope, trigger: .scheduled)
                let storeDuration = ProcessInfo.processInfo.systemUptime - storeStart
                storeSeconds += storeDuration
                maxStoreSeconds = max(maxStoreSeconds, storeDuration)
                generation = commit.generation // Validation can reopen a scanner-completed generation.
                slices += 1
                let progressBytes = try reader.scalarInt("SELECT COALESCE(MAX(length(progress)),0) FROM scan_generations")
                peakProgressBytes = max(peakProgressBytes, progressBytes)
                // One configured root in these synthetic fixtures. SQL measures
                // the JSON text; no file-count-sized Swift array is introduced.
                let frontierBytes = try reader.scalarInt("SELECT COALESCE(MAX(length(CAST(json_extract(CAST(progress AS TEXT), '$.roots[0].frontier') AS BLOB))),0) FROM scan_generations")
                peakFrontierBytes = max(peakFrontierBytes, frontierBytes)
                peakPendingFrontierRows = max(peakPendingFrontierRows, try reader.scalarInt("SELECT COUNT(*) FROM scan_frontier"))
                sampledProgressBytes += progressBytes
                let resource = resources.measure(databaseURL: database, underLoad: true)
                peakRSS = max(peakRSS, resource.residentBytes)
                peakDatabaseFamily = max(peakDatabaseFamily, resource.databaseBytes)
                let wal = (try? FileManager.default.attributesOfItem(atPath: database.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0
                peakWAL = max(peakWAL, wal)
                if commit.observation != nil {
                    finalStoreSeconds = storeDuration
                    status = "completed"
                    break
                }
                if generation.status == .abandoned { status = "abandoned"; break }
                if resource.residentBytes > 150 * 1_024 * 1_024 { status = "product-rss-limit"; break }
                if ProcessInfo.processInfo.systemUptime - lastReport >= 1 {
                    try emit("progress")
                    lastReport = ProcessInfo.processInfo.systemUptime
                }
            }
        } catch {
            status = "error"
            failure = String(describing: error)
        }
        if status == "running" { status = "time-limit" }
        try emit("result") // Preserve before diagnostics/close; external sampler captures long calls.
        let present = try reader.scalarInt("SELECT COUNT(*) FROM current_file_state WHERE presence = 'present'")
        let observations = try reader.scalarInt("SELECT COUNT(*) FROM observation_runs")
        if status == "completed" {
            XCTAssertEqual(present, Int64(expectedFiles))
            XCTAssertEqual(observations, 1)
            XCTAssertEqual(try reader.scalarInt("SELECT COUNT(*) FROM scan_generation_entries"), 0)
        } else {
            XCTAssertEqual(present, 0, "An unfinished fresh generation must not expose partial current state")
            XCTAssertEqual(observations, 0)
        }
        XCTAssertEqual(try reader.scalarText("PRAGMA quick_check"), "ok")
        reader.close()
        await store.close()
    }
}

// Foundation standardization abbreviates /private/tmp to /tmp on macOS.
// Use the filesystem canonical path for the ownership/symlink check instead.
private func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

private final class BenchmarkCheckpoints: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String: Double] = [:]
    func record(_ checkpoint: String) {
        lock.withLock { recorded[checkpoint] = ProcessInfo.processInfo.systemUptime }
    }
    var values: [String: Double] { lock.withLock { recorded } }
}
