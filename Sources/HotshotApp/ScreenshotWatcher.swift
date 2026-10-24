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
    private let visibilityDate: (String) -> Date?
    private var source: DispatchSourceFileSystemObject?
    private var debounceTimer: DispatchSourceTimer?
    private var lastSeen: Set<String> = []
    /// The folder the live fd and `lastSeen` baseline are bound to; nil when
    /// not watching. `screenshotDirectory` can change underneath a running
    /// watch (e.g. the macOS location default), so the diff must not re-read it.
    private var watchedDirectory: String?

    /// Called with the full path of a new, injectable screenshot.
    public var onNewScreenshot: ((_ path: String) -> Void)?

    public init(
        screenshotDirectory: @escaping () -> String,
        verboseDiagnostics: @escaping () -> Bool,
        diagnostic: @escaping Diagnostic,
        visibilityDate: @escaping (String) -> Date? = fileVisibilityDate(atPath:)
    ) {
        self.screenshotDirectory = screenshotDirectory
        self.verboseDiagnostics = verboseDiagnostics
        self.diagnostic = diagnostic
        self.visibilityDate = visibilityDate
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
        watchedDirectory = dir
        diagnostic("watcher.started", .info, dir, nil)
    }

    /// Re-binds the watch when the folder closure now names a different
    /// folder than the one the live fd is bound to; no-op when not watching.
    /// The new folder is probed before the live watch is torn down, so a
    /// folder that cannot be opened leaves the existing watch in place
    /// (`watcher.open_failed` names the folder that was refused).
    public func reconcileDirectory() {
        guard source != nil else { return }
        let dir = directory
        guard dir != watchedDirectory else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let probe = open(dir, O_EVTONLY)
        guard probe >= 0 else {
            diagnostic(DiagnosticEvent.watcherOpenFailed.rawValue, .error, dir, nil)
            return
        }
        close(probe)
        diagnostic(DiagnosticEvent.watcherDirectoryChanged.rawValue, .info, dir, nil)
        start()
    }

    public func stop() {
        debounceTimer?.cancel()
        debounceTimer = nil
        source?.cancel()
        source = nil
        watchedDirectory = nil
        NSLog(diagnosticLine(event: DiagnosticEvent.watcherStopped.rawValue))
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
        let dir = watchedDirectory ?? directory
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

        let candidates = screenshotCandidates(
            for: newFiles, directory: dir, isQuarantined: isQuarantinedFile(atPath:)
        ) { visibilityDate($0) }

        // Downloaded/received files (browser, Mail, Messages, AirDrop) carry
        // the quarantine xattr; screen captures never do. They are refused
        // in `newestInjectableScreenshot`; surface the refusal, count only.
        let quarantined = candidates.filter(\.quarantined)
        if !quarantined.isEmpty {
            diagnostic("watcher.quarantined_skipped", .warn, nil, quarantined.count)
            if verboseDiagnostics() {
                diagnostic(
                    "watcher.quarantined_skipped", .warn,
                    quarantined.map(\.fileName).sorted().joined(separator: ", "), nil)
            }
        }

        guard let path = newestInjectableScreenshot(from: candidates, directory: dir) else {
            // Every remaining candidate was too old; say so rather than drop it silently.
            let stale = staleScreenshotCandidates(from: candidates)
            if !stale.isEmpty {
                diagnostic("watcher.stale_skipped", .warn, nil, stale.count)
                if verboseDiagnostics() {
                    diagnostic(
                        "watcher.stale_skipped", .warn, stale.sorted().joined(separator: ", "), nil)
                }
            }
            return
        }

        diagnostic("watcher.new_screenshot", .info, path, nil)
        onNewScreenshot?(path)
    }
}
