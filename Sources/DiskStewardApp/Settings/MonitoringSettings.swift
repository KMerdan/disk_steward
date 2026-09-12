import DiskStewardCore
import Foundation

struct MonitoringSettings: Codable, Equatable, Sendable {
    var launchAtLogin: Bool
    var watchedRoots: [String]
    var excludedRoots: [String]
    var rawEventDays: Int
    var hourlySummaryDays: Int
    var dailySummaryDays: Int
    var maxDatabaseMiB: Int
    var writeCoalesceSeconds: Int
    var capacityThresholdPercent: Int
    var growthThresholdMiB: Int
    var sampleIntervalMinutes: Int
    var monitoringPaused: Bool
    var investigationRoot: String?
    var investigationExpiresAt: Date?

    static var defaults: MonitoringSettings {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return MonitoringSettings(
            launchAtLogin: false,
            watchedRoots: [
                home.appending(path: "Downloads", directoryHint: .isDirectory).path,
                home.appending(path: "Documents/Codex", directoryHint: .isDirectory).path,
            ],
            excludedRoots: [],
            rawEventDays: 7,
            hourlySummaryDays: 30,
            dailySummaryDays: 365,
            maxDatabaseMiB: 512,
            writeCoalesceSeconds: 15,
            capacityThresholdPercent: 90,
            growthThresholdMiB: 5_120,
            sampleIntervalMinutes: 5,
            monitoringPaused: false,
            investigationRoot: nil,
            investigationExpiresAt: nil
        )
    }

    mutating func normalize() {
        watchedRoots = Self.normalizedUnique(watchedRoots)
        excludedRoots = Self.normalizedUnique(excludedRoots)
        rawEventDays = min(30, max(1, rawEventDays))
        hourlySummaryDays = min(180, max(7, hourlySummaryDays))
        dailySummaryDays = min(730, max(30, dailySummaryDays))
        maxDatabaseMiB = min(10_240, max(10, maxDatabaseMiB))
        writeCoalesceSeconds = min(300, max(1, writeCoalesceSeconds))
        capacityThresholdPercent = min(99, max(50, capacityThresholdPercent))
        growthThresholdMiB = min(1_048_576, max(1, growthThresholdMiB))
        sampleIntervalMinutes = min(1_440, max(1, sampleIntervalMinutes))
        if let expiresAt = investigationExpiresAt, expiresAt <= Date() {
            investigationRoot = nil
            investigationExpiresAt = nil
        }
    }

    func monitoringPolicy(at date: Date) -> MonitoringPolicy {
        let investigation: [InvestigationWindow]
        if let investigationRoot, let investigationExpiresAt, investigationExpiresAt > date {
            investigation = [.init(root: URL(fileURLWithPath: investigationRoot), expiresAt: investigationExpiresAt)]
        } else {
            investigation = []
        }
        return MonitoringPolicy(
            watchedRoots: watchedRoots.map { URL(fileURLWithPath: $0, isDirectory: true) },
            excludedRoots: excludedRoots.map { URL(fileURLWithPath: $0, isDirectory: true) },
            investigations: investigation,
            coalescingWindow: TimeInterval(writeCoalesceSeconds)
        )
    }

    func retentionPolicy() throws -> EvidenceStoreRetentionPolicy {
        try EvidenceStoreRetentionPolicy(
            rawEventDays: rawEventDays,
            hourlySummaryDays: hourlySummaryDays,
            dailySummaryDays: dailySummaryDays,
            maxDatabaseBytes: Int64(maxDatabaseMiB) * 1_024 * 1_024,
            writeCoalesceSeconds: writeCoalesceSeconds,
            preserveUnreviewedAnomalies: true
        )
    }

    private static func normalizedUnique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { seen.insert($0).inserted }
            .sorted()
    }
}
