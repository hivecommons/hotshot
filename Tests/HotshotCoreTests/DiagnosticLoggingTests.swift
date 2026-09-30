import XCTest
@testable import HotshotCore

/// Covers the redaction/diagnostic-formatting policy from issue #77: normal
/// diagnostics must never contain screenshot directory paths, filenames,
/// generated AppleScript, or clipboard text, while failures stay
/// identifiable through a stable event name and severity.
final class DiagnosticLoggingTests: XCTestCase {
    func testVerboseDiagnosticsEnabledRequiresExactOptIn() {
        XCTAssertTrue(verboseDiagnosticsEnabled(environment: ["HOTSHOT_VERBOSE_LOGGING": "1"]))
        XCTAssertFalse(verboseDiagnosticsEnabled(environment: [:]))
        XCTAssertFalse(verboseDiagnosticsEnabled(environment: ["HOTSHOT_VERBOSE_LOGGING": "0"]))
        XCTAssertFalse(verboseDiagnosticsEnabled(environment: ["HOTSHOT_VERBOSE_LOGGING": "true"]))
    }

    func testRedactedHidesValueByDefault() {
        XCTAssertEqual(redacted("/Users/me/Desktop/hotshot/shot-1.png", verbose: false), "<redacted>")
    }

    func testRedactedRevealsValueWhenVerbose() {
        XCTAssertEqual(
            redacted("/Users/me/Desktop/hotshot/shot-1.png", verbose: true),
            "/Users/me/Desktop/hotshot/shot-1.png")
    }

    func testRedactedNeverEvaluatesAppleScriptOrClipboardTextInNormalMode() {
        // Redaction must work for any sensitive value, not just paths:
        // generated AppleScript and clipboard text redact the same way.
        let script = "tell application \"iTerm2\" to write text \"/Users/me/secret.png\""
        XCTAssertEqual(redacted(script, verbose: false), "<redacted>")
        XCTAssertEqual(redacted(script, verbose: true), script)
    }

    func testDiagnosticLineIncludesStableEventAndSeverityWithoutDetail() {
        XCTAssertEqual(
            diagnosticLine(event: "watcher.started"),
            "Hotshot [INFO] watcher.started")
    }

    func testDiagnosticLineAppendsRedactedDetail() {
        XCTAssertEqual(
            diagnosticLine(event: "watcher.open_failed", severity: .error, detail: "<redacted>"),
            "Hotshot [ERROR] watcher.open_failed: <redacted>")
    }

    func testDiagnosticLineOmitsEmptyDetail() {
        XCTAssertEqual(
            diagnosticLine(event: "watcher.stopped", severity: .info, detail: ""),
            "Hotshot [INFO] watcher.stopped")
    }

    func testDiagnosticLineEventNamesStayStableAcrossSeverities() {
        // Same event name, different severity: callers can filter on the
        // event slug alone regardless of whether it succeeded or failed.
        for severity in [DiagnosticSeverity.info, .warn, .error] {
            let line = diagnosticLine(event: "injection.iterm2", severity: severity)
            XCTAssertTrue(line.contains("injection.iterm2"))
            XCTAssertTrue(line.contains(severity.rawValue))
        }
    }
}
