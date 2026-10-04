import AppKit
@testable import DiskStewardCore
import SwiftUI
import Vision
import XCTest
@testable import DiskStewardApp

/// TASK-623: every state of the design's table renders in the hosted window,
/// in light and dark appearance, with what is known and what is not; an
/// interrupted review never reads as "nothing found".
@MainActor
final class ReviewWindowTests: XCTestCase {
    private let gib: Int64 = 1_073_741_824
    private let now = Date(timeIntervalSince1970: 1_791_300_000)

    private final class CapacityBox {
        var value: ReviewWindowModel.Capacity
        init(_ value: ReviewWindowModel.Capacity) { self.value = value }
    }

    private func model(_ capacity: ReviewWindowModel.Capacity, service: ReviewService? = nil, index: ReviewIndex? = nil,
                       scopes: [ReviewWindowModel.Scope] = [.folder("/Users/test/localGit"), .caches]) -> (ReviewWindowModel, CapacityBox) {
        let box = CapacityBox(capacity)
        let model = ReviewWindowModel(service: service, index: index, scopes: scopes, capacity: { box.value }, now: { [now] in now })
        return (model, box)
    }

    private var comfortable: ReviewWindowModel.Capacity { .init(availableBytes: 372 * gib, reserveBytes: 93 * gib) }
    private var low: ReviewWindowModel.Capacity { .init(availableBytes: 40 * gib, reserveBytes: 93 * gib) }

    private func report(status: ReviewStatus, objects: [ReviewObject], uncovered: [String] = [], unreadable: Int = 0) -> ReviewReport {
        ReviewReport(reportID: "r", scope: "/Users/test/localGit", startedAt: now, completedAt: now, status: status, entriesVisited: 2_025_415,
                     directoriesVisited: 245_550, scopeAllocatedBytes: 191 * gib, objects: objects,
                     projects: [ReviewProject(path: "/Users/test/localGit/web", marker: "package.json", lastSourceActivity: now.timeIntervalSince1970 - 120 * 86_400, tools: ["node", "pnpm"]),
                                ReviewProject(path: "/Users/test/localGit/engine", marker: "Cargo.toml", lastSourceActivity: now.timeIntervalSince1970 - 2 * 86_400, tools: ["cargo"])],
                     unresolved: [], unresolvedCount: 0, unreadableDirectories: unreadable, unreadableEntries: 0, skippedMounts: [], excluded: [],
                     coveredTopLevel: ["/Users/test/localGit/web"], uncoveredTopLevel: uncovered, classifierCalls: 0, repositoryQueries: 0,
                     repositoryQuerySeconds: 0, repositoryProcesses: 0)
    }

    private var objects: [ReviewObject] {
        [ReviewObject(path: "/Users/test/localGit/web/node_modules", kind: .artifact, rule: .content, reason: "it holds installed packages with their own manifests",
                      projectPath: "/Users/test/localGit/web", recreateClass: .redownload, allocatedBytes: 4 * gib, fileCount: 90_000, lastActivity: now.timeIntervalSince1970),
         ReviewObject(path: "/Users/test/localGit/engine/target", kind: .artifact, rule: .manifest, reason: "Cargo.toml beside it expects this output location",
                      projectPath: "/Users/test/localGit/engine", recreateClass: .rebuild, allocatedBytes: 7 * gib, fileCount: 40_000, lastActivity: now.timeIntervalSince1970)]
    }

    private func show(_ model: ReviewWindowModel, _ report: ReviewReport) {
        model.show(ReviewWindowModel.display(for: .folder("/Users/test/localGit"), report: report, items: ReviewRanking.rank(report, now: now), now: now))
    }

    /// A window that is not released on close: ARC owns it, so closing never over-releases.
    private static func window(_ hosting: NSView) -> NSWindow {
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        return window
    }

