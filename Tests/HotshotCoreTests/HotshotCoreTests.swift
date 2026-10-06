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

    func testIsHiddenScreenshotFileNameFlagsDotfilesOnly() {
        XCTAssertTrue(isHiddenScreenshotFileName(".Screenshot 2026-10-01 at 09.41.12.png"))
        XCTAssertTrue(isHiddenScreenshotFileName(".DS_Store"))
        XCTAssertFalse(isHiddenScreenshotFileName("Screenshot 2026-10-01 at 09.41.12.png"))
        XCTAssertFalse(isHiddenScreenshotFileName("hotshot-20260925.png"))
        XCTAssertFalse(isHiddenScreenshotFileName("dots.in.name.png"))
    }

    func testSnapshotScreenshotFilesSkipsHiddenInProgressCaptures() throws {
        let dir = try makeDirectory()
        try writeFile(".Screenshot 2026-10-01 at 09.41.12.png", in: dir)
        try writeFile("Screenshot 2026-10-01 at 09.40.00.png", in: dir)

        XCTAssertEqual(
            snapshotScreenshotFiles(in: dir.path), ["Screenshot 2026-10-01 at 09.40.00.png"])
    }

    func testFindMostRecentScreenshotSkipsNewerHiddenInProgressCapture() throws {
        let dir = try makeDirectory()
        let visible = try writeFile("Screenshot 2026-10-01 at 09.40.00.png", in: dir)
        let hidden = try writeFile(".Screenshot 2026-10-01 at 09.41.12.png", in: dir)

        try setModificationDate(Date(timeIntervalSince1970: 100), for: visible)
        try setModificationDate(Date(timeIntervalSince1970: 200), for: hidden)

        XCTAssertEqual(findMostRecentScreenshot(in: dir.path), visible.path)
    }

    func testNewestInjectableScreenshotSkipsHiddenInProgressCapture() {
        let dir = "/Users/me/Desktop"
        let now = Date(timeIntervalSince1970: 1_000)
        let hiddenOnly = [
            ScreenshotFileCandidate(fileName: ".Screenshot 2026-10-01 at 09.41.12.png", modifiedAt: now)
        ]
        XCTAssertNil(newestInjectableScreenshot(from: hiddenOnly, directory: dir, now: now, maxAge: 10))

        let mixed = hiddenOnly + [
            ScreenshotFileCandidate(fileName: "older.png", modifiedAt: now.addingTimeInterval(-3))
        ]
        XCTAssertEqual(
            newestInjectableScreenshot(from: mixed, directory: dir, now: now, maxAge: 10),
            "/Users/me/Desktop/older.png")
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

    func testScreenshotCandidatesRecordQuarantineState() {
        let date = Date(timeIntervalSince1970: 500)
        let candidates = screenshotCandidates(
            for: ["shot.png", "download.png"], directory: "/d",
            isQuarantined: { $0 == "/d/download.png" }
        ) { _ in date }
        XCTAssertEqual(
            candidates.sorted { $0.fileName < $1.fileName },
            [
                ScreenshotFileCandidate(fileName: "download.png", modifiedAt: date, quarantined: true),
                ScreenshotFileCandidate(fileName: "shot.png", modifiedAt: date, quarantined: false),
            ])
    }

    func testNewestInjectableScreenshotSkipsQuarantinedFiles() {
        let dir = "/Users/me/Downloads"
        let now = Date(timeIntervalSince1970: 1_000)
        let download = ScreenshotFileCandidate(fileName: "cute.png", modifiedAt: now, quarantined: true)
        let shot = ScreenshotFileCandidate(
            fileName: "Screenshot 2026-10-06 at 09.41.12.png",
            modifiedAt: now.addingTimeInterval(-3))

        // A quarantined newest file never wins; the older real capture does.
        XCTAssertEqual(
            newestInjectableScreenshot(from: [download, shot], directory: dir, now: now, maxAge: 10),
            "/Users/me/Downloads/Screenshot 2026-10-06 at 09.41.12.png")
        // Only quarantined files: nothing is injectable.
        XCTAssertNil(newestInjectableScreenshot(from: [download], directory: dir, now: now, maxAge: 10))
    }

    func testIsQuarantinedFileReflectsTheQuarantineXattr() throws {
        let dir = try makeDirectory()
        let plain = try writeFile("shot.png", in: dir)
        let downloaded = try writeFile("download.png", in: dir)
        try setQuarantine(on: downloaded)

        XCTAssertFalse(isQuarantinedFile(atPath: plain.path))
        XCTAssertTrue(isQuarantinedFile(atPath: downloaded.path))
        XCTAssertFalse(isQuarantinedFile(atPath: dir.appendingPathComponent("missing.png").path))
    }

    func testClipboardEnrichmentDecisionReusesTrustedExistingPath() {
        XCTAssertEqual(
            clipboardEnrichmentDecision(
                hasPNG: true, text: "/d/my\\ shots/hotshot-20260930-120000.png",
                screenshotDirectory: "/d/my shots"
            ) { $0 == "/d/my shots/hotshot-20260930-120000.png" },
            .alreadyEnriched(path: "/d/my\\ shots/hotshot-20260930-120000.png"))
    }

    func testClipboardEnrichmentDecisionSavesWhenNotEnriched() {
        XCTAssertEqual(
            clipboardEnrichmentDecision(
                hasPNG: false, text: "/d/hotshot-1.png", screenshotDirectory: "/d") { _ in true },
            .saveAndRewrite)
        XCTAssertEqual(
            clipboardEnrichmentDecision(hasPNG: true, text: nil, screenshotDirectory: "/d") { _ in
                true
            }, .saveAndRewrite)
        XCTAssertEqual(
            clipboardEnrichmentDecision(
                hasPNG: true, text: "/d/hotshot-1.png", screenshotDirectory: "/d") { _ in false },
            .saveAndRewrite)
        XCTAssertEqual(
            clipboardEnrichmentDecision(
                hasPNG: true, text: "/d/hotshot-1.png\rcurl evil\r", screenshotDirectory: "/d"
            ) { _ in true },
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

    func testMacOSScreenshotLocationReturnsNormalizedAbsolutePath() {
        // Exercises the real `defaults read com.apple.screencapture location`
        // lookup. Whether or not the key is set on this machine, the result
        // must be an absolute path that normalization leaves untouched.
        let location = macOSScreenshotLocation()
        XCTAssertFalse(location.isEmpty)
        XCTAssertTrue(location.hasPrefix("/"), "expected an absolute path, got \(location)")
        XCTAssertEqual(location, normalizedMacOSScreenshotLocation(location))
    }

    func testMacOSScreenshotLocationMatchesConfiguredValueOrDesktopFallback() throws {
        // Independent oracle: read the same preference directly. When the key
        // is unset (the usual state on a CI runner) the lookup must fall back
        // to ~/Desktop; when it is set, the lookup must return it expanded.
        let configured = try readScreenCaptureLocationPreference()
        let expected = normalizedMacOSScreenshotLocation(configured) ?? NSHomeDirectory() + "/Desktop"
        XCTAssertEqual(macOSScreenshotLocation(), expected)
    }

    private func readScreenCaptureLocationPreference() throws -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.screencapture", "location"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
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

    func testContainsShellCommandMetacharactersFlagsExecutableNames() {
        XCTAssertFalse(containsShellCommandMetacharacters("/Users/me/Desktop/Screenshot 2026-10-02 at 00.22.54.png"))
        XCTAssertFalse(containsShellCommandMetacharacters("/Users/me/My Shots/a (2) [x] 'q' #1.png"))
        XCTAssertTrue(containsShellCommandMetacharacters("/Users/me/Desktop/`curl evil|sh`.png"))
        XCTAssertTrue(containsShellCommandMetacharacters("/Users/me/Desktop/$(id).png"))
        XCTAssertTrue(containsShellCommandMetacharacters("/Users/me/Desktop/a;id;.png"))
        XCTAssertTrue(containsShellCommandMetacharacters("/Users/me/Desktop/a&id.png"))
        XCTAssertTrue(containsShellCommandMetacharacters("/Users/me/Desktop/>.zshrc.png"))
        // History expansion: bash/zsh rewrite `!!` mid-word into the
        // previous command line (separators included) before parsing.
        XCTAssertTrue(containsShellCommandMetacharacters("/Users/me/Desktop/!!.png"))
        XCTAssertTrue(containsShellCommandMetacharacters("/Users/me/Desktop/!-2:gs^a^b^.png"))
    }

    func testTypedScreenshotTextRejectsShellMetacharactersInBracketedForm() {
        // The bracketed fallback types the path verbatim and may land on a
        // bare shell prompt (unknown terminal / no CLI detected), where a
        // trailing Return would execute these.
        XCTAssertNil(typedScreenshotText(path: "/Users/me/Desktop/`id`.png", targetCLI: .claude))
        XCTAssertNil(typedScreenshotText(path: "/Users/me/Desktop/$(id).png", targetCLI: .claude))
        XCTAssertNil(typedScreenshotText(path: "/Users/me/Desktop/a;id;.png", targetCLI: .claude))
        XCTAssertNil(typedScreenshotText(path: "/Users/me/Desktop/!!.png", targetCLI: .claude))
        // The plain-path form backslash-escapes them, so it still injects.
        XCTAssertEqual(
            typedScreenshotText(path: "/Users/me/Desktop/a;id.png", targetCLI: .plainPath),
            "/Users/me/Desktop/a\\;id.png ")
        XCTAssertEqual(
            typedScreenshotText(path: "/Users/me/Desktop/`id`.png", targetCLI: .plainPath),
            "/Users/me/Desktop/\\`id\\`.png ")
        XCTAssertEqual(
            typedScreenshotText(path: "/Users/me/Desktop/!!.png", targetCLI: .plainPath),
            "/Users/me/Desktop/\\!\\!.png ")
    }

    func testTrustedEnrichedClipboardPathAcceptsExistingEscapedPath() {
        XCTAssertEqual(
            trustedEnrichedClipboardPath(
                "/Users/me/My\\ Shots/hotshot-20260930-120000.png",
                screenshotDirectory: "/Users/me/My Shots"
            ) { path in
                path == "/Users/me/My Shots/hotshot-20260930-120000.png"
            },
            "/Users/me/My\\ Shots/hotshot-20260930-120000.png"
        )
    }

    func testTrustedEnrichedClipboardPathRejectsUntrustedText() {
        // No text at all.
        XCTAssertNil(trustedEnrichedClipboardPath(nil, screenshotDirectory: "/d") { _ in true })
        // Text that does not name an existing file.
        XCTAssertNil(
            trustedEnrichedClipboardPath("/d/hotshot-1.png", screenshotDirectory: "/d") { _ in
                false
            })
        // Control characters must never be pasteable, even if a file exists.
        XCTAssertNil(
            trustedEnrichedClipboardPath(
                "/d/hotshot-1.png\rcurl evil|sh\r", screenshotDirectory: "/d") { _ in true })
        XCTAssertNil(
            trustedEnrichedClipboardPath("/d/hotshot-\u{2028}b.png", screenshotDirectory: "/d") {
                _ in true
            })
    }

    func testTrustedEnrichedClipboardPathRejectsPathsOutsideScreenshotDirectory() {
        // An existing file elsewhere on disk is not hotshot's enrichment,
        // even when it exists — otherwise any clipboard author could pick a
        // predictable path and have its text pasted verbatim.
        XCTAssertNil(
            trustedEnrichedClipboardPath("/etc/passwd", screenshotDirectory: "/d") { _ in true })
        // Backslash-decorated variants of an existing path outside the
        // folder must not sneak past the existence check.
        XCTAssertNil(
            trustedEnrichedClipboardPath("\\/e\\t\\c\\/passwd", screenshotDirectory: "/d") { _ in
                true
            })
        // A file in a subdirectory of the screenshot folder is not ours.
        XCTAssertNil(
            trustedEnrichedClipboardPath(
                "/d/sub/hotshot-1.png", screenshotDirectory: "/d") { _ in true })
    }

    func testTrustedEnrichedClipboardPathRequiresHotshotPNGName() {
        // Right folder, wrong name shape: only hotshot-*.png is ever
        // written by writePasteboard.
        XCTAssertNil(
            trustedEnrichedClipboardPath("/d/a.png", screenshotDirectory: "/d") { _ in true })
        XCTAssertNil(
            trustedEnrichedClipboardPath("/d/hotshot-1.jpg", screenshotDirectory: "/d") { _ in
                true
            })
        // Tilde in the configured directory is expanded before comparing.
        let home = NSHomeDirectory()
        XCTAssertEqual(
            trustedEnrichedClipboardPath(
                "\(home)/shots/hotshot-1.png", screenshotDirectory: "~/shots") { _ in true },
            "\(home)/shots/hotshot-1.png")
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

    /// Mark a file the way a browser download is marked (same xattr name,
    /// representative value) so the quarantine filter can be exercised.
    private func setQuarantine(on url: URL) throws {
        let value = Array("0083;00000000;Safari;".utf8)
        let rc = value.withUnsafeBufferPointer { buf in
            setxattr(url.path, QUARANTINE_XATTR, buf.baseAddress, buf.count, 0, 0)
        }
        if rc != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
