import AppKit
import HotshotCore
import XCTest

@testable import HotshotApp

/// Covers the injection shell extracted in #106. AppleScript never actually
/// runs: a recording `ScriptRunner` stands in for `NSAppleScript` and a fake
/// `ttyCommands` stands in for `ps`, so the suite stays hermetic on a CI
/// runner with no Automation permission and no terminal running while still
/// exercising every injection, Ctrl-V, focus and notification path.
final class TerminalInjectorTests: XCTestCase {
    private var events: [Event] = []
    private var loadedPaths: [String] = []
    private var scripts: [String] = []
    private var ttyLookups: [String] = []

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
        scripts = []
        ttyLookups = []
    }

    /// Builds an injector whose AppleScript and `ps` side effects are
    /// recorded instead of executed. `outcome` is consulted per script, so a
    /// test can answer the tty query and the injection script differently.
    private func makeInjector(
        autoReturn: Bool = false,
        autoFocus: Bool = false,
        notificationsEnabled: Bool = false,
        verboseDiagnostics: Bool = false,
        outcome: @escaping (String) -> ScriptOutcome = { _ in .success(nil) },
        ttyCommands: ((String) -> [String])? = nil
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
            verboseDiagnostics: { verboseDiagnostics },
            scriptRunner: { [weak self] (source: String) -> ScriptOutcome in
                self?.scripts.append(source)
                return outcome(source)
            },
            ttyCommands: ttyCommands.map { lookup -> (String) -> [String] in
                { [weak self] (tty: String) -> [String] in
                    self?.ttyLookups.append(tty)
                    return lookup(tty)
                }
            })
    }

    private func makeRealInjector() -> TerminalInjector {
        TerminalInjector(
            diagnostic: { _, _, _, _, _ in },
            loadPasteboard: { _ in },
            autoReturn: { false },
            autoFocus: { false },
            notificationsEnabled: { false },
            verboseDiagnostics: { false })
    }

    private var eventNames: [String] { events.map { $0.event } }

    private let iterm2 = "com.googlecode.iterm2"
    private let terminal = "com.apple.Terminal"
    private let screenshot = "/Users/me/Desktop/shot.png"

    /// Answers the tty query with `tty` and every other script with `rest`.
    private func ttyThen(_ tty: String?, rest: ScriptOutcome = .success(nil)) -> (String) -> ScriptOutcome {
        { source in source.contains("get tty of") ? .success(tty) : rest }
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

    // MARK: - injectPath: iTerm2 route

    func testInjectPathIntoITerm2WritesBracketedTextForClaude() {
        let injector = makeInjector(
            outcome: ttyThen("/dev/ttys003"),
            ttyCommands: { _ in ["-zsh", "claude"] })

        XCTAssertTrue(injector.injectPath(screenshot, terminalBundleID: iterm2))

        XCTAssertEqual(ttyLookups, ["ttys003"], "the tty basename is what ps is asked about")
        XCTAssertEqual(loadedPaths, [screenshot])
        XCTAssertEqual(
            scripts,
            [
                ttyScript(forBundleID: iterm2)!,
                iterm2InjectionScript(
                    text: "[\(screenshot)] ", autoReturn: false, autoFocus: false),
            ])
        let injected = events.first { $0.event == "injection.iterm2" }
        XCTAssertEqual(injected?.severity, .info)
        XCTAssertEqual(injected?.path, "[\(screenshot)] ")
        XCTAssertFalse(eventNames.contains("injection.iterm2.script"), "script is logged only when verbose")
    }

    func testInjectPathIntoITerm2TypesShellEscapedPathForCopilot() {
        let spaced = "/Users/me/Desktop/my shot.png"
        let injector = makeInjector(
            autoReturn: true, autoFocus: true,
            outcome: ttyThen("/dev/ttys003"),
            ttyCommands: { _ in ["/usr/local/bin/copilot"] })

        XCTAssertTrue(injector.injectPath(spaced, terminalBundleID: iterm2))

        let expected = shellEscapedPath(spaced) + " "
        XCTAssertEqual(
            scripts.last, iterm2InjectionScript(text: expected, autoReturn: true, autoFocus: true))
        XCTAssertEqual(events.first { $0.event == "injection.iterm2" }?.path, expected)
    }

    func testInjectPathFallsBackToClaudeWhenTTYQueryFails() {
        var lookedUp = false
        let injector = makeInjector(
            outcome: { source in source.contains("get tty of") ? .failure("not running") : .success(nil) },
            ttyCommands: { _ in
                lookedUp = true
                return ["copilot"]
            })

        XCTAssertTrue(injector.injectPath(screenshot, terminalBundleID: iterm2))

        XCTAssertFalse(lookedUp, "no tty means no ps lookup")
        XCTAssertEqual(
            scripts.last,
            iterm2InjectionScript(text: "[\(screenshot)] ", autoReturn: false, autoFocus: false))
        XCTAssertEqual(eventNames, ["injection.iterm2"], "a failed tty query is not an AppleScript error")
    }

    func testInjectPathFallsBackToClaudeWhenTTYIsEmpty() {
        let injector = makeInjector(outcome: ttyThen(""), ttyCommands: { _ in ["copilot"] })

        XCTAssertTrue(injector.injectPath(screenshot, terminalBundleID: iterm2))

        XCTAssertEqual(ttyLookups, [])
        XCTAssertEqual(
            scripts.last,
            iterm2InjectionScript(text: "[\(screenshot)] ", autoReturn: false, autoFocus: false))
    }

    // MARK: - injectPath: generic route

    func testInjectPathIntoTerminalUsesSystemEventsKeystroke() {
        let injector = makeInjector(
            autoReturn: true,
            outcome: ttyThen("/dev/ttys001"),
            ttyCommands: { _ in ["-bash"] })

        XCTAssertTrue(injector.injectPath(screenshot, terminalBundleID: terminal))

        XCTAssertEqual(ttyLookups, ["ttys001"])
        XCTAssertEqual(
            scripts,
            [
                ttyScript(forBundleID: terminal)!,
                genericInjectionScript(
                    text: "[\(screenshot)] ", bundleID: terminal, autoReturn: true),
            ])
        XCTAssertEqual(eventNames, [], "the generic route emits no injection diagnostic")
    }

    func testInjectPathIntoUnscriptableTerminalSkipsTheTTYQuery() {
        let injector = makeInjector(ttyCommands: { _ in ["copilot"] })

        XCTAssertTrue(injector.injectPath(screenshot, terminalBundleID: "com.example.unknown"))

        XCTAssertEqual(ttyLookups, [], "no tty script exists, so ps is never consulted")
        XCTAssertEqual(
            scripts,
            [
                genericInjectionScript(
                    text: "[\(screenshot)] ", bundleID: "com.example.unknown", autoReturn: false)
            ])
    }

    // MARK: - injectPath: AppleScript failures

    func testInjectPathReportsAppleScriptErrorDetail() {
        let injector = makeInjector(outcome: ttyThen(nil, rest: .failure("-1743 not authorized")))

        XCTAssertFalse(injector.injectPath(screenshot, terminalBundleID: iterm2))

        XCTAssertEqual(loadedPaths, [screenshot], "the pasteboard is loaded before the script runs")
        let failure = events.first { $0.event == "applescript.error" }
        XCTAssertEqual(failure?.severity, .error)
        XCTAssertEqual(failure?.detail, "-1743 not authorized")
        XCTAssertNil(failure?.path)
    }

    func testInjectPathReportsUnavailableWhenScriptDoesNotCompile() {
        let injector = makeInjector(outcome: ttyThen(nil, rest: .unavailable))

        XCTAssertFalse(injector.injectPath(screenshot, terminalBundleID: terminal))

        let failure = events.first { $0.event == "applescript.unavailable" }
        XCTAssertEqual(failure?.severity, .error)
        XCTAssertNil(failure?.detail)
        XCTAssertFalse(eventNames.contains("applescript.error"))
    }

    // MARK: - injectPath: refusals

    func testRefusalNotifiesWhenNotificationsAreEnabled() {
        let injector = makeInjector(notificationsEnabled: true)

        XCTAssertFalse(
            injector.injectPath("/Users/me/Desktop/bad\u{0007}.png", terminalBundleID: iterm2))

        XCTAssertEqual(loadedPaths, [])
        XCTAssertEqual(
            scripts,
            [
                ttyScript(forBundleID: iterm2)!,
                notificationScript(
                    title: "Hotshot",
                    body: "Refused to inject a file whose name contains control characters"),
            ])
    }

    func testInjectPathRefusesShellMetacharactersInTheBracketedFallback() {
        let injector = makeInjector(notificationsEnabled: true, ttyCommands: { _ in [] })

        XCTAssertFalse(
            injector.injectPath("/Users/me/Desktop/$(touch pwned).png", terminalBundleID: "com.example.unknown"))

        XCTAssertEqual(loadedPaths, [])
        let refusal = events.first { $0.event == "injection.shell_metachars_refused" }
        XCTAssertEqual(refusal?.severity, .warn)
        XCTAssertEqual(refusal?.path, "/Users/me/Desktop/$(touch pwned).png")
        XCTAssertEqual(
            scripts,
            [
                notificationScript(
                    title: "Hotshot",
                    body: "Refused to inject a file whose name contains shell metacharacters")
            ])
    }

    func testShellMetacharactersAreAllowedWhenTheCLITakesAnEscapedPath() {
        let dollar = "/Users/me/Desktop/$shot.png"
        let injector = makeInjector(
            outcome: ttyThen("/dev/ttys003"), ttyCommands: { _ in ["aider"] })

        XCTAssertTrue(injector.injectPath(dollar, terminalBundleID: iterm2))

        XCTAssertEqual(loadedPaths, [dollar])
        XCTAssertEqual(
            scripts.last,
            iterm2InjectionScript(
                text: shellEscapedPath(dollar) + " ", autoReturn: false, autoFocus: false))
    }

    // MARK: - verbose diagnostics

    func testVerboseDiagnosticsLogTheScriptAndTheResult() {
        let injector = makeInjector(
            verboseDiagnostics: true,
            outcome: ttyThen(nil, rest: .success("done")))

        XCTAssertTrue(injector.injectPath(screenshot, terminalBundleID: iterm2))

        XCTAssertEqual(eventNames, ["injection.iterm2", "injection.iterm2.script", "applescript.result"])
        let logged = events.first { $0.event == "injection.iterm2.script" }
        XCTAssertNil(logged?.path)
        XCTAssertEqual(
            logged?.script,
            iterm2InjectionScript(text: "[\(screenshot)] ", autoReturn: false, autoFocus: false))
        XCTAssertEqual(events.first { $0.event == "applescript.result" }?.path, "done")
    }

    func testVerboseResultWithoutAStringValueIsLoggedAsNone() {
        let injector = makeInjector(verboseDiagnostics: true)

        injector.focusTerminal(bundleID: terminal)

        let result = events.first { $0.event == "applescript.result" }
        XCTAssertEqual(result?.severity, .info)
        XCTAssertEqual(result?.path, "(none)")
    }

    // MARK: - Ctrl-V, focus, notifications

    func testSendCtrlVRunsTheCtrlVScriptForTheBundle() {
        let injector = makeInjector()

        XCTAssertTrue(injector.sendCtrlV(terminalBundleID: terminal, terminalName: "Terminal"))

        XCTAssertEqual(scripts, [ctrlVScript(bundleID: terminal)])
        XCTAssertEqual(eventNames, [])
    }

    func testSendCtrlVPropagatesAppleScriptFailure() {
        let injector = makeInjector(outcome: { _ in .failure("System Events denied") })

        XCTAssertFalse(injector.sendCtrlV(terminalBundleID: terminal, terminalName: nil))

        XCTAssertEqual(events.first { $0.event == "applescript.error" }?.detail, "System Events denied")
    }

    func testFocusTerminalActivatesTheBundleByID() {
        makeInjector().focusTerminal(bundleID: "com.example.term")

        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("tell application id \"com.example.term\""))
        XCTAssertTrue(scripts[0].contains("activate"))
    }

    func testShowNotificationRunsTheNotificationScriptWhenEnabled() {
        makeInjector(notificationsEnabled: true).showNotification(title: "Hot \"shot\"", body: "a\\b")

        XCTAssertEqual(scripts, [notificationScript(title: "Hot \"shot\"", body: "a\\b")])
    }

    // MARK: - detectTargetCLI

    func testDetectTargetCLIClassifiesTheCommandsOnTheTTY() {
        let injector = makeInjector(
            outcome: ttyThen("/dev/ttys007"),
            ttyCommands: { tty in tty == "ttys007" ? ["node /opt/copilot"] : [] })

        XCTAssertEqual(injector.detectTargetCLI(terminalBundleID: iterm2), .plainPath)
        XCTAssertEqual(scripts, [ttyScript(forBundleID: iterm2)!])
        XCTAssertEqual(ttyLookups, ["ttys007"])
    }

    func testDetectTargetCLIUsesPSWhenNoTTYLookupIsInjected() {
        // The default `ttyCommands` shells out to `ps`; a tty that does not
        // exist yields no commands, so the classifier falls back to Claude.
        let injector = makeInjector(outcome: ttyThen("/dev/ttys-does-not-exist"))

        XCTAssertEqual(injector.detectTargetCLI(terminalBundleID: terminal), .claude)
        XCTAssertEqual(ttyLookups, [])
    }

    // MARK: - runAppleScriptForResult

    func testRunAppleScriptForResultReturnsNilOnFailureAndUnavailable() {
        XCTAssertNil(makeInjector(outcome: { _ in .failure("x") }).runAppleScriptForResult("x"))
        XCTAssertNil(makeInjector(outcome: { _ in .unavailable }).runAppleScriptForResult("x"))
        XCTAssertEqual(makeInjector(outcome: { _ in .success("ok") }).runAppleScriptForResult("x"), "ok")
    }

    // MARK: - default runner

    func testDefaultRunnerNeverSucceedsForSourceThatCannotCompile() {
        // Compile errors surface either from `NSAppleScript(source:)` or from
        // `executeAndReturnError`, depending on the OS. No `tell application`
        // is involved, so no Automation prompt can appear on a CI runner.
        let outcome = TerminalInjector.appleScriptRunner("this is not AppleScript ((")
        if case .success = outcome {
            XCTFail("unparseable source must not succeed: \(outcome)")
        }
        XCTAssertFalse(makeRealInjector().runAppleScript("this is not AppleScript (("))
    }
}