    /// Renders the window, saves the screenshot for the evidence and returns the text Vision reads in it.
    private func render(_ model: ReviewWindowModel, _ name: String, dark: Bool) throws -> String {
        // cacheDisplay skips the window's backdrop; without it the bitmap is
        // transparent, which Vision reads as black (light text vanishes) and
        // viewers show as white (dark text vanishes).
        let hosting = NSHostingView(rootView: ReviewWindowView(model: model).background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = Self.window(hosting)
        window.appearance = hosting.appearance
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        // Lines are joined with spaces so a phrase that wraps still matches.
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appending(path: "review-\(name)-\(dark ? "dark" : "light").png"))
        print("REVIEW-RENDER \(name) \(dark ? "dark" : "light"): \(text)")
        window.orderOut(nil)
        return text
    }

    private func assertRenders(_ model: ReviewWindowModel, _ name: String, contains expected: [String], excludes: [String] = [],
                               file: StaticString = #filePath, line: UInt = #line) throws {
        for dark in [false, true] {
            let text = try render(model, name, dark: dark)
            for phrase in expected { XCTAssertTrue(text.localizedCaseInsensitiveContains(phrase), "\(name) \(dark ? "dark" : "light") lacks \"\(phrase)\": \(text)", file: file, line: line) }
            for phrase in excludes { XCTAssertFalse(text.localizedCaseInsensitiveContains(phrase), "\(name) shows \"\(phrase)\"", file: file, line: line) }
        }
    }

    func testComfortableAndBelowReserveBeforeAnyReview() throws {
        let (calm, _) = model(comfortable)
        XCTAssertEqual(calm.primaryActionTitle, "Review Storage")
        try assertRenders(calm, "comfortable", contains: ["free", "above your", "Review Storage", "No review"])
        let (tight, _) = model(low)
        XCTAssertTrue(tight.belowReserve)
        try assertRenders(tight, "below-reserve", contains: ["below your", "Review Storage"])
    }

    func testReviewingShowsConcreteCountsAndStop() throws {
        let (reviewing, _) = model(comfortable)
        reviewing.reviewState = .reviewing(ReviewProgress(entries: 812_400, directories: 96_120, objects: 1_204, elapsedSeconds: 19, currentTopLevel: nil))
        XCTAssertEqual(reviewing.primaryActionTitle, "Stop Review")
        XCTAssertFalse(reviewing.stateLine.contains("%"), "no invented percentage")
        try assertRenders(reviewing, "reviewing", contains: ["Stop Review", "812,400", "96,120", "free"], excludes: ["%"])
    }

    func testCompleteWithItemsGroupsByProjectAndShowsTheDetail() throws {
        let (complete, _) = model(comfortable)
        show(complete, report(status: .completed, objects: objects))
        XCTAssertEqual(complete.reviewState, .completeWithItems)
        XCTAssertEqual(complete.groups.map(\.name), ["/Users/test/localGit/web", "/Users/test/localGit/engine"], "idle project's item first, grouped by project")
        let item = try XCTUnwrap(complete.selectedItem)
        XCTAssertEqual(item.rebuildCommand, "pnpm install")
        XCTAssertEqual(complete.capacityLine, ReviewWindowModel.bytes(372 * gib) + " free · " + ReviewWindowModel.bytes(279 * gib) + " above your " + ReviewWindowModel.bytes(93 * gib) + " reserve",
                       "free space is the volume's own figure, never combined with the review estimate")
        XCTAssertTrue(complete.reviewBrief(item).contains("does not say it is safe to delete"))
        try assertRenders(complete, "complete-with-items", contains: ["worth reviewing", "node_modules", "target", "Reveal in Finder", "Copy Review Brief", "pnpm install", "Reasons to keep", "free"])
    }

    func testCompleteWithZeroItemsDoesNotGeneralize() throws {
        let (zero, _) = model(comfortable)
        show(zero, report(status: .completed, objects: []))
        XCTAssertEqual(zero.reviewState, .completeWithZeroItems)
        XCTAssertEqual(zero.primaryActionTitle, "Choose Another Scope")
        try assertRenders(zero, "complete-zero", contains: ["Nothing in the completed scope met review rules", "rest of the disk", "Choose Another Scope"])
    }

