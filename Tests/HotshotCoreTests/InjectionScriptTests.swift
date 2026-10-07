import XCTest

@testable import HotshotCore

final class InjectionScriptTests: XCTestCase {

    // MARK: - iterm2InjectionScript

    func testITerm2ScriptAutoReturnWritesTextWithNewline() {
        let script = iterm2InjectionScript(text: "/tmp/a.png ", autoReturn: true, autoFocus: false)
        XCTAssertTrue(script.contains("write text \"/tmp/a.png \""))
        XCTAssertFalse(script.contains("newline NO"))
        XCTAssertFalse(script.contains("activate"))
        XCTAssertTrue(script.hasPrefix("tell application \"iTerm2\""))
        XCTAssertTrue(script.hasSuffix("end tell"))
    }

    func testITerm2ScriptNoAutoReturnSuppressesNewline() {
        let script = iterm2InjectionScript(text: "/tmp/a.png ", autoReturn: false, autoFocus: false)
        XCTAssertTrue(script.contains("write text \"/tmp/a.png \" newline NO"))
    }

    func testITerm2ScriptAutoFocusAppendsActivate() {
        let script = iterm2InjectionScript(text: "/tmp/a.png ", autoReturn: true, autoFocus: true)
        XCTAssertTrue(script.hasSuffix("tell application \"iTerm2\" to activate"))
    }

