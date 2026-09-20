import Darwin
import Foundation

/// A directory Disk Steward records as one piece of evidence and never
/// enumerates inside. See docs/reliability/evidence/CONTRACT-601/object-contract.md.
public enum ClassifiedObjectKind: String, Equatable, Sendable, Codable {
    case artifact
    case cache
    case repository
}

/// The rule that decided a directory, in the order they are applied. The order
/// and the rules themselves come from the corpus measurement in RESEARCH-601.
public enum ObjectDetectionRule: String, Equatable, Sendable, Codable {
    /// The owning repository tracks files inside it: source, never an object.
    case tracked
    /// A marker inside it identifies it whatever it is named.
    case selfMarker = "self-marker"
    /// Its contents identify it.
    case content
    /// The owning repository ignores it.
    case ignored
    /// A project manifest beside it expects that output location.
    case manifest
    /// A repository directory.
    case repository
    /// A known output name with no project evidence: not classified.
    case unresolved
}

public enum ObjectDetectionConfidence: String, Equatable, Sendable, Codable {
    case high
    case medium
}

public struct ClassifiedObject: Equatable, Sendable, Codable {
    public let path: String
    public let kind: ClassifiedObjectKind
    public let rule: ObjectDetectionRule
    public let confidence: ObjectDetectionConfidence
    /// One sentence naming the evidence, shown to a person verbatim.
    public let reason: String
    public let owningProjectPath: String?
    public let owningProjectMarker: String?

    public init(path: String, kind: ClassifiedObjectKind, rule: ObjectDetectionRule,
                confidence: ObjectDetectionConfidence, reason: String,
                owningProjectPath: String? = nil, owningProjectMarker: String? = nil) {
        self.path = path
        self.kind = kind
        self.rule = rule
        self.confidence = confidence
        self.reason = reason
        self.owningProjectPath = owningProjectPath
        self.owningProjectMarker = owningProjectMarker
    }

    /// A repository is measured, never offered for cleanup.
    public var isCleanupCandidate: Bool { kind != .repository }
}

/// A directory that carries a known output name but no project evidence. It is
/// never an object; it is reported so a person can decide, never guessed at.
public struct UnresolvedCandidate: Equatable, Sendable, Codable {
    public let path: String
    public let name: String
    public let reason: String

    public init(path: String, name: String, reason: String) {
        self.path = path
        self.name = name
        self.reason = reason
    }
}

public enum ObjectClassification: Equatable, Sendable {
    case object(ClassifiedObject)
    /// Source that merely looks like output. Never an object, never a candidate.
    case source(path: String, reason: String)
    case unresolved(UnresolvedCandidate)

    public var object: ClassifiedObject? {
        if case let .object(value) = self { return value }
        return nil
    }
}

/// What a repository can say about a path. A repository that cannot be read
/// decides nothing: every answer is optional and `nil` means "no verdict".
public protocol RepositoryOracle: Sendable {
    /// True when the repository ignores the path, false when it does not,
    /// nil when the repository could not answer.
    func ignores(path: String, repositoryPath: String) -> Bool?
    /// True when the repository tracks files inside the path, false when it
    /// does not, nil when the repository could not answer.
    func tracksContents(ofPath path: String, repositoryPath: String) -> Bool?
}

/// A repository that never answers. Classification then falls through to the
/// evidence that does not need one.
public struct SilentRepositoryOracle: RepositoryOracle {
    public init() {}
    public func ignores(path _: String, repositoryPath _: String) -> Bool? { nil }
    public func tracksContents(ofPath _: String, repositoryPath _: String) -> Bool? { nil }
}

public struct ObjectDetectionRules: Sendable {
    /// Directory name -> manifests beside it that make it an expected output.
    public let outputNames: [String: [String]]
    /// Marker file inside a directory -> the kind and the sentence it earns.
    public let selfMarkers: [String: (kind: ClassifiedObjectKind, reason: String)]
    public let repositoryMarker: String

