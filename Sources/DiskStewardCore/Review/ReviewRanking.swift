import Darwin
import Foundation

/// One object in a review, ranked for a person to look at. Never a verdict:
/// every item is review-required, and removing it is the person's decision.
public struct RankedReviewItem: Sendable, Equatable {
    public enum State: String, Sendable, Codable {
        /// Present at the last check; a person must review it before removing anything.
        case reviewRequired = "review-required"
        /// Gone since the review measured it.
        case missing
    }

    public let rank: Int
    public let object: ReviewObject
    public let projectPath: String?
    /// Days since the owning project's newest source change; nil when no project owns it.
    public let projectIdleDays: Double?
    public let score: Double
    /// Bytes a removal would free, as measured; the object's allocated size.
    public let reclaimableBytes: Int64
    /// How to recreate it, or a sentence saying the command is unknown.
    public let rebuildCommand: String
    public let rebuildCommandKnown: Bool
    /// The owning tool's own cleanup command, as text, when it has one.
    public let cleanupCommand: String?
    public var state: State
    public var verifiedAt: Date
    public let reasons: [String]
}

/// TASK-622: ranks a review's objects by what reviewing them could be worth.
///
/// The score is a pure function of the recorded report and `now`: size,
/// times how long the owning *project* has been idle (never the object's own
/// timestamp, which a rebuild refreshes), times a narrow recreate-cost
/// factor. A project idle for 30 days or more always outranks an equally
/// sized object in a project changed within a day. Repositories are measured
/// but never ranked.
public enum ReviewRanking {
    public static let maximumItems = 2_000
    /// The reason that marks an item's size as a lower bound; stored with
    /// the item, so a reopened review can still tell.
    public static let unreadableInside = "folders inside could not be read; the size covers the rest."

    public static func sizeIsLowerBound(reasons: [String]) -> Bool { reasons.contains { $0.hasSuffix(unreadableInside) } }
    /// Idle time beyond which more idleness no longer raises the score.
    public static let idleSaturationDays = 180.0

    public static func idleFactor(days: Double?) -> Double {
        guard let days else { return 0.2 }
        return 0.2 + 0.8 * min(max(days, 0), idleSaturationDays) / idleSaturationDays
    }

    /// Kept narrow on purpose, so idleness, not the kind of output, decides.
    public static func recreateFactor(_ recreate: RecreateClass) -> Double {
        switch recreate {
        case .redownload: return 1.0
        case .rebuild: return 0.92
        case .expensive: return 0.85
        case .liveState: return 0
        }
    }

    public static func rank(_ report: ReviewReport, now: Date) -> [RankedReviewItem] {
        let projects = Dictionary(uniqueKeysWithValues: report.projects.map { ($0.path, $0) })
        let scored = report.objects.filter { $0.kind != .repository }.map { object -> (ReviewObject, ReviewProject?, Double?, Double) in
            let project = object.rule == .catalog ? nil : owningProject(of: object, in: projects)
            // A tool cache has no project: its own newest use is what idleness means.
            let idle = object.rule == .catalog
                ? max(0, now.timeIntervalSince1970 - object.lastActivity) / 86_400
                : project.map { max(0, now.timeIntervalSince1970 - $0.lastSourceActivity) / 86_400 }
            let score = Double(object.allocatedBytes) * idleFactor(days: idle) * recreateFactor(object.recreateClass)
            return (object, project, idle, score)
        }.sorted { lhs, rhs in
            if lhs.3 != rhs.3 { return lhs.3 > rhs.3 }
            if lhs.0.allocatedBytes != rhs.0.allocatedBytes { return lhs.0.allocatedBytes > rhs.0.allocatedBytes }
            return lhs.0.path < rhs.0.path
        }
        return scored.prefix(maximumItems).enumerated().map { index, entry in
            let (object, project, idle, score) = entry
            let tools = toolHints(for: project, in: projects)
            let command = rebuildCommand(for: object, tools: tools)
            var reasons = [String(object.reason.prefix(1)).uppercased() + String(object.reason.dropFirst()) + "."]
            if object.rule == .catalog, let idle {
                reasons.append("It was last used \(Self.days(idle)) ago.")
            } else if let project, let idle {
                reasons.append("Its project (\(URL(fileURLWithPath: project.path).lastPathComponent)) last changed \(Self.days(idle)) ago.")
            } else {
                reasons.append("No owning project was found, so it is ranked as if just used.")
            }
            reasons.append(recreateSentence(object.recreateClass))
            if object.unreadableDirectories > 0 {
                reasons.append("\(object.unreadableDirectories) \(Self.unreadableInside)")
            }
            return RankedReviewItem(rank: index + 1, object: object, projectPath: project?.path ?? object.projectPath, projectIdleDays: idle,
                                    score: score, reclaimableBytes: object.allocatedBytes, rebuildCommand: command.text,
                                    rebuildCommandKnown: command.known, cleanupCommand: object.cleanupCommand,
                                    state: .reviewRequired, verifiedAt: report.completedAt, reasons: reasons)
        }
    }

