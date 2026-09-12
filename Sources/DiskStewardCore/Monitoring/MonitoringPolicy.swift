import Foundation

public struct InvestigationWindow: Equatable, Sendable {
    public let root: URL
    public let expiresAt: Date

    public init(root: URL, expiresAt: Date) {
        self.root = root
        self.expiresAt = expiresAt
    }
}

public struct MonitoringPolicy: Equatable, Sendable {
    public let watchedRoots: [URL]
    public let registeredRoots: [URL]
    public let excludedRoots: [URL]
    public let investigations: [InvestigationWindow]
    public let maximumEntries: Int
    public let maximumDepth: Int
    public let coalescingWindow: TimeInterval

    public init(
        watchedRoots: [URL],
        registeredRoots: [URL] = [],
        excludedRoots: [URL] = [],
        investigations: [InvestigationWindow] = [],
        maximumEntries: Int = 100_000,
        maximumDepth: Int = 64,
        coalescingWindow: TimeInterval = 15
    ) {
        self.watchedRoots = watchedRoots
        self.registeredRoots = registeredRoots
        self.excludedRoots = excludedRoots
        self.investigations = investigations
        self.maximumEntries = max(1, maximumEntries)
        self.maximumDepth = max(0, maximumDepth)
        self.coalescingWindow = min(300, max(1, coalescingWindow))
    }

    public func activeRoots(at date: Date) -> [URL] {
        normalizedUnique(
            watchedRoots + registeredRoots + investigations.filter { $0.expiresAt > date }.map(\.root)
        )
    }

    public func includes(path: String, at date: Date) -> Bool {
        let normalized = Self.normalized(path)
        guard activeRoots(at: date).contains(where: { Self.contains(normalized, root: $0.path) }) else {
            return false
        }
        return !normalizedUnique(excludedRoots).contains(where: { Self.contains(normalized, root: $0.path) })
    }

    public func exclusionReason(for path: String) -> String? {
        let normalized = Self.normalized(path)
        guard let root = normalizedUnique(excludedRoots).first(where: { Self.contains(normalized, root: $0.path) }) else {
            return nil
        }
        return "Excluded by configured root \(root.path)."
    }

    public func scopeLimitations(at date: Date) -> [String] {
        var limitations = [
            "File-level detail is limited to configured roots: \(activeRoots(at: date).map(\.path).joined(separator: ", ")).",
        ]
        limitations.append(contentsOf: normalizedUnique(excludedRoots).map { "Excluded subtree: \($0.path)." })
        limitations.append(contentsOf: investigations
            .filter { $0.expiresAt <= date }
            .map { "Investigation window expired for \($0.root.standardizedFileURL.path)." })
        return limitations.sorted()
    }

    private func normalizedUnique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls
            .map { URL(fileURLWithPath: Self.normalized($0.path), isDirectory: true) }
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func contains(_ path: String, root: String) -> Bool {
        let normalizedRoot = normalized(root)
        return path == normalizedRoot || path.hasPrefix(normalizedRoot == "/" ? "/" : normalizedRoot + "/")
    }
}
