import CryptoKit
import Foundation

/// One file of a legacy evidence set, hashed before it was moved.
public struct LegacyEvidenceFile: Codable, Equatable, Sendable {
    /// The suffix after the set's name: ".sqlite", ".sqlite-wal", ".sqlite-shm".
    public let suffix: String
    public let bytes: Int64
    public let sha256: String
}

/// TASK-653: the retired per-file evidence store, renamed unmodified into
/// `legacy/` and kept only for export or rollback.
public struct LegacyEvidenceManifest: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case moving, migrated }

    public static let schema = "legacy-evidence-v1"
    public var schema = Self.schema
    /// "evidence-2026-10-04", or with "-2" and up for a second set that day.
    public let name: String
    public var status: Status
    public let migratedAt: Date
    /// The app version that performed the move.
    public let migratedBy: String
    public let files: [LegacyEvidenceFile]

    public var databaseBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

public enum LegacyEvidenceError: Error, Equatable, Sendable, LocalizedError {
    case confirmationRequired
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .confirmationRequired: return "Deleting legacy evidence needs confirmation."
        case let .notFound(name): return "There is no \(name) to export: nothing was moved to legacy/."
        }
    }
}

public enum LegacyEvidence {
    public static let directoryName = "legacy"
    static let databaseName = "evidence.sqlite"
    /// SQLite keeps uncheckpointed pages in `-wal`; it moves first, so an
    /// interrupted move never leaves the main file without its log.
    static let suffixes = [".sqlite-wal", ".sqlite-shm", ".sqlite-journal", ".sqlite"]
    static let cloneDirectoryPrefix = ".export-clone-"

    public static func directory(in supportDirectory: URL) -> URL {
        supportDirectory.appending(path: directoryName, directoryHint: .isDirectory)
    }

    static func manifestURL(_ name: String, in supportDirectory: URL) -> URL {
        directory(in: supportDirectory).appending(path: name + ".json")
    }

    public static func databaseURL(of manifest: LegacyEvidenceManifest, in supportDirectory: URL) -> URL {
        directory(in: supportDirectory).appending(path: manifest.name + ".sqlite")
    }

    /// Moves `evidence.sqlite` and its sidecars into `legacy/` by rename, so
    /// the bytes are unchanged, and records their hashes first. Resumes a move
    /// that was interrupted. Returns nil when there is nothing to move; then no
    /// `legacy/` directory is created.
    @discardableResult
    public static func migrate(
        supportDirectory: URL, at date: Date, migratedBy: String, fileManager: FileManager = .default
    ) throws -> LegacyEvidenceManifest? {
        try removeStaleClones(in: supportDirectory, fileManager: fileManager)
        if var pending = try manifests(in: supportDirectory).first(where: { $0.status == .moving }) {
            try move(pending, supportDirectory: supportDirectory, fileManager: fileManager)
            pending.status = .migrated
            try write(pending, in: supportDirectory)
            try moveConvergenceRecord(name: pending.name, supportDirectory: supportDirectory, fileManager: fileManager)
            return pending
        }
        let source = supportDirectory.appending(path: databaseName)
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        var files: [LegacyEvidenceFile] = []
        for suffix in suffixes {
            let url = supportDirectory.appending(path: "evidence" + suffix)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let (bytes, digest) = try hash(url)
            files.append(.init(suffix: suffix, bytes: bytes, sha256: digest))
        }
        try fileManager.createDirectory(at: directory(in: supportDirectory), withIntermediateDirectories: true)
        var manifest = LegacyEvidenceManifest(
            name: try availableName(for: date, in: supportDirectory, fileManager: fileManager),
            status: .moving, migratedAt: date, migratedBy: migratedBy, files: files)
        try write(manifest, in: supportDirectory)
        try move(manifest, supportDirectory: supportDirectory, fileManager: fileManager)
        manifest.status = .migrated
        try write(manifest, in: supportDirectory)
        try moveConvergenceRecord(name: manifest.name, supportDirectory: supportDirectory, fileManager: fileManager)
        return manifest
    }

    /// Migrated sets, newest first.
    public static func sets(in supportDirectory: URL) throws -> [LegacyEvidenceManifest] {
        try manifests(in: supportDirectory).filter { $0.status == .migrated }
    }