    func testITerm2ScriptEscapesTextSoItCannotBreakOutOfLiteral() {
        let hostile = "a\"b\\c\nd"
        let script = iterm2InjectionScript(text: hostile, autoReturn: true, autoFocus: false)
        // The interpolated argument stays a single quoted literal: quotes and
        // backslashes are escaped, and the raw newline becomes a \n escape.
        XCTAssertTrue(script.contains("write text \"a\\\"b\\\\c\\nd\""))
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertFalse(line.trimmingCharacters(in: .whitespaces) == "d\"",
                "raw newline in input must not split the AppleScript literal")
        }
    }

    // MARK: - genericInjectionScript

    func testGenericScriptShapeWithAutoReturn() {
        let script = genericInjectionScript(
            text: "[/tmp/a.png] ", bundleID: "com.apple.Terminal", autoReturn: true)
        XCTAssertTrue(script.hasPrefix("tell application id \"com.apple.Terminal\""))
        XCTAssertTrue(script.contains("delay \(REFOCUS_DELAY_SECONDS)"))
        XCTAssertTrue(script.contains("keystroke \"[/tmp/a.png] \""))
        XCTAssertTrue(script.contains("keystroke return"))
        XCTAssertTrue(script.hasSuffix("end tell"))
    }

    func testGenericScriptWithoutAutoReturnOmitsReturnKeystroke() {
        let script = genericInjectionScript(
            text: "[/tmp/a.png] ", bundleID: "com.apple.Terminal", autoReturn: false)
        XCTAssertFalse(script.contains("keystroke return"))
    }

    func testGenericScriptEscapesTextSoItCannotBreakOutOfLiteral() {
        let hostile = "x\" \nkeystroke return\n\""
        let script = genericInjectionScript(
            text: hostile, bundleID: "com.apple.Terminal", autoReturn: false)
        // Escaping must neutralize the embedded quote/newline payload: the
        // payload stays inside the typed literal instead of becoming a line.
        XCTAssertTrue(script.contains("keystroke \"x\\\" \\nkeystroke return\\n\\\"\""))
        let lines = script.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        XCTAssertFalse(lines.contains("keystroke return"),
            "escaped payload must not surface as a real `keystroke return` line")
    }

    // MARK: - ctrlVScript

    func testCtrlVScriptShape() {
        let script = ctrlVScript(bundleID: "com.googlecode.iterm2")
        XCTAssertTrue(script.hasPrefix("tell application id \"com.googlecode.iterm2\""))
        XCTAssertTrue(script.contains("delay \(REFOCUS_DELAY_SECONDS)"))
        XCTAssertTrue(script.contains("keystroke \"v\" using {control down}"))
        XCTAssertTrue(script.hasSuffix("end tell"))
    }

    // MARK: - notificationScript

    func testNotificationScriptEscapesTitleAndBody() {
        let script = notificationScript(title: "Hot\"shot", body: "line1\nline2")
        XCTAssertEqual(
            script,
            "display notification \"line1\\nline2\" with title \"Hot\\\"shot\"")
    }

    // MARK: - screenshotSavePath

    func testScreenshotSavePathNamingContract() {
        let path = screenshotSavePath(
            directory: "/tmp/shots", date: Date(timeIntervalSince1970: 0.5)) { _ in false }
        let name = (path as NSString).lastPathComponent
        XCTAssertTrue(path.hasPrefix("/tmp/shots/"))
        XCTAssertTrue(name.hasPrefix("hotshot-"))
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertNotNil(
            name.range(of: #"^hotshot-\d{8}-\d{6}-500\.png$"#, options: .regularExpression),
            "unexpected screenshot file name: \(name)")
    }

    func testScreenshotSavePathAddsSuffixWhenNameIsTaken() {
        let date = Date(timeIntervalSince1970: 0.5)
        let free = screenshotSavePath(directory: "/tmp/shots", date: date) { _ in false }
        let base = (free as NSString).deletingPathExtension
        var taken: Set<String> = [free]
        let second = screenshotSavePath(directory: "/tmp/shots", date: date) { taken.contains($0) }
        XCTAssertEqual(second, "\(base)-1.png")
        taken.insert(second)
        let third = screenshotSavePath(directory: "/tmp/shots", date: date) { taken.contains($0) }
        XCTAssertEqual(third, "\(base)-2.png")
        XCTAssertTrue((third as NSString).lastPathComponent.hasPrefix("hotshot-"))
    }

    func testScreenshotSavePathSameInstantYieldsDistinctFilesOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotshot-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)

        let first = screenshotSavePath(directory: dir.path, date: date)
        try Data("first".utf8).write(to: URL(fileURLWithPath: first), options: .withoutOverwriting)
        let second = screenshotSavePath(directory: dir.path, date: date)
        try Data("second".utf8).write(to: URL(fileURLWithPath: second), options: .withoutOverwriting)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOfFile: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOfFile: second, encoding: .utf8), "second")
    }

    func testScreenshotSavePathIsSkippedByWatcher() {
        // The hotshot- prefix is the watcher's self-reinjection guard:
        // files written by screenshotSavePath must never be re-injected.
        let now = Date()
        let path = screenshotSavePath(directory: "/tmp/shots", date: now)
        let name = (path as NSString).lastPathComponent
        let saved = ScreenshotFileCandidate(fileName: name, modifiedAt: now)
        XCTAssertNil(
            newestInjectableScreenshot(from: [saved], directory: "/tmp/shots", now: now))
        let user = ScreenshotFileCandidate(fileName: "Screenshot.png", modifiedAt: now)
        XCTAssertEqual(
            newestInjectableScreenshot(from: [saved, user], directory: "/tmp/shots", now: now),
            "/tmp/shots/Screenshot.png")
    }

    // MARK: - parsePSOutput

    func testParsePSOutputSplitsLinesAndDropsEmpties() {
        XCTAssertEqual(
            parsePSOutput("-zsh\nclaude --continue\n\n/usr/bin/ssh host\n"),
            ["-zsh", "claude --continue", "/usr/bin/ssh host"])
    }

    func testParsePSOutputEmptyAndWhitespace() {
        XCTAssertEqual(parsePSOutput(""), [])
        XCTAssertEqual(parsePSOutput("\n\n"), [])
    }

    func testParsePSOutputFeedsClassifyCommands() {
        let cli = classifyCommands(parsePSOutput("-zsh\n/opt/homebrew/bin/copilot\n"))
        XCTAssertEqual(cli, .plainPath)
    }
}
