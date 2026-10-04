@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-621 AC-02, opt-in: `.bench/review-scope` names a real scope and
/// `.bench/synthetic-tree` a generated tree, placed only in an isolated test
/// snapshot. The review only reads; git is asked through the read-only oracle.
final class ReviewBenchmarkTests: XCTestCase {
    private func marker(_ name: String) -> String? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".bench/" + name)
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testRealScopeReviewTimeAndDuParity() throws {
        guard let scope = marker("review-scope") else { throw XCTSkip("No benchmark scope in this snapshot") }
        var runs: [[String: Any]] = []
        var last: ReviewReport?
        for label in ["first", "second"] {
            let started = ProcessInfo.processInfo.systemUptime
            let baseline = ReviewWalker.physicalFootprint()
            let tracker = PeakTracker(baseline)
            let report = ReviewWalker(footprint: { tracker.sample() }).review(scope: scope)
            let peak = tracker.peak
            let seconds = ProcessInfo.processInfo.systemUptime - started
            runs.append(["run": label, "seconds": seconds, "status": report.status.label, "entries": report.entriesVisited,
                         "directories": report.directoriesVisited, "objects": report.objects.count, "object_bytes": report.objectBytes,
                         "scope_bytes": report.scopeAllocatedBytes, "classifier_calls": report.classifierCalls,
                         "git_queries": report.repositoryQueries, "git_seconds": report.repositoryQuerySeconds,
                         "footprint_growth_bytes": peak > baseline ? peak - baseline : 0, "unresolved": report.unresolvedCount,
                         "unreadable_directories": report.unreadableDirectories, "skipped_mounts": report.skippedMounts.count])
            last = report
        }
        let report = try XCTUnwrap(last)
        // du runs outside the supervised test, from the object list written here,
        // so the comparison does not start a process per object under supervision.
        if let output = marker("output-dir") {
            let objects = report.objects.map { ["path": $0.path, "bytes": $0.allocatedBytes, "kind": $0.kind.rawValue, "rule": $0.rule.rawValue] as [String: Any] }
            let record: [String: Any] = ["scope": scope, "runs": runs, "scope_bytes": report.scopeAllocatedBytes, "object_bytes": report.objectBytes,
                                         "git_processes": report.repositoryProcesses, "objects": objects,
                                         "unresolved": report.unresolved.map(\.path), "limitations": report.limitations]
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: URL(fileURLWithPath: output + "/review-localgit.json"))
        }
        let byKind = Dictionary(grouping: report.objects, by: { $0.kind.rawValue }).mapValues { ["count": $0.count, "bytes": $0.reduce(Int64(0)) { $0 + $1.allocatedBytes }] }
        let summary: [String: Any] = ["scope": scope, "runs": runs, "objects_by_kind": byKind, "git_processes": report.repositoryProcesses,
                                      "largest_objects": report.objects.prefix(15).map { ["bytes": $0.allocatedBytes, "kind": $0.kind.rawValue, "name": URL(fileURLWithPath: $0.path).lastPathComponent, "rule": $0.rule.rawValue] }]
        print("REVIEW-BENCHMARK", String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))
        XCTAssertEqual(report.status, .completed)
        XCTAssertLessThan(runs.compactMap { $0["seconds"] as? Double }.max() ?? 999, 60)
    }

    func testSyntheticMillionFileTree() throws {
        guard let tree = marker("synthetic-tree") else { throw XCTSkip("No synthetic tree in this snapshot") }
        var started = ProcessInfo.processInfo.systemUptime
        let full = ReviewWalker(decider: ClassifierObjectDecider(oracle: SilentRepositoryOracle())).review(scope: tree)
        let fullSeconds = ProcessInfo.processInfo.systemUptime - started
        started = ProcessInfo.processInfo.systemUptime
        let bounded = ReviewWalker(decider: ClassifierObjectDecider(oracle: SilentRepositoryOracle()),
                                   budget: ReviewBudget(maximumEntries: 300_000)).review(scope: tree)
        let boundedSeconds = ProcessInfo.processInfo.systemUptime - started
        let summary: [String: Any] = [
            "tree": tree,
            "default_budget": ["seconds": fullSeconds, "status": full.status.label, "entries": full.entriesVisited, "objects": full.objects.count,
                               "covered_top_level": full.coveredTopLevel.count],
            "injected_budget_300k_entries": ["seconds": boundedSeconds, "status": bounded.status.label, "entries": bounded.entriesVisited,
                                             "objects": bounded.objects.count, "covered_top_level": bounded.coveredTopLevel.count,
                                             "uncovered_top_level": bounded.uncoveredTopLevel.count, "limitations": bounded.limitations]]
        print("REVIEW-SYNTHETIC", String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))
        XCTAssertEqual(full.status, .completed)
        XCTAssertGreaterThan(full.entriesVisited, 1_000_000)
        XCTAssertEqual(bounded.status, .stopped(.entries))
        XCTAssertFalse(bounded.uncoveredTopLevel.isEmpty)
    }
}

private final class PeakTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64
    init(_ value: UInt64) { self.value = value }
    func sample() -> UInt64 {
        let now = ReviewWalker.physicalFootprint()
        lock.withLock { value = max(value, now) }
        return now
    }
    var peak: UInt64 { lock.withLock { value } }
}
