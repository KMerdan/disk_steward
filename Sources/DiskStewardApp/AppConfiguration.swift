import AppKit
import Darwin

enum AppConfiguration {
    static let activationPolicy: NSApplication.ActivationPolicy = .accessory
    static let defaultExportFolderName = "Disk Steward Exports"

    static let isSmoke = CommandLine.arguments.contains("--ui-smoke")
    static let supportDirectory = resolveSupportDirectory(isSmoke: isSmoke)

    static func resolveSupportDirectory(
        isSmoke: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        // Smoke mode must never inherit a production directory, even when its
        // caller mistakenly passes one. No defaults, roots or access flag leak in.
        if isSmoke {
            return FileManager.default.temporaryDirectory.appending(path: "ds-smoke-\(UUID().uuidString)")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Disk Steward", directoryHint: .isDirectory)
    }

    static func validateLaunch(isSmoke: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        // A database-path override alone does not isolate defaults, watched roots,
        // client profiles, notifications or FSEvents. Reject it before startup.
        if !isSmoke, let override = environment["DISK_STEWARD_SUPPORT_DIRECTORY"], !override.isEmpty {
            throw NSError(domain: "DiskSteward.Isolation", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "A support-directory override is not an isolated launch. Use --ui-smoke for isolated verification."
            ])
        }
    }

    /// Verification artifacts may use an explicit destination only when it is a
    /// new leaf in an existing private temporary directory. Never replace or
    /// recursively remove a caller-supplied directory, even during a test.
    static func createVerificationArtifactDirectory(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let parent = url.deletingLastPathComponent()
        let temporaryRoots = [URL(fileURLWithPath: "/private/tmp"), FileManager.default.temporaryDirectory]
            .compactMap { canonicalPOSIXPath($0.path) }
        var metadata = stat()
        guard path.hasPrefix("/"), !path.contains("//"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              canonicalPOSIXPath(parent.path) == parent.path,
              temporaryRoots.contains(where: { parent.path.hasPrefix($0 + "/") }),
              lstat(parent.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        // mkdir is exclusive: an existing file, directory or symlink fails.
        guard mkdir(url.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }

    private static func canonicalPOSIXPath(_ path: String) -> String? {
        // Foundation may prettify /private/tmp as /tmp for existing files.
        // POSIX realpath provides the physical spelling used by these guards.
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

enum AppMenuLabels {
    static let statusItem = "Disk Steward"
    static let generalExport = "Export Current Evidence"
    static let settings = "Settings…"
    static let about = "About Disk Steward"
    static let quit = "Quit Disk Steward"
}
