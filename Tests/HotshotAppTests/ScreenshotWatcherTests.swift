import AppKit
import HotshotCore
import XCTest

@testable import HotshotApp

/// Covers the screenshot-folder watch shell extracted in #106. Most tests
/// drive `checkForNewScreenshots()` directly over a temp directory so the
/// snapshot/diff/candidate/newest pipeline and its bounded diagnostics are
/// exercised without waiting on a real filesystem event; the "live watch"
/// section at the end lets the real `DispatchSource` and debounce timer fire
/// so the wiring between them is covered too.
final class ScreenshotWatcherTests: XCTestCase {
    private var directory: String!
    private var events: [Event] = []
    private var verbose = false

    private struct Event {
        let event: String
        let severity: DiagnosticSeverity
        let path: String?
        let count: Int?
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeDirectory().path
        events = []
        verbose = false
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
    }

    /// Same scratch-directory convention as `HotshotCoreTests`: a per-test
    /// directory under `.build`, removed on teardown.
    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build")
            .appendingPathComponent("HotshotAppTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Helpers

    private func makeWatcher(directoryOverride: String? = nil) -> ScreenshotWatcher {
        let dir = directoryOverride ?? directory!
        return ScreenshotWatcher(
            screenshotDirectory: { dir },
            verboseDiagnostics: { [weak self] in self?.verbose ?? false },
            diagnostic: { [weak self] event, severity, path, count in
                self?.events.append(
                    Event(event: event, severity: severity, path: path, count: count))
            })
    }

    @discardableResult
    private func writeFile(_ name: String, ageSeconds: TimeInterval = 0) throws -> String {
        let path = (directory as NSString).appendingPathComponent(name)
        try Data([0x00]).write(to: URL(fileURLWithPath: path))
        if ageSeconds > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: path)
        }
        return path
    }

    private func setQuarantine(on path: String) throws {
        let value = Array("0083;00000000;Safari;".utf8)
        let rc = value.withUnsafeBufferPointer { buf in
            setxattr(path, QUARANTINE_XATTR, buf.baseAddress, buf.count, 0, 0)
        }
        if rc != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    // MARK: - checkForNewScreenshots

    func testFiresOnceWithTheNewestFreshScreenshot() throws {
        try writeFile("older.png", ageSeconds: 2)
        let newest = try writeFile("newest.png")
        var injected: [String] = []
        let watcher = makeWatcher()
        watcher.onNewScreenshot = { injected.append($0) }

        watcher.checkForNewScreenshots()

        XCTAssertEqual(injected, [newest])
        XCTAssertEqual(events.last?.event, "watcher.new_screenshot")
    }

    func testIgnoresHiddenStaleNonImageAndOwnOutputFiles() throws {
        try writeFile(".Screenshot in progress.png")
        try writeFile("notes.txt")
        try writeFile("stale.png", ageSeconds: WATCH_FILE_AGE_MAX_SECONDS + 60)
        try writeFile("hotshot-20240101-120000.png")
        var injected: [String] = []
        let watcher = makeWatcher()
        watcher.onNewScreenshot = { injected.append($0) }

        watcher.checkForNewScreenshots()

        XCTAssertEqual(injected, [], "nothing here is an injectable new screenshot")
        XCTAssertNil(events.first { $0.event == "watcher.new_screenshot" })
        XCTAssertNil(events.first { $0.event == "watcher.quarantined_skipped" })
    }

    func testRefusesQuarantinedDownloadsAndReportsOnlyACount() throws {
        let download = try writeFile("cute.png")
        try setQuarantine(on: download)
        var injected: [String] = []
        let watcher = makeWatcher()
        watcher.onNewScreenshot = { injected.append($0) }

        watcher.checkForNewScreenshots()

        XCTAssertEqual(injected, [], "a downloaded file is not a screenshot the user took")
        XCTAssertNil(events.first { $0.event == "watcher.new_screenshot" })
        let skipped = events.filter { $0.event == "watcher.quarantined_skipped" }
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped.first?.severity, .warn)
        XCTAssertEqual(skipped.first?.count, 1)
        XCTAssertNil(skipped.first?.path, "filenames must stay out of normal diagnostics")
    }

    func testQuarantinedDownloadDoesNotShadowARealCapture() throws {
        let shot = try writeFile("Screenshot 2026-10-06 at 09.41.12.png", ageSeconds: 2)
        let download = try writeFile("cute.png")
        try setQuarantine(on: download)
        var injected: [String] = []
        let watcher = makeWatcher()
        watcher.onNewScreenshot = { injected.append($0) }

        watcher.checkForNewScreenshots()

        XCTAssertEqual(injected, [shot])
    }

    func testVerboseDiagnosticsNameTheQuarantinedFiles() throws {
        verbose = true
        try setQuarantine(on: try writeFile("b.png"))
        try setQuarantine(on: try writeFile("a.png"))

        makeWatcher().checkForNewScreenshots()

        let named = events.filter { $0.event == "watcher.quarantined_skipped" && $0.path != nil }
        XCTAssertEqual(named.first?.path, "a.png, b.png")
    }

    func testReportsOnlyACountInNormalDiagnostics() throws {
        try writeFile("one.png")
        try writeFile("two.png")

        makeWatcher().checkForNewScreenshots()

        let newFiles = events.filter { $0.event == "watcher.new_files" }
        XCTAssertEqual(newFiles.count, 1)
        XCTAssertEqual(newFiles.first?.count, 2)
        XCTAssertNil(newFiles.first?.path, "filenames must stay out of normal diagnostics")
    }

    func testVerboseDiagnosticsAddTheFileNames() throws {
        verbose = true
        try writeFile("one.png")
        try writeFile("two.png")

        makeWatcher().checkForNewScreenshots()

        let named = events.filter { $0.event == "watcher.new_files" && $0.path != nil }
        XCTAssertEqual(named.first?.path, "one.png, two.png")
    }

    func testSecondCheckWithoutChangesStaysQuiet() throws {
        try writeFile("shot.png")
        var injected: [String] = []
        let watcher = makeWatcher()
        watcher.onNewScreenshot = { injected.append($0) }

        watcher.checkForNewScreenshots()
        events = []
        watcher.checkForNewScreenshots()

        XCTAssertEqual(injected.count, 1)
        XCTAssertEqual(events.count, 0)
    }

    func testOnlyFilesAppearingAfterStartAreNew() throws {
        try writeFile("pre-existing.png")
        var injected: [String] = []
        let watcher = makeWatcher()
        watcher.onNewScreenshot = { injected.append($0) }

        watcher.start()
        let fresh = try writeFile("fresh.png")
        watcher.checkForNewScreenshots()
        watcher.stop()

        XCTAssertEqual(injected, [fresh])
        XCTAssertNotNil(events.first { $0.event == "watcher.started" })
    }

    func testStartReportsOpenFailureForAnUnopenableDirectory() {
        let watcher = makeWatcher(directoryOverride: "/dev/null/hotshot-not-a-directory")

        watcher.start()
        defer { watcher.stop() }

        let failure = events.first { $0.event == "watcher.open_failed" }
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.severity, .error)
        XCTAssertNil(events.first { $0.event == "watcher.started" })
    }

    func testDirectoryChangeIsLoggedOnlyWhenVerbose() throws {
        let watcher = makeWatcher()

        watcher.handleDirectoryChange()
        XCTAssertNil(events.first { $0.event == "watcher.directory_change" })

        verbose = true
        watcher.handleDirectoryChange()
        watcher.stop()

        XCTAssertNotNil(events.first { $0.event == "watcher.directory_change" })
    }

    // MARK: - Live watch (real DispatchSource + debounce timer)

    /// A file written into the watched directory must reach `onNewScreenshot`
    /// through the real kqueue source and the debounce timer — the only path
    /// the app itself uses. Guards the event mask, `resume()`, and the
    /// timer-to-check hand-off, none of which the direct-call tests touch.
    func testLiveWatchInjectsAFileWrittenAfterStart() throws {
        let watcher = makeWatcher()
        let fired = expectation(description: "debounced check injects the new screenshot")
        var injected: [String] = []
        watcher.onNewScreenshot = {
            injected.append($0)
            fired.fulfill()
        }

        watcher.start()
        defer { watcher.stop() }
        let fresh = try writeFile("Screenshot 2026-10-07 at 09.45.00.png")
        try writeFile("notes.txt")

        wait(for: [fired], timeout: WATCH_DEBOUNCE_SECONDS + 5)

        XCTAssertEqual(injected, [fresh])
        let newFiles = events.filter { $0.event == "watcher.new_files" }
        XCTAssertEqual(newFiles.count, 1, "both writes land in one debounced check")
        XCTAssertEqual(newFiles.first?.count, 1, "notes.txt is not a screenshot")
    }

    /// Every directory change inside the debounce window must cancel and
    /// re-arm the timer, so a burst of events yields exactly one check (and
    /// exactly one injection — `assertForOverFulfill` catches a second).
    func testRepeatedDirectoryChangesCollapseIntoOneDebouncedCheck() throws {
        let fresh = try writeFile("shot.png")
        let watcher = makeWatcher()
        let fired = expectation(description: "exactly one debounced check")
        var injected: [String] = []
        watcher.onNewScreenshot = {
            injected.append($0)
            fired.fulfill()
        }

        watcher.handleDirectoryChange()
        watcher.handleDirectoryChange()
        watcher.handleDirectoryChange()

        wait(for: [fired], timeout: WATCH_DEBOUNCE_SECONDS + 5)
        watcher.stop()

        XCTAssertEqual(injected, [fresh])
        XCTAssertEqual(events.filter { $0.event == "watcher.new_files" }.count, 1)
    }

    /// `stop()` during the debounce window must cancel the pending check so
    /// a watcher that was turned off never injects late.
    func testStopCancelsAPendingDebouncedCheck() throws {
        try writeFile("shot.png")
        let watcher = makeWatcher()
        let notFired = expectation(description: "no check after stop")
        notFired.isInverted = true
        watcher.onNewScreenshot = { _ in notFired.fulfill() }

        watcher.handleDirectoryChange()
        watcher.stop()

        wait(for: [notFired], timeout: WATCH_DEBOUNCE_SECONDS + 0.5)

        XCTAssertNil(events.first { $0.event == "watcher.new_files" })
    }
}
