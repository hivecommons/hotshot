import XCTest
@testable import HotshotCore

final class HotshotCoreTests: XCTestCase {
    func testShellEscapedPathEscapesTerminalSpecials() {
        XCTAssertEqual(shellEscapedPath("/Users/me/Desktop/plain.png"), "/Users/me/Desktop/plain.png")
        XCTAssertEqual(shellEscapedPath("/Users/me/My Shots/a b.png"), "/Users/me/My\\ Shots/a\\ b.png")
        XCTAssertEqual(shellEscapedPath("/tmp/!\"#$&'()*,;<>?[]\\^`{}|.png"), "/tmp/\\!\\\"\\#\\$\\&\\'\\(\\)\\*\\,\\;\\<\\>\\?\\[\\]\\\\\\^\\`\\{\\}\\|.png")
        XCTAssertEqual(shellEscapedPath("/tmp/tab\tname.png"), "/tmp/tab\\\tname.png")
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

    func testMacOSScreenshotLocationNormalization() {
        XCTAssertNil(normalizedMacOSScreenshotLocation("\n \t"))
        XCTAssertEqual(normalizedMacOSScreenshotLocation("~/Pictures\n"), NSHomeDirectory() + "/Pictures")
        XCTAssertEqual(normalizedMacOSScreenshotLocation("/Users/example/Desktop\n"), "/Users/example/Desktop")
    }

    func testAppleScriptEscapedStringEscapesBackslashesAndQuotes() {
        XCTAssertEqual(appleScriptEscaped(#"/tmp/a\b "quoted".png"#), #"/tmp/a\\b \"quoted\".png"#)
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