    func testAnInterruptedReviewIsPartialAndNeverNothingFound() throws {
        let (partial, _) = model(comfortable)
        show(partial, report(status: .stopped(.wallTime), objects: [objects[1]], uncovered: ["/Users/test/localGit/engine", "/Users/test/localGit/huge"]))
        XCTAssertEqual(partial.reviewState, .partial)
        XCTAssertEqual(partial.display?.items.map(\.evidence), [.verifiedNow], "a listed object was measured whole; the review, not the item, is partial")
        try assertRenders(partial, "partial", contains: ["stopped before covering", "2 folders were not reviewed and are unknown, not empty", "1 item so far", "Review a Smaller Scope", "Not reviewed"])
        // Interrupted with nothing found yet: still partial, never "nothing found".
        let (empty, _) = model(comfortable)
        show(empty, report(status: .stopped(.entries), objects: [], uncovered: ["/Users/test/localGit/huge"]))
        XCTAssertEqual(empty.reviewState, .partial)
        try assertRenders(empty, "partial-empty", contains: ["stopped before covering", "1 folder was not reviewed and is unknown, not empty"], excludes: ["No candidates", "Nothing in the completed scope"])
    }

    /// A review that ran to the end but met unreadable folders (the real
    /// ~/Library/Caches has TCC-protected ones) is partial, yet it did not
    /// stop: it must not say so, and a smaller scope is not the remedy.
    func testACompletedReviewWithUnreadableFoldersDoesNotClaimItStopped() throws {
        let (finished, _) = model(comfortable)
        show(finished, report(status: .completed, objects: objects, unreadable: 11))
        XCTAssertEqual(finished.reviewState, .partial)
        XCTAssertTrue(finished.finishedWithUnreadable)
        XCTAssertFalse(finished.stateLine.contains("stopped"), finished.stateLine)
        XCTAssertFalse(finished.stateLine.contains("so far"), finished.stateLine)
        XCTAssertEqual(finished.primaryActionTitle, "Refresh Review")
        try assertRenders(finished, "finished-unreadable", contains: ["The review finished, but some folders could not be read", "unknown, not absent", "11 folders could not be read", "Refresh Review"],
                          excludes: ["stopped before covering", "Review a Smaller Scope"])
        let (empty, _) = model(comfortable)
        show(empty, report(status: .completed, objects: [], unreadable: 2))
        XCTAssertEqual(empty.reviewState, .partial, "unreadable folders never read as nothing found")
        XCTAssertTrue(empty.stateLine.contains("Nothing in the readable part met review rules"), empty.stateLine)
        XCTAssertEqual(empty.primaryActionTitle, "Choose Another Scope")
    }

    func testAStoredCompletedReviewWithUnreadableFoldersReadsTheSame() throws {
        let stored = StoredReviewReport(reportID: "r", scope: "/Users/test/localGit", startedAt: now, completedAt: now, coverage: "partial", status: "completed",
                                        totalItems: 0, truncated: true, limitations: ["3 folders could not be read; their contents are unknown, not absent."])
        let (reopened, _) = model(comfortable)
        reopened.show(ReviewWindowModel.display(for: .folder("/Users/test/localGit"), stored: stored, items: [], now: now))
        XCTAssertEqual(reopened.reviewState, .partial)
        XCTAssertTrue(reopened.stateLine.hasPrefix("The review finished, but some folders could not be read"), reopened.stateLine)
        XCTAssertEqual(reopened.primaryActionTitle, "Choose Another Scope")
    }

