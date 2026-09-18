
import Foundation
import DiskStewardCore

struct Interrupted: Error {}

@main
struct StoreProbe {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else { fail("usage: store-probe <open|create|backup> <db> [--seed N] [--interrupt STAGE] [--destination PATH]", code: 64) }
        let command = arguments.removeFirst()
        guard !arguments.isEmpty else { fail("missing database path", code: 64) }
        let database = URL(fileURLWithPath: arguments.removeFirst())
        var seed = 0
        var interrupt: String? = nil
        var destination: URL? = nil
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            guard !arguments.isEmpty else { fail("missing value for \(flag)", code: 64) }
            let value = arguments.removeFirst()
            switch flag {
            case "--seed": seed = Int(value) ?? 0
            case "--interrupt": interrupt = value
            case "--destination": destination = URL(fileURLWithPath: value)
            default: fail("unknown flag \(flag)", code: 64)
            }
        }
        let stage = interrupt
        do {
            let store = try EvidenceStore(url: database, migrationCheckpoint: { reached in
                if let stage, reached == stage { throw Interrupted() }
            })
            if command == "create", seed > 0 {
                let base = Date(timeIntervalSince1970: 1_900_000_000)
                let events = (0..<seed).map { index in
                    EvidenceStoreEvent(
                        eventID: "rehearsal-\(index)", observedAt: base.addingTimeInterval(Double(index)), operation: .writeSummary,
                        path: "/rehearsal/fixture/segment-\(index % 17).bin", logicalDelta: 4_096, allocatedDelta: 4_096,
                        consumerCategory: "developer-cache", confidence: .inferred, isAnomaly: false)
                }
                try await store.insert(events)
            }
            if command == "backup" {
                guard let destination else { fail("backup needs --destination", code: 64) }
                try await store.backup(to: destination)
            }
            let diagnostics = try await store.diagnostics()
            let current = try await store.currentFiles()
            await store.close()
            let report: [String: Any] = [
                "ok": true, "command": command, "database": database.path,
                "schemaVersion": diagnostics.schemaVersion, "integrity": diagnostics.integrity, "journalMode": diagnostics.journalMode,
                "eventCount": diagnostics.eventCount, "snapshotCount": diagnostics.snapshotCount, "currentFileCount": current.count,
                "storageBytes": diagnostics.storageBytes, "retentionRunCount": diagnostics.retentionRunCount,
            ]
            emit(report); exit(0)
        } catch is Interrupted {
            emit(["ok": false, "command": command, "database": database.path, "interruptedAt": stage ?? ""]); exit(4)
        } catch {
            let message = String(describing: error)
            let refused = message.contains("newer than this application")
            emit(["ok": false, "command": command, "database": database.path, "error": message, "refusedNewerSchema": refused]); exit(refused ? 3 : 2)
        }
    }

    static func emit(_ report: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    static func fail(_ message: String, code: Int32) -> Never {
        emit(["ok": false, "error": message]); exit(code)
    }
}
