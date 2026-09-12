import DiskStewardCore
import Foundation

struct MCPResponseSanitizer: Sendable {
    private let forbiddenKeys: Set<String> = [
        "file_contents", "filecontents", "environment", "environment_variables",
        "token", "secret", "credential", "password", "challenge", "challenge_digest",
    ]

    func sanitize(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(object):
            return .object(object.reduce(into: [:]) { result, entry in
                let normalized = entry.key.lowercased().replacingOccurrences(of: "-", with: "_")
                let secretLike = forbiddenKeys.contains(normalized)
                    || normalized.hasSuffix("_token")
                    || normalized.hasSuffix("_secret")
                    || normalized.hasSuffix("_password")
                    || normalized.hasSuffix("_credential")
                guard !secretLike else { return }
                result[entry.key] = sanitize(entry.value)
            })
        case let .array(values):
            return .array(values.map(sanitize))
        case let .string(string):
            return .string(redact(string))
        default:
            return value
        }
    }

    private func redact(_ string: String) -> String {
        let pattern = #"(?i)(--(?:token|api-key|password)(?:=|\s+))[^\s]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return expression.stringByReplacingMatches(in: string, range: range, withTemplate: "$1<redacted>")
    }
}
