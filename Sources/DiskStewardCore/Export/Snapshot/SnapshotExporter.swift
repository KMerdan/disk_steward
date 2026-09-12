import Foundation

public struct SnapshotExporter: Sendable {
    public typealias IdentifierSource = @Sendable () -> String

    private let productVersion: String
    private let identifierSource: IdentifierSource

    public init(
        productVersion: String = "0.1.0",
        identifierSource: @escaping IdentifierSource = { UUID().uuidString.lowercased() }
    ) {
        self.productVersion = productVersion
        self.identifierSource = identifierSource
    }

    public func export(_ snapshot: StorageSnapshot, to parentDirectory: URL) throws -> SnapshotExportResult {
        let bundleID = identifierSource()
        guard isSafePathComponent(bundleID) else { throw SnapshotExportError.unsafeBundleIdentifier }

        let bundleURL = parentDirectory.appending(path: "disk-steward-\(bundleID)", directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw SnapshotExportError.destinationAlreadyExists
        }

        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: false)

        do {
            let encoder = Self.encoder()
            let snapshotData = try encoder.encode(snapshot)
            let briefData = Data(brief(for: snapshot).utf8)
            let payloads: [(String, SnapshotExportManifest.FileEntry.Role, Data)] = [
                ("codex-brief.md", .codexBrief, briefData),
                ("storage-snapshot.json", .snapshot, snapshotData),
            ]

            for (path, _, data) in payloads {
                try data.write(to: bundleURL.appending(path: path), options: .atomic)
            }

            let manifest = SnapshotExportManifest(
                schema: "export-manifest-v1",
                bundleID: bundleID,
                createdAt: snapshot.observedAt,
                producer: .init(
                    name: ProductIdentity.diskSteward.evidenceProducer,
                    version: productVersion,
                    evidenceSchemaVersion: 1
                ),
                requestedRange: .init(from: snapshot.observedAt, through: snapshot.observedAt),
                files: payloads.map { path, role, data in
                    .init(path: path, role: role, sha256: SHA256Digest.hex(for: data), bytes: data.count)
                },
                limitations: snapshot.limitations,
                privacy: .init(
                    containsFileContents: false,
                    containsEnvironment: false,
                    pathDetail: "full"
                )
            )
            try encoder.encode(manifest).write(
                to: bundleURL.appending(path: "manifest.json"),
                options: .atomic
            )
            return SnapshotExportResult(bundleURL: bundleURL, manifest: manifest)
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }
    }

    private func brief(for snapshot: StorageSnapshot) -> String {
        let rows = snapshot.volumes.map { volume in
            "| `\(volume.mountPath)` | \(volume.totalBytes) | \(volume.usedBytes) | \(volume.availableBytes) |"
        }.joined(separator: "\n")
        let limitations = snapshot.limitations.isEmpty
            ? "- None reported."
            : snapshot.limitations.map { "- \($0)" }.joined(separator: "\n")

        return """
        # Disk Steward Snapshot

        Observed: \(snapshot.observedAt)  
        Snapshot ID: `\(snapshot.snapshotID)`  
        Scope: `\(snapshot.scope.rawValue)`

        | Mount | Total bytes | Used bytes | Available bytes |
        |---|---:|---:|---:|
        \(rows)

        ## Limitations

        \(limitations)

        Privacy: capacity metadata only; no file contents or environment variables are included.
        """
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