    /// Clones a set's files (an APFS clone: no copy, no change to the
    /// original) into a private directory beside it. SQLite only ever opens
    /// the clone, so the legacy bytes stay as they were moved.
    public static func clone(
        _ manifest: LegacyEvidenceManifest, supportDirectory: URL, fileManager: FileManager = .default
    ) throws -> URL {
        let target = directory(in: supportDirectory)
            .appending(path: cloneDirectoryPrefix + UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
        for file in manifest.files where file.suffix != ".sqlite-shm" {
            let from = directory(in: supportDirectory).appending(path: manifest.name + file.suffix)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            try fileManager.copyItem(at: from, to: target.appending(path: "evidence" + file.suffix))
        }
        return target.appending(path: databaseName)
    }

    /// Deletes a set only when the user confirmed it. `remove` defaults to
    /// moving each file to the Trash.
    public static func delete(
        _ manifest: LegacyEvidenceManifest, supportDirectory: URL, confirmed: Bool,
        remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        guard confirmed else { throw LegacyEvidenceError.confirmationRequired }
        let legacy = directory(in: supportDirectory)
        let names = manifest.files.map { manifest.name + $0.suffix } + [manifest.name + "-scan-convergence.json", manifest.name + ".json"]
        for name in names {
            let url = legacy.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { try remove(url) }
        }
    }

    // MARK: Internals

    static func hash(_ url: URL) throws -> (Int64, String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
            bytes += Int64(chunk.count)
        }
        return (bytes, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func move(_ manifest: LegacyEvidenceManifest, supportDirectory: URL, fileManager: FileManager) throws {
        let legacy = directory(in: supportDirectory)
        for suffix in suffixes {
            guard manifest.files.contains(where: { $0.suffix == suffix }) else { continue }
            let from = supportDirectory.appending(path: "evidence" + suffix)
            let to = legacy.appending(path: manifest.name + suffix)
            // Already moved before an interruption.
            guard fileManager.fileExists(atPath: from.path), !fileManager.fileExists(atPath: to.path) else { continue }
            try fileManager.moveItem(at: from, to: to)
        }
    }

    private static func moveConvergenceRecord(name: String, supportDirectory: URL, fileManager: FileManager) throws {
        let record = supportDirectory.appending(path: "scan-convergence.json")
        guard fileManager.fileExists(atPath: record.path) else { return }
        let target = directory(in: supportDirectory).appending(path: name + "-scan-convergence.json")
        guard !fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.moveItem(at: record, to: target)
    }

    private static func availableName(for date: Date, in supportDirectory: URL, fileManager: FileManager) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let base = "evidence-" + formatter.string(from: date)
        let legacy = directory(in: supportDirectory)
        var candidate = base
        var index = 2
        while try fileManager.contentsOfDirectory(atPath: legacy.path).contains(where: { $0.hasPrefix(candidate + ".") || $0.hasPrefix(candidate + "-scan") }) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    private static func manifests(in supportDirectory: URL) throws -> [LegacyEvidenceManifest] {
        let legacy = directory(in: supportDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: legacy.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A set renamed back by restore-legacy-evidence keeps its manifest as
        // `<name>.restored.json`; it is no longer a set here.
        return names.filter { $0.hasSuffix(".json") && !$0.hasSuffix("-scan-convergence.json") && !$0.hasSuffix(".restored.json") }
            .compactMap { try? decoder.decode(LegacyEvidenceManifest.self, from: Data(contentsOf: legacy.appending(path: $0))) }
            .filter { $0.schema == LegacyEvidenceManifest.schema }
            .sorted { ($0.migratedAt, $0.name) > ($1.migratedAt, $1.name) }
    }

    private static func write(_ manifest: LegacyEvidenceManifest, in supportDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(manifest.name, in: supportDirectory), options: .atomic)
    }

    private static func removeStaleClones(in supportDirectory: URL, fileManager: FileManager) throws {
        let legacy = directory(in: supportDirectory)
        guard let names = try? fileManager.contentsOfDirectory(atPath: legacy.path) else { return }
        for name in names where name.hasPrefix(cloneDirectoryPrefix) {
            try? fileManager.removeItem(at: legacy.appending(path: name))
        }
    }
}
