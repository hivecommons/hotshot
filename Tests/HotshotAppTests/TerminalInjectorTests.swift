import AppKit
import HotshotCore
import XCTest

@testable import HotshotApp

/// Covers the injection shell extracted in #106. Only the branches that
/// never reach `NSAppleScript` are exercised, so the suite stays hermetic on
/// a CI runner with no Automation permission and no terminal running.
final class TerminalInjectorTests: XCTestCase {
    private var events: [Event] = []
    private var loadedPaths: [String] = []

    private struct Event {
        let event: String
        let severity: DiagnosticSeverity
        let path: String?
        let script: String?
        let detail: String?
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        events = []
        loadedPaths = []
    }

    private func makeInjector(
        autoReturn: Bool = false,
        autoFocus: Bool = false,
        notificationsEnabled: Bool = false,
        verboseDiagnostics: Bool = false
    ) -> TerminalInjector {
        TerminalInjector(
            diagnostic: { [weak self] event, severity, path, script, detail in
                self?.events.append(
                    Event(
                        event: event, severity: severity, path: path, script: script,
                        detail: detail))
            },
            loadPasteboard: { [weak self] path in self?.loadedPaths.append(path) },
            autoReturn: { autoReturn },
            autoFocus: { autoFocus },
            notificationsEnabled: { notificationsEnabled },
            verboseDiagnostics: { verboseDiagnostics })
    }

    func testInjectPathRefusesControlCharactersBeforeTouchingThePasteboard() {
        let injector = makeInjector()

        let injected = injector.injectPath(
            "/Users/me/Desktop/shot\u{000A}rm -rf.png", terminalBundleID: "com.example.unknown")

        XCTAssertFalse(injected)
        XCTAssertEqual(loadedPaths, [], "a refused path must never reach the pasteboard")
        let refusal = events.first { $0.event == "injection.control_chars_refused" }
        XCTAssertNotNil(refusal)
        XCTAssertEqual(refusal?.severity, .warn)
    }

    func testRefusalStaysSilentWhenNotificationsAreDisabled() {
        let injector = makeInjector(notificationsEnabled: false)

        _ = injector.injectPath("/Users/me/Desktop/bad\u{0007}.png", terminalBundleID: "com.example.unknown")

        XCTAssertEqual(
            events.map { $0.event }, ["injection.control_chars_refused"],
            "no AppleScript diagnostics when notifications are off")
    }

    func testDetectTargetCLIFallsBackToClaudeWithoutAScriptableTerminal() {
        // An unscriptable bundle ID has no tty script, so no AppleScript runs
        // and the historical bracketed format is used.
        XCTAssertEqual(
            makeInjector().detectTargetCLI(terminalBundleID: "com.example.unknown"), .claude)
        XCTAssertEqual(events.map { $0.event }, [])
    }

    func testCommandsOnUnknownTTYAreEmpty() {
        XCTAssertEqual(makeInjector().commands(onTTY: "ttys-does-not-exist"), [])
    }

    func testShowNotificationIsANoOpWhenDisabled() {
        makeInjector(notificationsEnabled: false).showNotification(title: "t", body: "b")
        XCTAssertEqual(events.map { $0.event }, [])
    }
}
