import AppKit
import HotshotCore
import XCTest

@testable import HotshotApp

/// Covers the pasteboard I/O shell extracted in #106. Everything here is
/// hermetic: a private named `NSPasteboard` stands in for `.general` and the
/// screenshot folder is a per-test temp directory, so no test touches the
/// user's clipboard or Desktop.
final class ClipboardWatcherTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var directory: String!
    private var events: [Event] = []

    private struct Event {
        let event: String
        let severity: DiagnosticSeverity
        let path: String?
        let detail: String?
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("hotshot-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        directory = try makeDirectory().path
        events = []
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
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

    private func makeWatcher(directoryOverride: String? = nil) -> ClipboardWatcher {
        let dir = directoryOverride ?? directory!
        return ClipboardWatcher(
            pasteboard: pasteboard,
            screenshotDirectory: { dir },
            diagnostic: { [weak self] event, severity, path, detail in
                self?.events.append(
                    Event(event: event, severity: severity, path: path, detail: detail))
            })
    }

    private func makeBitmap(hasAlpha: Bool = true) throws -> NSBitmapImageRep {
        try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 4,
                pixelsHigh: 4,
                bitsPerSample: 8,
                samplesPerPixel: hasAlpha ? 4 : 3,
                hasAlpha: hasAlpha,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0))
    }

    private func imageData(_ type: NSBitmapImageRep.FileType, hasAlpha: Bool = true) throws -> Data {
        let rep = try makeBitmap(hasAlpha: hasAlpha)
        return try XCTUnwrap(rep.representation(using: type, properties: [:]))
    }

    private func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    private func setPasteboardData(_ data: Data, forType type: NSPasteboard.PasteboardType) {
        _ = pasteboard.declareTypes([type], owner: nil)
        XCTAssertTrue(pasteboard.setData(data, forType: type))
    }

    private func setPasteboardString(_ text: String) {
        _ = pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
    }

    // MARK: - pngData conversion ladder

    func testPNGDataReturnsPasteboardPNGUnchanged() throws {
        let png = try imageData(.png)
        setPasteboardData(png, forType: .png)
        XCTAssertEqual(makeWatcher().pngData(), png)
    }

    func testPNGDataConvertsTIFFToPNG() throws {
        setPasteboardData(try imageData(.tiff), forType: .tiff)
        let converted = try XCTUnwrap(makeWatcher().pngData())
        XCTAssertTrue(isPNG(converted))
    }

    func testPNGDataConvertsJPEGToPNG() throws {
        setPasteboardData(
            try imageData(.jpeg, hasAlpha: false),
            forType: NSPasteboard.PasteboardType("public.jpeg"))
        let converted = try XCTUnwrap(makeWatcher().pngData())
        XCTAssertTrue(isPNG(converted))
    }

    func testPNGDataIsNilForTextOnlyPasteboard() {
        setPasteboardString("just text")
        let watcher = makeWatcher()
        XCTAssertNil(watcher.pngData())
        XCTAssertFalse(watcher.hasImage())
    }

    // MARK: - writePasteboard

    func testWritePasteboardCarriesImageFileURLAndEscapedPathInOneItem() throws {
        let png = try imageData(.png)
        let path = (directory as NSString).appendingPathComponent("a shot.png")
        let watcher = makeWatcher()

        watcher.writePasteboard(pngData: png, path: path)

        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertEqual(
            pasteboard.string(forType: .fileURL), URL(fileURLWithPath: path).absoluteString)
        XCTAssertEqual(pasteboard.string(forType: .string), shellEscapedPath(path))
        XCTAssertTrue(watcher.hasImage())
        XCTAssertEqual(events.map { $0.event }, ["pasteboard.loaded"])
    }

    func testWritePasteboardSuppressesTheWatchersOwnChangeCount() throws {
        var detected: [Int] = []
        let watcher = makeWatcher()
        watcher.onImageDetected = { detected.append($0) }

        watcher.writePasteboard(pngData: try imageData(.png), path: (directory as NSString).appendingPathComponent("x.png"))
        watcher.check()

        XCTAssertEqual(detected, [], "the watcher must not re-fire on its own write")
    }

    func testCheckFiresOnceForAForeignImageWrite() throws {
        var detected: [Int] = []
        let watcher = makeWatcher()
        watcher.onImageDetected = { detected.append($0) }

        setPasteboardData(try imageData(.png), forType: .png)
        watcher.check()
        watcher.check()

        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected.first, pasteboard.changeCount)
    }

    func testCheckIgnoresNonImageClipboardChanges() {
        var detected: [Int] = []
        let watcher = makeWatcher()
        watcher.onImageDetected = { detected.append($0) }

        setPasteboardString("hello")
        watcher.check()

        XCTAssertEqual(detected, [])
    }

    func testStartThenStopSyncsChangeCountWithoutFiring() throws {
        var detected: [Int] = []
        setPasteboardData(try imageData(.png), forType: .png)
        let watcher = makeWatcher()
        watcher.onImageDetected = { detected.append($0) }

        watcher.start()
        watcher.check()
        watcher.stop()

        XCTAssertEqual(detected, [], "start() adopts the current change count")
    }

    // MARK: - enrichWithSavedImage

    func testEnrichWithSavedImageSavesHotshotPNGAndRewritesThePasteboard() throws {
        setPasteboardData(try imageData(.png), forType: .png)

        let path = try XCTUnwrap(makeWatcher().enrichWithSavedImage())

        let name = (path as NSString).lastPathComponent
        XCTAssertTrue(name.hasPrefix("hotshot-"))
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertEqual((path as NSString).deletingLastPathComponent, directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(pasteboard.string(forType: .string), shellEscapedPath(path))
    }

    func testEnrichWithSavedImageShortCircuitsWhenAlreadyEnriched() throws {
        setPasteboardData(try imageData(.png), forType: .png)
        let watcher = makeWatcher()
        let first = try XCTUnwrap(watcher.enrichWithSavedImage())
        let filesAfterFirst = try FileManager.default.contentsOfDirectory(atPath: directory)

        let second = watcher.enrichWithSavedImage()

        XCTAssertEqual(second, first, "an already-enriched clipboard is reused as-is")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory).count,
            filesAfterFirst.count,
            "the short-circuit must not write a second file")
    }

    func testEnrichWithSavedImageRewritesForeignClipboardText() throws {
        let item = NSPasteboardItem()
        item.setData(try imageData(.png), forType: .png)
        item.setString("/etc/passwd", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let path = try XCTUnwrap(makeWatcher().enrichWithSavedImage())

        XCTAssertNotEqual(path, "/etc/passwd")
        XCTAssertEqual(pasteboard.string(forType: .string), shellEscapedPath(path))
    }

    func testEnrichWithSavedImageReportsSaveFailureAsDomainAndCode() throws {
        // A regular file where the screenshot folder should be: the directory
        // create and the PNG write both fail.
        let blocked = (directory as NSString).appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocked, contents: Data()))
        setPasteboardData(try imageData(.png), forType: .png)

        let result = makeWatcher(directoryOverride: blocked).enrichWithSavedImage()

        XCTAssertNil(result)
        let failure = try XCTUnwrap(events.first { $0.event == "clipboard.save_failed" })
        XCTAssertEqual(failure.severity, .error)
        let detail = try XCTUnwrap(failure.detail)
        if !verboseDiagnosticsEnabled() {
            XCTAssertTrue(detail.contains("code="), "expected domain+code, got \(detail)")
            XCTAssertFalse(detail.contains(blocked), "the raw path must stay out of the detail")
        }
    }

    func testEnrichWithSavedImageReturnsNilWithoutAnImage() {
        setPasteboardString("no image here")
        XCTAssertNil(makeWatcher().enrichWithSavedImage())
    }

    // MARK: - loadPasteboard(withFile:)

    func testLoadPasteboardReportsReadFailureForAMissingFile() {
        let missing = (directory as NSString).appendingPathComponent("gone.png")
        makeWatcher().loadPasteboard(withFile: missing)
        XCTAssertEqual(events.map { $0.event }, ["pasteboard.read_failed"])
        XCTAssertEqual(events.first?.severity, .warn)
    }

    func testLoadPasteboardReportsConversionFailureForANonImageFile() throws {
        let path = (directory as NSString).appendingPathComponent("notes.txt")
        try "not an image".write(toFile: path, atomically: true, encoding: .utf8)

        makeWatcher().loadPasteboard(withFile: path)

        XCTAssertEqual(events.map { $0.event }, ["pasteboard.png_conversion_failed"])
        XCTAssertEqual(events.first?.severity, .warn)
    }

    func testLoadPasteboardWritesAnExistingPNGStraightThrough() throws {
        let png = try imageData(.png)
        let path = (directory as NSString).appendingPathComponent("shot.png")
        try png.write(to: URL(fileURLWithPath: path))

        makeWatcher().loadPasteboard(withFile: path)

        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertEqual(pasteboard.string(forType: .string), shellEscapedPath(path))
        XCTAssertEqual(events.map { $0.event }, ["pasteboard.loaded"])
    }

    func testLoadPasteboardConvertsANonPNGImageFile() throws {
        let path = (directory as NSString).appendingPathComponent("shot.tiff")
        try imageData(.tiff).write(to: URL(fileURLWithPath: path))

        makeWatcher().loadPasteboard(withFile: path)

        let written = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertTrue(isPNG(written))
        XCTAssertEqual(events.map { $0.event }, ["pasteboard.loaded"])
    }
}