    /// Checks each item against its live path: still a directory with the
    /// same name is review-required (re-verified now); otherwise it is gone.
    public static func revalidate(_ items: [RankedReviewItem], at date: Date) -> [RankedReviewItem] {
        items.map { item in
            var updated = item
            var status = stat()
            let present = lstat(item.object.path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
            updated.state = present ? .reviewRequired : .missing
            updated.verifiedAt = date
            return updated
        }
    }

    // MARK: Rebuild commands

    /// The nearest project at or above the object's own project.
    static func owningProject(of object: ReviewObject, in projects: [String: ReviewProject]) -> ReviewProject? {
        var candidate = object.projectPath ?? parent(object.path)
        for _ in 0 ..< ObjectClassifier.maximumAncestorDepth {
            if let project = projects[candidate] { return project }
            if candidate == "/" || candidate.isEmpty { return nil }
            candidate = parent(candidate)
        }
        return nil
    }

    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    /// Tools of the project and of every enclosing project (a lockfile often
    /// lives at a monorepo root above the package that owns the output).
    static func toolHints(for project: ReviewProject?, in projects: [String: ReviewProject]) -> Set<String> {
        guard let project else { return [] }
        var tools = Set(project.tools)
        for (path, other) in projects where project.path.hasPrefix(path == "/" ? "/" : path + "/") { tools.formUnion(other.tools) }
        return tools
    }

    public static func rebuildCommand(for object: ReviewObject, tools: Set<String>) -> (text: String, known: Bool) {
        let name = URL(fileURLWithPath: object.path).lastPathComponent
        func node(_ script: String?) -> (String, Bool) {
            let manager = tools.contains("pnpm") ? "pnpm" : tools.contains("yarn") ? "yarn" : tools.contains("bun") ? "bun" : "npm"
            if let script { return ("\(manager) run \(script)", true) }
            switch manager {
            case "pnpm": return ("pnpm install", true)
            case "yarn": return ("yarn install", true)
            case "bun": return ("bun install", true)
            default: return (tools.contains("npm") ? "npm ci" : "npm install", true)
            }
        }
        if object.rule == .catalog {
            return object.recreateClass == .expensive
                ? ("Expensive to recreate: it must be downloaded or set up again.", true)
                : ("Recreated by the tool that owns it the next time it needs the cache.", true)
        }
        if object.kind == .cache { return ("Recreated by the tool that owns it the next time it needs the cache.", true) }
        switch name {
        case "node_modules": return node(nil)
        case ".next", ".nuxt", ".turbo", ".parcel-cache", "dist", "out": return node("build")
        case "target": return tools.contains("cargo") ? ("cargo build", true) : unknown(name)
        case ".build", ".swiftpm": return tools.contains("swiftpm") ? ("swift build", true) : unknown(name)
        case ".venv", "venv":
            if tools.contains("uv") { return ("uv sync", true) }
            if tools.contains("poetry") { return ("poetry install", true) }
            if tools.contains("pipenv") { return ("pipenv install", true) }
            if tools.contains("pip") { return ("python3 -m venv \(name) && \(name)/bin/pip install -r requirements.txt", true) }
            return ("python3 -m venv \(name), then reinstall the project's dependencies", true)
        case "__pycache__", ".pytest_cache", ".mypy_cache": return ("Recreated automatically the next time the tool runs.", true)
        case ".tox": return ("tox", true)
        case ".gradle": return ("gradle build", true)
        case "build":
            if tools.contains("gradle") { return ("gradle build", true) }
            if tools.contains("cmake") { return ("cmake -S . -B build && cmake --build build", true) }
            if tools.contains("meson") { return ("meson setup build", true) }
            if tools.contains("make") { return ("make", true) }
            return unknown(name)
        case "vendor":
            if tools.contains("go") { return ("go mod vendor", true) }
            if tools.contains("composer") { return ("composer install", true) }
            return unknown(name)
        case "Pods": return ("pod install", true)
        default: return unknown(name)
        }
    }

    private static func unknown(_ name: String) -> (text: String, known: Bool) {
        ("Unknown: no rebuild command is known for \(name) here; check the project's own instructions before removing it.", false)
    }

    private static func recreateSentence(_ recreate: RecreateClass) -> String {
        switch recreate {
        case .rebuild: return "It can be rebuilt from source."
        case .redownload: return "It can be downloaded again."
        case .expensive: return "It is expensive to recreate."
        case .liveState: return "It is live state and is never a candidate."
        }
    }

    private static func days(_ value: Double) -> String {
        value < 1 ? "less than a day" : value < 2 ? "1 day" : "\(Int(value)) days"
    }
}
