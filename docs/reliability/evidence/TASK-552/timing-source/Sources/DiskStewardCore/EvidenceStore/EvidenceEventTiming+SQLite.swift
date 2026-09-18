import CSQLite
import Foundation

extension EvidenceEventTiming {
    /// All readers use the same three columns from event_evidence. That view
    /// only admits versioned, measured timing; it never backfills legacy dates.
    static func read(_ statement: OpaquePointer, firstColumn: Int32 = 10) throws -> Self? {
        let indexes = [firstColumn, firstColumn + 1, firstColumn + 2]
        let values = indexes.map { index -> Double? in
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
        }
        if values.allSatisfy({ $0 == nil }) { return nil }
        guard let end = values[1], let detected = values[2],
              end.isFinite, detected.isFinite, end <= detected,
              values[0].map({ $0.isFinite && $0 <= end }) ?? true else {
            throw EvidenceStoreError.invalidEvent("Stored occurrence timing is invalid")
        }
        return Self(occurredStart: values[0].map(Date.init(timeIntervalSince1970:)),
                    occurredEnd: Date(timeIntervalSince1970: end),
                    detectedAt: Date(timeIntervalSince1970: detected))
    }
}