    func testDetailUnavailableAndCapacityUnavailable() throws {
        let (unavailable, _) = model(comfortable)
        unavailable.reviewState = .detailUnavailable("the review could not be stored (review_reports)")
        try assertRenders(unavailable, "detail-unavailable", contains: ["File detail is unavailable", "free", "Review a Smaller Scope"])
        let (blind, box) = model(.unavailable)
        XCTAssertEqual(blind.primaryActionTitle, "Retry Capacity Read")
        try assertRenders(blind, "capacity-unavailable", contains: ["Capacity unavailable", "Retry Capacity Read"], excludes: ["GB free"])
        box.value = comfortable
        blind.primaryAction()
        XCTAssertEqual(blind.capacity, comfortable, "retry reads capacity again")
    }

    /// SwiftUI builds its accessibility tree only for an assistive client, so
    /// the labels are checked where they are made (the model) and the view is
    /// checked to use them; VoiceOver itself is exercised by hand at GATE-669.
    func testAccessibilityLabelsCarryAmountsAndFreshness() throws {
        let (complete, _) = model(comfortable)
        show(complete, report(status: .completed, objects: objects))
        let summary = complete.accessibilitySummary
        XCTAssertTrue(summary.contains("free") && summary.contains("GB"), summary)
        XCTAssertTrue(summary.contains("worth reviewing"), summary)
        XCTAssertTrue(summary.contains("Last review"), summary)
        let row = ReviewWindowModel.accessibilityLabel(for: try XCTUnwrap(complete.display?.items.first { $0.name == "node_modules" }))
        for part in ["node_modules", "GB", "Verified now", "checked"] { XCTAssertTrue(row.contains(part), "row label lacks \(part): \(row)") }
        let (partial, _) = model(.unavailable)
        show(partial, report(status: .stopped(.wallTime), objects: [], uncovered: ["/Users/test/localGit/huge"]))
        XCTAssertTrue(partial.accessibilitySummary.contains("Capacity unavailable"), partial.accessibilitySummary)
        XCTAssertTrue(partial.accessibilitySummary.contains("unknown, not empty"), "a partial review is announced as partial")

        let view = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/DiskStewardApp/Review/ReviewWindowView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains(".accessibilityElement(children: .combine)\n        .accessibilityLabel(model.accessibilitySummary)"), "the summary is one labelled element")
        XCTAssertTrue(view.contains(".accessibilityLabel(ReviewWindowModel.accessibilityLabel(for: item))"), "rows use the model's label")
        XCTAssertTrue(view.contains(".accessibilityLabel(\"Items to review, grouped by project\")"))
        XCTAssertTrue(view.contains(".keyboardShortcut(model.isReviewing ? \".\" : \"r\", modifiers: .command)"), "⌘R reviews and ⌘. stops")
        XCTAssertTrue(view.contains(".accessibilityHint("), "the primary action says what it does")
        // The hosted window still lays out every control in both appearances.
        try assertRenders(complete, "accessibility", contains: ["Refresh Review", "node_modules"])
    }

    /// Reopening the window after an interrupted review: the stored report
    /// keeps its limitations but not the uncovered paths, so the window states
    /// the rest is unknown without inventing a count. An item whose own size
    /// is a lower bound is still Partial after the reopen.
    func testAReopenedInterruptedReviewStaysPartial() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/ds-reopen-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "scope/engine/target")
        let modules = root.appending(path: "scope/web/node_modules")
        for folder in [target, modules] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let index = try ReviewIndex(url: root.appending(path: "steward.sqlite"))
        let scope = DirectoryChangeStream.canonicalPath(root.path + "/scope")
        func object(_ url: URL, _ project: String, unreadable: Int) -> ReviewObject {
            ReviewObject(path: DirectoryChangeStream.canonicalPath(url.path), kind: .artifact, rule: .manifest, reason: "a manifest beside it expects this output location",
                         projectPath: scope + "/" + project, recreateClass: .rebuild, allocatedBytes: 7 * gib, fileCount: 1, lastActivity: Date().timeIntervalSince1970,
                         unreadableDirectories: unreadable)
        }
        let stopped = ReviewReport(reportID: "stopped", scope: scope, startedAt: Date(), completedAt: Date(), status: .stopped(.wallTime), entriesVisited: 10,
                                   directoriesVisited: 4, scopeAllocatedBytes: 14 * gib,
                                   objects: [object(target, "engine", unreadable: 0), object(modules, "web", unreadable: 2)],
                                   projects: [], unresolved: [], unresolvedCount: 0, unreadableDirectories: 2, unreadableEntries: 0, skippedMounts: [], excluded: [],
                                   coveredTopLevel: [scope + "/engine", scope + "/web"], uncoveredTopLevel: [scope + "/huge"], classifierCalls: 0, repositoryQueries: 0,
                                   repositoryQuerySeconds: 0, repositoryProcesses: 0)
        _ = try await index.record(stopped)
        try await index.recordItems(ReviewRanking.rank(stopped, now: Date()), report: stopped)
        let window = ReviewWindowModel(service: nil, index: index, scopes: [.folder(root.path + "/scope")], capacity: { [comfortable] in comfortable })
        await window.loadLatest()
        XCTAssertEqual(window.reviewState, .partial)
        XCTAssertFalse(window.finishedWithUnreadable, "it stopped")
        let evidence = Dictionary(uniqueKeysWithValues: (window.display?.items ?? []).map { ($0.name, $0.evidence) })
        XCTAssertEqual(evidence, ["target": .verifiedNow, "node_modules": .partial], "only a size that is a lower bound is Partial")
        XCTAssertTrue(window.display?.items.first { $0.name == "node_modules" }?.reasonsToKeep.contains { $0.contains("lower bound") } == true)
        XCTAssertTrue(window.stateLine.contains("the rest of the scope was not reviewed and is unknown, not empty"), window.stateLine)
        XCTAssertFalse(window.stateLine.contains("0 folders"), "no invented count")
        XCTAssertTrue(window.display?.limitations.contains { $0.contains("huge") } == true, "the stored limitation names what was not reviewed")
        try assertRenders(window, "reopened-partial", contains: ["stopped before covering", "unknown, not empty", "huge", "Partial"])
        await index.close()
    }

    func testAReviewRunsEndToEndThroughTheWindow() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/ds-window-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, bytes) in [("scope/web/package.json", 100), ("scope/web/pnpm-lock.yaml", 100), ("scope/web/node_modules/.modules.yaml", 100),
                              ("scope/web/node_modules/a/package.json", 100), ("scope/web/node_modules/a/i.js", 80_000), ("scope/rust/Cargo.toml", 100),
                              ("scope/rust/target/debug/app", 300_000)] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }
        let index = try ReviewIndex(url: root.appending(path: "steward.sqlite"))
        let service = ReviewService(index: index, stateURL: root.appending(path: "review-state.json"), makeWalker: { previous, cancelled in
            ReviewWalker(decider: ClassifierObjectDecider(oracle: SilentRepositoryOracle()), previousCompleteEntries: previous, isCancelled: cancelled)
        })
        let box = CapacityBox(comfortable)
        let window = ReviewWindowModel(service: service, index: index, scopes: [.folder(root.path + "/scope")], capacity: { box.value })
        window.start()
        for _ in 0..<200 where window.isReviewing { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(window.reviewState, .completeWithItems)
        XCTAssertEqual(Set(window.display?.items.map(\.name) ?? []), ["target", "node_modules"])
        XCTAssertTrue(window.display?.items.allSatisfy { $0.evidence == .verifiedNow } == true, "revalidated against the live paths")
        // Reopening shows the stored review.
        let reopened = ReviewWindowModel(service: service, index: index, scopes: [.folder(root.path + "/scope")], capacity: { box.value })
        await reopened.loadLatest()
        XCTAssertEqual(reopened.reviewState, .completeWithItems)
        XCTAssertEqual(reopened.display?.items.count, 2)
        await index.close()
    }
}
