import AppKit
import HotshotCore

/// Owns clipboard polling state and pasteboard I/O, extracted from HotshotApp.
final class ClipboardWatcher {
    typealias Diagnostic = (
        _ event: String, _ severity: DiagnosticSeverity, _ path: String?, _ detail: String?
    ) -> Void

    private let pasteboard: NSPasteboard
    private let screenshotDirectory: () -> String
    private let diagnostic: Diagnostic
    private var timer: Timer?
    private var lastChangeCount: Int = 0

    /// Called when a new image lands on the clipboard.
    var onImageDetected: ((_ changeCount: Int) -> Void)?

    init(
        pasteboard: NSPasteboard = .general,
        screenshotDirectory: @escaping () -> String,
        diagnostic: @escaping Diagnostic
    ) {
        self.pasteboard = pasteboard
        self.screenshotDirectory = screenshotDirectory
        self.diagnostic = diagnostic
    }

    deinit { timer?.invalidate() }

    func start() {
        stop()
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(
            withTimeInterval: CLIPBOARD_POLL_INTERVAL_SECONDS, repeats: true
        ) { [weak self] _ in
            self?.check()
        }
        NSLog("Hotshot: started watching clipboard for images")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSLog("Hotshot: stopped watching clipboard")
    }

    func check() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard hasImage() else { return }
        onImageDetected?(currentCount)
    }

    func hasImage() -> Bool {
        pasteboard.canReadItem(withDataConformingToTypes: [
            "public.png", "public.tiff", "public.jpeg",
        ])
    }

    func pngData() -> Data? {
        let pb = pasteboard
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff),
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        {
            return png
        }
        if let jpeg = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")),
            let rep = NSBitmapImageRep(data: jpeg),
            let png = rep.representation(using: .png, properties: [:])
        {
            return png
        }
        return nil
    }

    /// Write a single pasteboard item carrying the PNG image (Claude Code
    /// reads image data on Ctrl-V), a file URL (Finder-copy equivalence), and
    /// a shell-escaped plain-text POSIX path (GitHub Copilot CLI and other
    /// CLIs paste the path as text) all at once.
    func writePasteboard(pngData: Data, path: String) {
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        item.setString(shellEscapedPath(path), forType: .string)

        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        // Don't let the watcher re-trigger on our own write.
        lastChangeCount = pasteboard.changeCount
        diagnostic("pasteboard.loaded", .info, path, nil)
    }

    /// Load an on-disk screenshot onto the pasteboard (image + URL + path).
    func loadPasteboard(withFile path: String) {
        guard let data = FileManager.default.contents(atPath: path) else {
            diagnostic("pasteboard.read_failed", .warn, path, nil)
            return
        }
        let png: Data
        if (path as NSString).pathExtension.lowercased() == "png" {
            png = data
        } else if let rep = NSBitmapImageRep(data: data),
            let converted = rep.representation(using: .png, properties: [:])
        {
            png = converted
        } else {
            diagnostic("pasteboard.png_conversion_failed", .warn, path, nil)
            return
        }
        writePasteboard(pngData: png, path: path)
    }

    /// Save the clipboard image to the screenshot folder and rewrite the
    /// pasteboard with image + file URL + plain-text path representations.
    /// Returns the saved path, or nil if there was no image to save.
    @discardableResult
    func enrichWithSavedImage() -> String? {
        // Already enriched (image + control-character-free existing file
        // path) — nothing to do. Text failing the trust check is rewritten
        // below so a Ctrl-V paste never types attacker-controlled clipboard
        // text into the terminal.
        if case .alreadyEnriched(let existing) = clipboardEnrichmentDecision(
            hasPNG: pasteboard.data(forType: .png) != nil,
            text: pasteboard.string(forType: .string),
            fileExists: { FileManager.default.fileExists(atPath: $0) })
        {
            return existing
        }

        guard let png = pngData() else { return nil }

        let dir = (screenshotDirectory() as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        let path = screenshotSavePath(directory: dir)

        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            diagnostic("clipboard.save_failed", .error, path, "\(error)")
            return nil
        }

        writePasteboard(pngData: png, path: path)
        return path
    }
}
