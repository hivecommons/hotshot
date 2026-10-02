import AppKit
import HotshotCore

/// Owns the screenshot-folder file-system watch, its debounce timer, and the
/// set of already-seen files, extracted from the app delegate.
public final class ScreenshotWatcher {
    public typealias Diagnostic = (
        _ event: String, _ severity: DiagnosticSeverity, _ path: String?, _ count: Int?
    ) -> Void

    private let screenshotDirectory: () -> String
    private let verboseDiagnostics: () -> Bool
    private let diagnostic: Diagnostic
    private var source: DispatchSourceFileSystemObject?
    private var debounceTimer: DispatchSourceTimer?
    private var lastSeen: Set<String> = []

    /// Called with the full path of a new, injectable screenshot.
    public var onNewScreenshot: ((_ path: String) -> Void)?

    public init(
        screenshotDirectory: @escaping () -> String,
        verboseDiagnostics: @escaping () -> Bool,
        diagnostic: @escaping Diagnostic
    ) {
        self.screenshotDirectory = screenshotDirectory
        self.verboseDiagnostics = verboseDiagnostics
        self.diagnostic = diagnostic
    }

    deinit { stop() }

    private var directory: String {
        (screenshotDirectory() as NSString).expandingTildeInPath
    }

    public func start() {
        stop()

        let dir = directory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        lastSeen = snapshotScreenshotFiles(in: dir)

        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            diagnostic("watcher.open_failed", .error, dir, nil)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .link, .attrib],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.handleDirectoryChange()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.source = source
        diagnostic("watcher.started", .info, dir, nil)
    }

    public func stop() {
        debounceTimer?.cancel()
        debounceTimer = nil
        source?.cancel()
        source = nil
        NSLog("Hotshot: stopped watching for screenshots")
    }

    func handleDirectoryChange() {
        // Verbose-only: this fires on every filesystem event, so normal
        // diagnostics stay bounded to the debounced outcome logged below.
        if verboseDiagnostics() {
            diagnostic("watcher.directory_change", .info, nil, nil)
        }
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + WATCH_DEBOUNCE_SECONDS)
        timer.setEventHandler { [weak self] in
            self?.checkForNewScreenshots()
        }
        timer.resume()
        debounceTimer = timer
    }

    func checkForNewScreenshots() {
        let dir = directory
        let current = snapshotScreenshotFiles(in: dir)
        let newFiles = newScreenshotFiles(previous: lastSeen, current: current)
        lastSeen = current

        // Bounded, per-debounced-cycle: only log when there is something to
        // report, and only a count in normal diagnostics — filenames may be
        // revealing and are never included unless HOTSHOT_VERBOSE_LOGGING=1.
        guard !newFiles.isEmpty else { return }
        diagnostic("watcher.new_files", .info, nil, newFiles.count)
        if verboseDiagnostics() {
            diagnostic("watcher.new_files", .info, newFiles.sorted().joined(separator: ", "), nil)
        }

        let candidates = screenshotCandidates(for: newFiles, directory: dir) { fullPath in
            let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath)
            return attrs?[.modificationDate] as? Date
        }

        guard let path = newestInjectableScreenshot(from: candidates, directory: dir) else { return }

        diagnostic("watcher.new_screenshot", .info, path, nil)
        onNewScreenshot?(path)
    }
}
