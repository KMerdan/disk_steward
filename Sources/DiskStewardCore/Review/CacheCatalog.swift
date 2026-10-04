import Foundation

/// One tool-owned cache the review can measure once the user opts it in.
public struct CacheCatalogEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Where the cache lives, first existing wins; `~` is the home folder.
    public let locations: [String]
    public let recreateClass: RecreateClass
    /// The owning tool's own cleanup command, shown as text and never run.
    public let cleanupCommand: String
    /// One sentence on what removing it costs.
    public let note: String

    public func resolvedPath(home: String) -> String? {
        locations.map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
            .first { FileManager.default.fileExists(atPath: $0) }
    }
}

/// TASK-631: the caches a review can measure. Nothing here is measured or
/// cleaned on its own: an entry is sized only after the user opts it into
/// review, and its command is text for a person.
public enum CacheCatalog {
    /// The scope label of a catalog review.
    public static let scope = "catalog:opted-in-caches"

    public static let entries: [CacheCatalogEntry] = [
        .init(id: "uv", name: "uv cache", locations: ["~/.cache/uv", "~/Library/Caches/uv"], recreateClass: .redownload,
              cleanupCommand: "uv cache prune", note: "uv downloads packages again when a project needs them."),
        .init(id: "npm", name: "npm cache", locations: ["~/.npm"], recreateClass: .redownload,
              cleanupCommand: "npm cache clean --force", note: "npm downloads packages again on the next install."),
        .init(id: "pnpm", name: "pnpm store", locations: ["~/Library/pnpm/store", "~/.local/share/pnpm/store", "~/.pnpm-store"], recreateClass: .redownload,
              cleanupCommand: "pnpm store prune", note: "pnpm re-downloads packages no project links any more."),
        .init(id: "library-caches", name: "Application caches", locations: ["~/Library/Caches"], recreateClass: .redownload,
              cleanupCommand: "Quit the app first, then remove its own folder inside ~/Library/Caches.",
              note: "Apps rebuild their caches; some start slower until they do."),
        .init(id: "coresimulator", name: "iOS simulators", locations: ["~/Library/Developer/CoreSimulator"], recreateClass: .expensive,
              cleanupCommand: "xcrun simctl delete unavailable", note: "Deleted simulators and their apps and data must be downloaded and set up again."),
        .init(id: "xcode-deriveddata", name: "Xcode DerivedData", locations: ["~/Library/Developer/Xcode/DerivedData"], recreateClass: .rebuild,
              cleanupCommand: "Xcode › Product › Clean Build Folder, or remove a project's folder inside ~/Library/Developer/Xcode/DerivedData.",
              note: "Xcode rebuilds it on the next build."),
        .init(id: "xcode-archives", name: "Xcode archives", locations: ["~/Library/Developer/Xcode/Archives"], recreateClass: .expensive,
              cleanupCommand: "Xcode › Window › Organizer › Archives: delete archives you no longer need.",
              note: "Archives hold the dSYMs that symbolicate crash reports of released builds; they cannot be rebuilt."),
        .init(id: "ollama", name: "Ollama models", locations: ["~/.ollama"], recreateClass: .expensive,
              cleanupCommand: "ollama rm <model>", note: "A removed model must be downloaded again, often several gigabytes."),
        .init(id: "docker", name: "Docker Desktop disk", locations: ["~/Library/Containers/com.docker.docker/Data/vms", "~/.docker"], recreateClass: .expensive,
              cleanupCommand: "docker system prune", note: "Pruned images, containers and volumes are pulled or rebuilt again."),
        .init(id: "actcache", name: "act cache", locations: ["~/.cache/actcache", "~/.cache/act"], recreateClass: .redownload,
              cleanupCommand: "Remove ~/.cache/actcache; act downloads actions again.", note: "act fetches actions and images again on the next run."),
    ]

    /// The caches a review measures: only opted-in entries whose location exists.
    public static func targets(optedIn: Set<String>, home: String = NSHomeDirectory()) -> [ReviewWalker.CatalogTarget] {
        entries.filter { optedIn.contains($0.id) }.compactMap { entry in
            guard let path = entry.resolvedPath(home: home) else { return nil }
            let canonical = DirectoryChangeStream.canonicalPath(path)
            return ReviewWalker.CatalogTarget(
                path: canonical,
                object: ClassifiedObject(path: canonical, kind: .cache, rule: .catalog, confidence: .high,
                                         reason: "it is the \(entry.name), which you opted into review. \(entry.note)"),
                recreateClass: entry.recreateClass, cleanupCommand: entry.cleanupCommand)
        }
    }
}
