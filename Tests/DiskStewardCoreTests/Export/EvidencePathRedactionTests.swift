@testable import DiskStewardCore
import XCTest

/// FIND-R4-PATH-REDACTION-FALSE-POSITIVE: credential-shaped text is redacted
/// where a token can start, and ordinary names that merely contain "sk-" are
/// kept. One filter serves the MCP answers and the evidence bundle.
final class EvidencePathRedactionTests: XCTestCase {
    func testOrdinaryNamesSurvive() {
        for name in [".disk-steward-gate-659", "/Users/me/localGit/disk_steward", "task-skeleton", "risk-assessment-2026", "flask-app"] {
            XCTAssertEqual(EvidencePathRedaction.redact(name), name)
        }
    }

    func testTokensAtANameBoundaryAreRedacted() {
        XCTAssertEqual(EvidencePathRedaction.redact("/tmp/sk-proj-abcdefgh12/cache"), "/tmp/[REDACTED]/cache")
        XCTAssertEqual(EvidencePathRedaction.redact("sk-abcdefgh123456"), "[REDACTED]")
        XCTAssertEqual(EvidencePathRedaction.redact("/x/ghp_abcdefgh1234"), "/x/[REDACTED]")
        XCTAssertEqual(EvidencePathRedaction.redact("/x/AKIAABCDEFGHIJKLMNOP"), "/x/[REDACTED]")
        XCTAssertEqual(EvidencePathRedaction.redact("/x/key=sk-abcdefgh123/y"), "/x/key=[REDACTED]/y")
    }

    /// The bundle exporter's copy excluded the letter "s" instead of
    /// whitespace, so a value starting with "s" was never redacted.
    func testAssignedSecretsAreRedactedWhateverTheyStartWith() {
        XCTAssertEqual(EvidencePathRedaction.redact("/x/password=s3cret/y"), "/x/[REDACTED]/y")
        XCTAssertEqual(EvidencePathRedaction.redact("/x/token=visible/y"), "/x/[REDACTED]/y")
        XCTAssertEqual(EvidencePathRedaction.redact("/x/api_key=abc def"), "/x/[REDACTED] def", "a value stops at whitespace")
    }
}
