import Darwin
import Foundation
import XCTest
@testable import DiskStewardCore

/// Explicitly opt-in wall-clock soak of the product storage path (TASK-572).
/// The supervisor (Scripts/Testing/supervise_soak.py) creates and owns every
/// input and output path. Each cycle mutates the fixture tree, scans it to
/// publication, checks published current state against the tree, runs every
/// read model, exports periodically and lets retention run on its schedule,
/// while RSS, CPU, file descriptors, database, log and staging peaks are
/// recorded. Time, an external stop file or a budget breach ends the run; a
/// breach is a measurement, never a completion. Virtual time is never used.
final class SoakBenchmarkTests: XCTestCase, @unchecked Sendable {
    func testOptInProductionSoak() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DISK_STEWARD_SOAK_BENCHMARK"] == "supervised-v1" else {
            throw XCTSkip("Run only through Scripts/Testing/supervise_soak.py")
        }
        try requireScaleSupervisor()
        let path = try XCTUnwrap(environment["DISK_STEWARD_SOAK_ROOT"])
        let root = URL(fileURLWithPath: path)
        guard root.deletingLastPathComponent().path == "/private/tmp",
              root.lastPathComponent.hasPrefix("disk-steward-572-soak."),
              soakCanonicalPath(path) == path else {
            XCTFail("Soak requires a supervisor-owned /private/tmp leaf")
            return
        }
        let token = try String(contentsOf: root.appending(path: "owner-token"), encoding: .utf8)
        guard token == environment["DISK_STEWARD_SOAK_TOKEN"], token.count == 36 else { XCTFail("Owner token mismatch"); return }
        let fixture = root.appending(path: "fixture", directoryHint: .isDirectory)
        guard soakCanonicalPath(fixture.path) == fixture.path else { XCTFail("Fixture is not canonical"); return }
        let seconds = Double(environment["DISK_STEWARD_SOAK_SECONDS"] ?? "") ?? 600
        guard seconds > 0, seconds <= 172_800 else { XCTFail("Invalid time limit"); return }
        let capMiB = Int64(environment["DISK_STEWARD_SOAK_CAP_MIB"] ?? "") ?? 512
        guard (10...16_384).contains(capMiB) else { XCTFail("Invalid storage cap"); return }
        let rssBudget = (Int64(environment["DISK_STEWARD_SOAK_RSS_MIB"] ?? "") ?? 300) * 1_024 * 1_024
        let descriptorBudget = Int(environment["DISK_STEWARD_SOAK_FD_BUDGET"] ?? "") ?? 512
        let churn = Int(environment["DISK_STEWARD_SOAK_CHURN"] ?? "") ?? 200
        let buckets = Int(environment["DISK_STEWARD_SOAK_BUCKETS"] ?? "") ?? 16
        let pause = Double(environment["DISK_STEWARD_SOAK_PAUSE_SECONDS"] ?? "") ?? 15
        let exportEvery = Int(environment["DISK_STEWARD_SOAK_EXPORT_EVERY"] ?? "") ?? 10
        let retentionEvery = Int(environment["DISK_STEWARD_SOAK_RETENTION_EVERY"] ?? "") ?? 20
        guard churn >= 0, buckets > 0, pause >= 0, exportEvery > 0, retentionEvery > 0 else { XCTFail("Invalid cycle parameters"); return }
        let stopFile = root.appending(path: "stop")
        let database = root.appending(path: "soak/evidence.sqlite")
        guard !FileManager.default.fileExists(atPath: database.path) else { XCTFail("Use a fresh soak database"); return }
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let exportsDirectory = root.appending(path: "exports", directoryHint: .isDirectory)
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let started = ProcessInfo.processInfo.systemUptime
        let cap = capMiB * 1_024 * 1_024
        let store = try EvidenceStore(url: database, maximumStorageBytes: cap)
        let reader = try SQLiteConnection(url: database)
        let scanner = DirectoryMetadataScanner()
        let resources = LiveResourceMeasurementSource()
        let exporter = EvidenceBundleExporter(temporaryDirectory: temporaryDirectory)
        let policy = MonitoringPolicy(watchedRoots: [fixture], maximumEntries: 512, maximumDepth: 8)
        let retention = try EvidenceStoreRetentionPolicy(maxDatabaseBytes: cap)

        // The expected tree: every regular file under the fixture, by canonical path.
        var expected = soakRegularFiles(under: fixture)
        var nextIndex = expected.count
        var cycles = 0, totalSlices = 0, totalMismatches = 0, exports = 0, retentionRuns = 0, forcedEvictions = 0
        var peakRSS: Int64 = 0, peakCPU = 0.0, peakDescriptors = 0, peakDatabaseFamily: Int64 = 0, peakWAL: Int64 = 0
        var peakStagedRows: Int64 = 0, peakFrontierRows: Int64 = 0, peakExportBytes: Int64 = 0, peakCommitted: Int64 = 0
        var maxCycleSeconds = 0.0, maxPublicationSeconds = 0.0, maxQuerySeconds = 0.0, maxExportSeconds = 0.0, maxRetentionSeconds = 0.0
        var lastAdmission = "", limitations: [String] = [], status = "running", failure = ""
        var queryRefusals = 0, exportRefusals = 0, retentionFailures = 0
        var recentBundles: [URL] = []

        func emit(_ kind: String, _ extra: [String: Any] = [:]) throws {
            var row: [String: Any] = [
                "schema": "disk-steward-soak-v1", "kind": kind, "status": status,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "cycles": cycles, "slices": totalSlices, "expectedFiles": expected.count, "mutationMismatches": totalMismatches,
                "exports": exports, "retentionRuns": retentionRuns, "forcedEvictions": forcedEvictions,
                "peakInProcessRSSBytes": peakRSS, "peakCPUPercent": peakCPU, "peakOpenDescriptors": peakDescriptors,
                "peakSampledDatabaseFamilyBytes": peakDatabaseFamily, "peakSampledWALBytes": peakWAL,
                "peakStagedRows": peakStagedRows, "peakDurableFrontierRows": peakFrontierRows, "peakExportBytes": peakExportBytes,
                "peakCommittedBytes": peakCommitted, "storageCapBytes": cap, "lastAdmission": lastAdmission,
                "maxCycleSeconds": maxCycleSeconds, "maxPublicationSeconds": maxPublicationSeconds, "maxQuerySeconds": maxQuerySeconds,
                "maxExportSeconds": maxExportSeconds, "maxRetentionSeconds": maxRetentionSeconds,
                "queryRefusals": queryRefusals, "exportRefusals": exportRefusals, "retentionFailures": retentionFailures,
                "limitations": Array(limitations.suffix(8)), "error": failure,
            ]
            for (key, value) in extra { row[key] = value }
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        }
        try emit("start", ["files": expected.count, "churn": churn, "buckets": buckets, "pauseSeconds": pause, "timeLimitSeconds": seconds])

        do {
            while ProcessInfo.processInfo.systemUptime - started < seconds {
                if FileManager.default.fileExists(atPath: stopFile.path) { status = "external-stop"; break }
                let cycleStart = ProcessInfo.processInfo.systemUptime
                let cycleDate = Date()
                var cycle: [String: Any] = [:]

                // 1. Bounded churn: create, modify and delete; the expected set follows.
                var created = 0, modified = 0, deleted = 0
                for _ in 0..<churn {
                    let bucket = fixture.appending(path: "bucket-\(String(format: "%02d", nextIndex % buckets))", directoryHint: .isDirectory)
                    let file = bucket.appending(path: String(format: "s-%09d", nextIndex))
                    nextIndex += 1
                    try Data([UInt8(nextIndex % 251)]).write(to: file)
                    expected.insert(file.standardizedFileURL.path)
                    created += 1
                }
                for path in expected.prefix(churn) {
                    try Data([1, 2]).write(to: URL(fileURLWithPath: path))
                    modified += 1
                }
                for path in Array(expected.prefix(churn)) where created > 0 {
                    try FileManager.default.removeItem(atPath: path)
                    expected.remove(path)
                    deleted += 1
                }
                cycle["created"] = created; cycle["modified"] = modified; cycle["deleted"] = deleted

                // 2. Scan to publication through the product staging path.
                let scope = policy.scopeVersion(at: cycleDate)
                var generation = try await store.beginOrResumeScanGeneration(scope: scope, at: cycleDate)
                var slices = 0, published = false, publicationSeconds = 0.0
                while slices < 50_000 {
                    let slice = autoreleasepool { scanner.scanSlice(policy: policy, generation: generation, at: Date()) }
                    let snapshot = StorageSnapshot(snapshotID: "soak-\(cycles)-\(slices)", observedAt: EvidenceTimestamp.format(Date()),
                        volumes: [.init(mountPath: "/fixture", totalBytes: 1_000_000_000, availableBytes: 500_000_000, isInternal: true, isReadOnly: false)])
                    let storeStart = ProcessInfo.processInfo.systemUptime
                    let commit = try await store.recordScanSlice(snapshot: snapshot, slice: slice, scope: scope, trigger: .scheduled)
                    let storeSeconds = ProcessInfo.processInfo.systemUptime - storeStart
                    generation = commit.generation
                    slices += 1
                    totalSlices += 1
                    peakStagedRows = max(peakStagedRows, try reader.scalarInt("SELECT COUNT(*) FROM scan_generation_entries"))
                    peakFrontierRows = max(peakFrontierRows, try reader.scalarInt("SELECT COUNT(*) FROM scan_frontier"))
                    if commit.observation != nil { published = true; publicationSeconds = storeSeconds; break }
                    if generation.status == .abandoned { break }
                    if FileManager.default.fileExists(atPath: stopFile.path) { break }
                }
                maxPublicationSeconds = max(maxPublicationSeconds, publicationSeconds)
                cycle["slicesThisCycle"] = slices; cycle["published"] = published; cycle["publicationSeconds"] = publicationSeconds
                cycle["generationStatus"] = generation.status.rawValue

                // 3. Mutation correctness: published presence must equal the tree.
                if published {
                    let present = Set(try await store.currentFiles().filter { $0.presence == .present }.map(\.path))
                    let missing = expected.subtracting(present), extra = present.subtracting(expected)
                    let mismatches = missing.count + extra.count
                    totalMismatches += mismatches
                    cycle["mismatches"] = mismatches
                    if mismatches > 0 {
                        cycle["missingSample"] = Array(missing.prefix(3)); cycle["extraSample"] = Array(extra.prefix(3))
                    }
                }

                // 4. Every read model, timed. A typed budget refusal is product
                //    behavior under a bounded budget: it is counted and recorded,
                //    never treated as a soak failure.
                let queryStart = ProcessInfo.processInfo.systemUptime
                var refused: [String] = []
                func attempt<T>(_ name: String, _ work: () async throws -> T) async -> T? {
                    do { return try await work() } catch { queryRefusals += 1; refused.append("\(name): \(error)"); return nil }
                }
                let consumers = await attempt("consumers") { try await store.queryCurrentConsumers(limit: 100) }
                let growth = await attempt("growth") { try await store.queryGrowth(from: cycleDate.addingTimeInterval(-3_600), through: Date()) }
                let sample = expected.first ?? fixture.path
                let chain = await attempt("provenance") { try await store.provenanceChain(pathQuery: sample, limit: 50) }
                let impacts = await attempt("taskImpact") { try await store.taskImpactCandidates(from: Date(timeIntervalSinceNow: -3_600), through: Date()) }
                let lifecycle = try await store.lifecycleStatus(retention, at: Date())
                let summary = await attempt("lifecycleSummary") { try await store.lifecycleSummary(retention, at: Date()) }
                let querySeconds = ProcessInfo.processInfo.systemUptime - queryStart
                maxQuerySeconds = max(maxQuerySeconds, querySeconds)
                cycle["querySeconds"] = querySeconds
                cycle["consumers"] = consumers?.items.count ?? -1; cycle["growthItems"] = growth?.page.items.count ?? -1
                cycle["provenanceObjects"] = chain?.objectIDs.count ?? -1; cycle["taskImpactCandidates"] = impacts?.count ?? -1
                cycle["detailCoverage"] = summary?.detailCoverage ?? "refused"
                if !refused.isEmpty { cycle["queryRefused"] = refused }
                if let storage = lifecycle.storage {
                    lastAdmission = storage.admission.rawValue
                    peakCommitted = max(peakCommitted, storage.committedBytes)
                    cycle["admission"] = storage.admission.rawValue; cycle["committedBytes"] = storage.committedBytes
                    cycle["reservedPublicationBytes"] = storage.reservedPublicationBytes
                    for limitation in storage.limitations where !limitations.contains(limitation) { limitations.append(limitation) }
                }

                // 5. Periodic export, bounded on disk to the last two bundles.
                if cycles % exportEvery == 0 {
                    let exportStart = ProcessInfo.processInfo.systemUptime
                    let options = EvidenceBundleExportOptions(from: Date(timeIntervalSinceNow: -3_600), through: Date(), pathDetail: .hashed, maximumEvents: 10_000)
                    do {
                        let result = try await exporter.export(store: store, options: options, to: exportsDirectory)
                        let exportSeconds = ProcessInfo.processInfo.systemUptime - exportStart
                        maxExportSeconds = max(maxExportSeconds, exportSeconds)
                        let bytes = soakDirectoryBytes(result.bundleURL)
                        peakExportBytes = max(peakExportBytes, bytes)
                        exports += 1
                        cycle["exportSeconds"] = exportSeconds; cycle["exportBytes"] = bytes
                        recentBundles.append(result.bundleURL)
                        while recentBundles.count > 2 {
                            try? FileManager.default.removeItem(at: recentBundles.removeFirst())
                        }
                    } catch {
                        exportRefusals += 1
                        cycle["exportRefused"] = String(describing: error)
                    }
                }

                // 6. Retention on schedule, or under pressure when the store asks for it.
                if cycles % retentionEvery == retentionEvery - 1 || lastAdmission == "retention-required" {
                    let retentionStart = ProcessInfo.processInfo.systemUptime
                    do {
                        let report = try await store.applyRetention(retention, trigger: lastAdmission == "retention-required" ? .pressure : .scheduled)
                        let retentionSeconds = ProcessInfo.processInfo.systemUptime - retentionStart
                        maxRetentionSeconds = max(maxRetentionSeconds, retentionSeconds)
                        retentionRuns += 1
                        forcedEvictions += report.forcedEvictions
                        cycle["retentionSeconds"] = retentionSeconds; cycle["retentionForcedEvictions"] = report.forcedEvictions
                        cycle["retentionLimitations"] = report.limitations
                    } catch {
                        retentionFailures += 1
                        cycle["retentionFailed"] = String(describing: error)
                    }
                }

                // 7. Measurements and budgets.
                let resource = resources.measure(databaseURL: database, underLoad: true)
                let descriptors = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
                let wal = (try? FileManager.default.attributesOfItem(atPath: database.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0
                peakRSS = max(peakRSS, resource.residentBytes); peakCPU = max(peakCPU, resource.cpuPercent)
                peakDescriptors = max(peakDescriptors, descriptors); peakDatabaseFamily = max(peakDatabaseFamily, resource.databaseBytes); peakWAL = max(peakWAL, wal)
                cycle["rssBytes"] = resource.residentBytes; cycle["cpuPercent"] = resource.cpuPercent; cycle["openDescriptors"] = descriptors
                cycle["databaseFamilyBytes"] = resource.databaseBytes; cycle["walBytes"] = wal
                let cycleSeconds = ProcessInfo.processInfo.systemUptime - cycleStart
                maxCycleSeconds = max(maxCycleSeconds, cycleSeconds)
                cycle["cycleSeconds"] = cycleSeconds
                cycles += 1
                try emit("cycle", cycle)
                if resource.residentBytes > rssBudget { status = "rss-budget-breach"; break }
                if descriptors > descriptorBudget { status = "descriptor-budget-breach"; break }
                if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
            }
        } catch {
            status = "error"
            failure = String(describing: error)
        }
        if status == "running" { status = "completed" }
        try emit("result")
        let integrity = try reader.scalarText("PRAGMA quick_check")
        XCTAssertEqual(integrity, "ok")
        XCTAssertEqual(totalMismatches, 0, "Published current state diverged from the fixture tree")
        XCTAssertTrue(["completed", "external-stop"].contains(status), "Soak ended by \(status): \(failure)")
        reader.close()
        await store.close()
    }
}

private func soakCanonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func soakRegularFiles(under directory: URL) -> Set<String> {
    var files = Set<String>()
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return files }
    for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        files.insert(url.standardizedFileURL.path)
    }
    return files
}

private func soakDirectoryBytes(_ url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
        total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
}
