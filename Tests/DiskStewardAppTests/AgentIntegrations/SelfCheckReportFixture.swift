@testable import DiskStewardApp
import Foundation

/// The self-check report a fixture helper "prints": the exact shape
/// `disk-witness-mcp --self-check` emits, bound to the identity of the
/// executable the command named, so verification fixtures exercise the real
/// identity check instead of a bare exit code.
enum SelfCheckReportFixture {
    static func report(for helper: URL, app: String = "connected", ageSeconds: Double? = 5, socket: String = "/tmp/ds.sock") -> String {
        let identity = PrivateIntegrationFile.executableIdentity(helper).map { "\"\($0)\"" } ?? "null"
        var evidence = "null"
        if app == "connected" {
            evidence = ageSeconds.map { "{\"observedAt\": \"2026-09-18T00:00:00Z\", \"ageSeconds\": \($0), \"persisted\": true}" }
                ?? "{\"observedAt\": null, \"ageSeconds\": null, \"persisted\": false}"
        }
        return "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n{\"schema\":\"disk-steward-self-check-v1\",\"helper\":{\"path\":\"\(helper.path)\",\"identity\":\(identity)},\"socket\":\"\(socket)\",\"app\":\"\(app)\",\"evidence\":\(evidence),\"error\":null}\n"
    }

    static func result(for command: AgentCommand, app: String = "connected", ageSeconds: Double? = 5) -> AgentCommandResult {
        .init(exitCode: app == "connected" ? 0 : 1, standardOutput: report(for: command.executableURL, app: app, ageSeconds: ageSeconds), standardError: "")
    }
}
