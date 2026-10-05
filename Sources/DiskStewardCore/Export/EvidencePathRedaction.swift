import Foundation

/// The one filter every exported or answered path passes through: credential
/// shaped text becomes `[REDACTED]`. A token starts at a name boundary, so
/// "sk-" inside an ordinary name such as ".disk-steward-gate-659" is kept.
public enum EvidencePathRedaction {
    static let pattern = #"(?i)((?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{8,}|(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{8,}|(?<![A-Za-z0-9])AKIA[A-Z0-9]{16}|(?:token|password|secret|api[_-]?key)=[^/\s]+)"#

    public static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
    }
}
