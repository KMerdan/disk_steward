import DiskStewardCore
import Foundation

/// Why a scan generation was judged unable to converge.
enum ScanConvergenceReason: String, Codable, Equatable, Sendable {
    /// The scanner keeps re-walking: processed entries far exceed staged files.
    case processedFarBeyondStaged = "processed-far-beyond-staged"
    /// Storage refused the scan on consecutive samples.
    case storageRefused = "storage-refused"
    /// The generation has consumed more active scan time than any review should.
    case activeWorkExceeded = "active-work-exceeded"
}

/// Thresholds for abandoning a scan that cannot converge. A stopped scope is
/// not restarted until the cooldown passes or the scope or store limit changes.
struct ScanConvergencePolicy: Equatable, Sendable {
    var processedToStagedRatio: Int64 = 20
    /// Staged counts below this floor are judged as the floor, so a young
    /// generation is stopped for the ratio only after 20 x 100k entries.
    var minimumJudgedStaged: Int64 = 100_000
    var consecutiveRefusedSamples = 3
    var maximumActiveWork: TimeInterval = 6 * 60 * 60
    var cooldown: TimeInterval = 24 * 60 * 60

    func verdict(processed: Int64, staged: Int64, consecutiveRefusals: Int, activeWork: TimeInterval) -> ScanConvergenceReason? {
        if processed > processedToStagedRatio * max(staged, minimumJudgedStaged) { return .processedFarBeyondStaged }
        if consecutiveRefusals >= consecutiveRefusedSamples { return .storageRefused }
        if activeWork > maximumActiveWork { return .activeWorkExceeded }
        return nil
    }
}

/// The persisted stop: one explicit state with its reason and remedies.
struct ScanConvergenceStop: Codable, Equatable, Sendable {
    let generationID: String
    let scopeVersionID: String
    let capBytes: Int64
    let stoppedAt: Date
    let reason: ScanConvergenceReason
    let processedEntryCount: Int64
    let stagedFileCount: Int64

    /// Whether this stop still holds for the given scope and limit.
    func applies(scopeVersionID: String, capBytes: Int64, at date: Date, policy: ScanConvergencePolicy) -> Bool {
        self.scopeVersionID == scopeVersionID && self.capBytes == capBytes
            && date.timeIntervalSince(stoppedAt) < policy.cooldown
    }

    var message: String {
        let cause: String
        switch reason {
        case .processedFarBeyondStaged:
            cause = "it kept re-walking without finishing: \(processedEntryCount) entries processed, \(stagedFileCount) files staged"
        case .storageRefused:
            cause = "evidence storage refused it on consecutive samples"
        case .activeWorkExceeded:
            cause = "it used more than six hours of scan time without finishing"
        }
        return "File-detail scanning stopped: the watched folders are too large for the evidence store limit (\(cause)). "
            + "Capacity monitoring continues. To resume detail, remove large folders from the watched roots or raise the store limit; "
            + "otherwise the scan is retried after 24 hours."
    }
}

/// A small JSON record beside the evidence store. It survives relaunch, so a
/// stopped scope is not silently restarted, and it carries the generation's
/// accumulated active scan time.
struct ScanConvergenceRecord: Codable, Equatable, Sendable {
    var stop: ScanConvergenceStop?
    var activeWorkGenerationID: String?
    var activeWorkSeconds: TimeInterval = 0

    static func url(beside databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appending(path: "scan-convergence.json")
    }

    static func load(from url: URL) -> ScanConvergenceRecord {
        guard let data = try? Data(contentsOf: url) else { return .init() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // An unreadable record must not block monitoring; it only loses the
        // cooldown, which the convergence verdict re-establishes.
        return (try? decoder.decode(ScanConvergenceRecord.self, from: data)) ?? .init()
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
    }

    func activeWork(for generationID: String) -> TimeInterval {
        activeWorkGenerationID == generationID ? activeWorkSeconds : 0
    }

    mutating func addActiveWork(_ seconds: TimeInterval, generationID: String) {
        if activeWorkGenerationID != generationID {
            activeWorkGenerationID = generationID
            activeWorkSeconds = 0
        }
        activeWorkSeconds += max(0, seconds)
    }
}
