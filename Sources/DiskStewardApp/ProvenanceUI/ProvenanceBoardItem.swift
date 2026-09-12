import DiskStewardCore
import Foundation

struct ProvenanceBoardItem: Equatable, Sendable {
    let title: String
    let confidenceLabel: String
    let actorLabel: String
    let taskLabel: String
    let support: [ProvenanceSourceReference]
    let limitations: [String]

    init(claim: ProvenanceClaim) {
        let record = ProvenancePresentationAdapter().record(for: claim, channel: .userInterface)
        title = "\(record.operation): \(URL(fileURLWithPath: record.path).lastPathComponent)"
        confidenceLabel = record.confidence
        actorLabel = record.actorExecutable ?? record.actorPID.map { "PID \($0)" } ?? "Unknown process"
        taskLabel = record.sessionID ?? "No supported task link"
        support = record.support
        limitations = record.limitations
    }
}