    public static let `default` = ObjectDetectionRules(
        outputNames: [
            "node_modules": ["package.json"],
            "target": ["Cargo.toml"],
            ".build": ["Package.swift"],
            "build": ["CMakeLists.txt", "build.gradle", "build.gradle.kts", "Makefile", "meson.build"],
            "dist": ["package.json", "pyproject.toml", "setup.py"],
            ".next": ["package.json"],
            ".nuxt": ["package.json"],
            ".turbo": ["package.json"],
            ".parcel-cache": ["package.json"],
            "out": ["package.json"],
            ".venv": ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile"],
            "venv": ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile"],
            "__pycache__": ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg"],
            ".tox": ["tox.ini", "pyproject.toml"],
            ".pytest_cache": ["pyproject.toml", "pytest.ini", "setup.cfg", "tox.ini"],
            ".mypy_cache": ["mypy.ini", "pyproject.toml", "setup.cfg"],
            ".gradle": ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
            "vendor": ["go.mod", "composer.json"],
            "Pods": ["Podfile"],
            ".swiftpm": ["Package.swift"],
        ],
        selfMarkers: [
            "pyvenv.cfg": (.artifact, "it contains pyvenv.cfg, so it is a Python virtual environment"),
            "CACHEDIR.TAG": (.cache, "it is tagged as a cache directory (CACHEDIR.TAG)"),
        ],
        repositoryMarker: ".git"
    )

    public init(outputNames: [String: [String]],
                selfMarkers: [String: (kind: ClassifiedObjectKind, reason: String)],
                repositoryMarker: String) {
        self.outputNames = outputNames
        self.selfMarkers = selfMarkers
        self.repositoryMarker = repositoryMarker
    }

    public func isCandidateName(_ name: String) -> Bool {
        name == repositoryMarker || outputNames[name] != nil
    }
}

/// Decides whether a directory is an object, source that merely looks like
/// output, or a candidate with no evidence either way.
///
/// The classifier only reads: it never writes to the examined tree and never
/// executes a project's own tooling. A repository is consulted through
/// `RepositoryOracle`, which reads an index and ignore rules and nothing else.
public struct ObjectClassifier: Sendable {
    private let rules: ObjectDetectionRules
    private let oracle: any RepositoryOracle

    public init(rules: ObjectDetectionRules = .default,
                oracle: any RepositoryOracle = SilentRepositoryOracle()) {
        self.rules = rules
        self.oracle = oracle
    }

    /// `FileManager` is not `Sendable`, so each read takes the thread-local
    /// default rather than storing one.
    private var fileManager: FileManager { .default }

    /// Classify one directory. `repositoryPath` is the nearest enclosing
    /// repository, when one exists; `repositoryPath(for:)` finds it.
    public func classify(directoryPath: String, repositoryPath: String? = nil) -> ObjectClassification {
        let url = URL(fileURLWithPath: directoryPath)
        let name = url.lastPathComponent

        if name == rules.repositoryMarker, isDirectory(directoryPath) {
            return .object(ClassifiedObject(
                path: directoryPath, kind: .repository, rule: .repository, confidence: .high,
                reason: "a repository is measured as one object and is never offered for cleanup",
                owningProjectPath: url.deletingLastPathComponent().path,
                owningProjectMarker: rules.repositoryMarker))
        }

        // 1. Tracked source is refused before any other evidence is considered.
        if let repositoryPath, oracle.tracksContents(ofPath: directoryPath, repositoryPath: repositoryPath) == true {
            return .source(path: directoryPath,
                           reason: "the owning repository tracks files inside it, so it is source, not output")
        }

        // 2. A marker inside it identifies it whatever it is named.
        if let marker = selfMarker(in: directoryPath) {
            return .object(ClassifiedObject(
                path: directoryPath, kind: marker.kind, rule: .selfMarker, confidence: .high,
                reason: marker.reason,
                owningProjectPath: repositoryPath, owningProjectMarker: repositoryPath == nil ? nil : rules.repositoryMarker))
        }

        guard let manifests = rules.outputNames[name] else {
            return .unresolved(UnresolvedCandidate(
                path: directoryPath, name: name,
                reason: "no known output name and no marker inside it"))
        }

        // 3. Its contents identify it.
        if let reason = contentEvidence(name: name, directoryPath: directoryPath) {
            return .object(ClassifiedObject(
                path: directoryPath, kind: .artifact, rule: .content, confidence: .high, reason: reason,
                owningProjectPath: repositoryPath, owningProjectMarker: repositoryPath == nil ? nil : rules.repositoryMarker))
        }

        // 4. The owning repository ignores it.
        if let repositoryPath, oracle.ignores(path: directoryPath, repositoryPath: repositoryPath) == true {
            return .object(ClassifiedObject(
                path: directoryPath, kind: .artifact, rule: .ignored, confidence: .high,
                reason: "the owning repository ignores it",
                owningProjectPath: repositoryPath, owningProjectMarker: rules.repositoryMarker))
        }

        // 5. A manifest beside it expects this output location.
        let parent = url.deletingLastPathComponent()
        if let marker = manifests.first(where: { fileManager.fileExists(atPath: parent.appendingPathComponent($0).path) }) {
            return .object(ClassifiedObject(
                path: directoryPath, kind: .artifact, rule: .manifest, confidence: .medium,
                reason: "\(marker) beside it expects this output location",
                owningProjectPath: parent.path, owningProjectMarker: marker))
        }

        // 6. A known output name and nothing else: never guessed at.
        return .unresolved(UnresolvedCandidate(
            path: directoryPath, name: name,
            reason: "a known output name with no project evidence"))
    }

    /// The nearest enclosing repository of a path, if any.
    ///
    /// Only an absolute path has ancestors to walk. A relative one would make
    /// `deletingLastPathComponent` prepend `..` forever instead of reaching a
    /// fixed point, so it decides nothing, and the walk is bounded as well.
    public func repositoryPath(for directoryPath: String) -> String? {
        guard directoryPath.hasPrefix("/") else { return nil }
        var current = URL(fileURLWithPath: directoryPath).standardizedFileURL
        for _ in 0 ..< Self.maximumAncestorDepth {
            if isDirectory(current.appendingPathComponent(rules.repositoryMarker).path) { return current.path }
            if current.path == "/" { return nil }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }

    /// A filesystem path deeper than this is not walked to its root; nothing
    /// real reaches it, and an unbounded walk is how a bad path hangs a scan.
    public static let maximumAncestorDepth = 256

    /// The ancestors of a path, outermost last, bounded the same way.
    public func ancestors(of directoryPath: String) -> [String] {
        guard directoryPath.hasPrefix("/") else { return [] }
        var current = URL(fileURLWithPath: directoryPath).standardizedFileURL
        var paths: [String] = []
        for _ in 0 ..< Self.maximumAncestorDepth {
            paths.append(current.path)
            if current.path == "/" { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        return paths
    }

    private func selfMarker(in directoryPath: String) -> (kind: ClassifiedObjectKind, reason: String)? {
        for (marker, value) in rules.selfMarkers
        where fileManager.fileExists(atPath: URL(fileURLWithPath: directoryPath).appendingPathComponent(marker).path) {
            return value
        }
        return nil
    }

    /// Content evidence, bounded: it reads one directory level, never a subtree.
    private func contentEvidence(name: String, directoryPath: String) -> String? {
        let url = URL(fileURLWithPath: directoryPath)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directoryPath) else { return nil }
        switch name {
        case "__pycache__":
            guard !entries.isEmpty else { return nil }
            let onlyBytecode = entries.allSatisfy { $0.hasSuffix(".pyc") || $0.hasSuffix(".pyo") }
            return onlyBytecode ? "it holds only compiled Python bytecode" : nil
        case "node_modules":
            for entry in entries {
                if [".package-lock.json", ".yarn-state.yml", ".modules.yaml"].contains(entry) {
                    return "it holds an installer's own state file"
                }
                let candidate = url.appendingPathComponent(entry)
                if isDirectory(candidate.path),
                   fileManager.fileExists(atPath: candidate.appendingPathComponent("package.json").path) {
                    return "it holds installed packages with their own manifests"
                }
            }
            return nil
        default:
            return nil
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }
}
