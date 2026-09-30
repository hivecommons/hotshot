import AppKit
import HotshotCore

// MARK: - App Delegate

class HotshotApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var lastTerminalBundleID: String?
    var lastTerminalPID: pid_t?
    var lastTerminalName: String?
    var workspace = NSWorkspace.shared
    var watcherSource: DispatchSourceFileSystemObject?
    var watcherFD: Int32 = -1
    var lastSeenScreenshots: Set<String> = []
    var watchDebounceTimer: DispatchSourceTimer?

    lazy var clipboardWatcher: ClipboardWatcher = {
        let watcher = ClipboardWatcher(
            screenshotDirectory: { [unowned self] in self.screenshotDir },
            diagnostic: { [unowned self] event, severity, path, detail in
                self.diag(event, severity: severity, path: path, detail: detail)
            })
        watcher.onImageDetected = { [unowned self] count in
            self.handleClipboardImage(changeCount: count)
        }
        return watcher
    }()

    @UserDefault(PREF_AUTO_FOCUS, defaultValue: true)
    var autoFocus: Bool

    @UserDefault(PREF_AUTO_RETURN, defaultValue: false)
    var autoReturn: Bool

    @UserDefault(PREF_NOTIFICATIONS, defaultValue: false)
    var notifications: Bool

    @UserDefault(PREF_AUTO_WATCH, defaultValue: true)
    var autoWatch: Bool

    @UserDefault(PREF_CLIPBOARD_WATCH, defaultValue: true)
    var clipboardWatch: Bool

    var screenshotDir: String {
        get { UserDefaults.standard.string(forKey: PREF_SCREENSHOT_DIR) ?? macOSScreenshotLocation() }
        set { UserDefaults.standard.set(newValue, forKey: PREF_SCREENSHOT_DIR) }
    }

    /// Cached once per process; verbosity is controlled by the
    /// HOTSHOT_VERBOSE_LOGGING env var at launch, not by app state.
    lazy var verboseDiagnostics: Bool = verboseDiagnosticsEnabled()

    /// Emit a stable, local-only diagnostic line (see HotshotCore.diagnosticLine).
    /// `path` and `script` may reveal screenshot directory paths, filenames,
    /// generated AppleScript, or clipboard text, so both are redacted unless
    /// HOTSHOT_VERBOSE_LOGGING=1 is set. `count` and `detail` are for
    /// non-sensitive, bounded information (e.g. a file count or an
    /// AppleScript error description) that is always safe in normal logs.
    func diag(
        _ event: String,
        severity: DiagnosticSeverity = .info,
        path: String? = nil,
        script: String? = nil,
        count: Int? = nil,
        detail: String? = nil
    ) {
        var parts: [String] = []
        if let path {
            parts.append(redacted(path, verbose: verboseDiagnostics))
        }
        if let script {
            parts.append(redacted(script, verbose: verboseDiagnostics))
        }
        if let count {
            parts.append("\(count) file(s)")
        }
        if let detail {
            parts.append(detail)
        }
        let joinedDetail = parts.isEmpty ? nil : parts.joined(separator: ", ")
        NSLog(diagnosticLine(event: event, severity: severity, detail: joinedDetail))
    }

    func setTarget(_ app: NSRunningApplication) {
        lastTerminalBundleID = app.bundleIdentifier
        lastTerminalPID = app.processIdentifier
        lastTerminalName = windowTitle(for: app) ?? app.localizedName ?? "unknown"
    }

    /// Seed the tracked terminal target from the frontmost application, or
    /// failing that, the first running terminal, when no target is set yet.
    /// Shared by launch-time seeding and the menu-open fallback so both
    /// paths agree on what counts as "a terminal".
    func seedTargetFromRunningApps(logPrefix: String) {
        if let front = workspace.frontmostApplication,
            let bid = front.bundleIdentifier,
            TERMINAL_BUNDLE_IDS.contains(bid)
        {
            setTarget(front)
            NSLog("Hotshot: \(logPrefix) seeded target = \(lastTerminalName ?? "unknown")")
        } else {
            for app in workspace.runningApplications where !app.isTerminated {
                if let bid = app.bundleIdentifier, TERMINAL_BUNDLE_IDS.contains(bid) {
                    setTarget(app)
                    NSLog("Hotshot: \(logPrefix) found running terminal = \(lastTerminalName ?? "unknown")")
                    break
                }
            }
        }
    }

    func windowTitle(for app: NSRunningApplication) -> String? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else {
            return nil
        }
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(
            atPath: screenshotDir, withIntermediateDirectories: true)

        setupStatusBar()
        observeAppActivation()

        seedTargetFromRunningApps(logPrefix: "launch")

        diag("app.launched", path: screenshotDir)

        if autoWatch {
            startWatchingScreenshots()
        }
        if clipboardWatch {
            startWatchingClipboard()
        }
    }

    // MARK: - Status Bar

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let img = NSImage(
                systemSymbolName: "camera.viewfinder",
                accessibilityDescription: "Hotshot")
            {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "HS"
            }
            button.toolTip = "Hotshot \u{2014} screenshot \u{2192} terminal"
        }

        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let targetItem = NSMenuItem(title: "Target: none", action: nil, keyEquivalent: "")
        targetItem.tag = 100
        menu.addItem(targetItem)

        let dirItem = NSMenuItem(title: "Save to: \(screenshotDir)", action: nil, keyEquivalent: "")
        dirItem.isEnabled = false
        menu.addItem(dirItem)

        menu.addItem(NSMenuItem.separator())

        let focusItem = NSMenuItem(
            title: "Auto-focus terminal after paste",
            action: #selector(toggleAutoFocus), keyEquivalent: "")
        focusItem.state = autoFocus ? .on : .off
        menu.addItem(focusItem)

        let returnItem = NSMenuItem(
            title: "Auto-press Return after paste",
            action: #selector(toggleAutoReturn), keyEquivalent: "")
        returnItem.state = autoReturn ? .on : .off
        menu.addItem(returnItem)

        let notifyItem = NSMenuItem(
            title: "Show notifications",
            action: #selector(toggleNotifications), keyEquivalent: "")
        notifyItem.state = notifications ? .on : .off
        menu.addItem(notifyItem)

        let watchItem = NSMenuItem(
            title: "Auto-inject new screenshots (⌘⇧3/4)",
            action: #selector(toggleAutoWatch), keyEquivalent: "")
        watchItem.state = autoWatch ? .on : .off
        menu.addItem(watchItem)

        let clipItem = NSMenuItem(
            title: "Auto-inject from clipboard (⌃⌘⇧3/4)",
            action: #selector(toggleClipboardWatch), keyEquivalent: "")
        clipItem.state = clipboardWatch ? .on : .off
        menu.addItem(clipItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(
            withTitle: "Inject last screenshot", action: #selector(injectLastScreenshot),
            keyEquivalent: "")
        menu.addItem(
            withTitle: "Inject clipboard image (Ctrl-V)", action: #selector(injectClipboardNow),
            keyEquivalent: "")

        menu.addItem(NSMenuItem.separator())

        menu.addItem(
            withTitle: "Change screenshot folder\u{2026}", action: #selector(chooseScreenshotDir),
            keyEquivalent: "")

        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Quit Hotshot", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        menu.delegate = self
        statusItem.menu = menu
        updateTargetLabel()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if lastTerminalBundleID == nil {
            seedTargetFromRunningApps(logPrefix: "menuWillOpen")
        }
        updateTargetLabel()
    }

    @objc func toggleAutoFocus() {
        autoFocus = !autoFocus
        rebuildMenu()
    }

    @objc func toggleAutoReturn() {
        autoReturn = !autoReturn
        rebuildMenu()
    }

    @objc func toggleNotifications() {
        notifications = !notifications
        rebuildMenu()
    }

    @objc func toggleAutoWatch() {
        autoWatch = !autoWatch
        if autoWatch {
            startWatchingScreenshots()
        } else {
            stopWatchingScreenshots()
        }
        rebuildMenu()
    }

    @objc func toggleClipboardWatch() {
        clipboardWatch = !clipboardWatch
        if clipboardWatch {
            startWatchingClipboard()
        } else {
            stopWatchingClipboard()
        }
        rebuildMenu()
    }

    @objc func injectClipboardNow() {
        guard let bid = lastTerminalBundleID else {
            showNotification(title: "Hotshot", body: "No terminal session tracked yet. Focus a terminal first.")
            return
        }

        guard clipboardWatcher.hasImage() else {
            showNotification(title: "Hotshot", body: "No image on clipboard")
            return
        }

        NSLog("Hotshot: manually injecting clipboard image via Ctrl-V")
        guard clipboardWatcher.enrichWithSavedImage() != nil else {
            NSLog("Hotshot: could not save/enrich clipboard image; refusing to paste untrusted clipboard")
            showNotification(
                title: "Hotshot",
                body: "Could not save the clipboard image \u{2014} paste skipped")
            return
        }
        sendCtrlV(terminalBundleID: bid)
        showNotification(title: "Hotshot", body: "Clipboard image injected via Ctrl-V")
    }

    // MARK: - Clipboard Watcher

    func startWatchingClipboard() { clipboardWatcher.start() }

    func stopWatchingClipboard() { clipboardWatcher.stop() }

    func handleClipboardImage(changeCount: Int) {
        NSLog("Hotshot: clipboard image detected (changeCount=\(changeCount))")

        // Save to disk and add a plain-text path + file URL alongside the
        // image so both image-paste (Claude Code) and text-paste (GitHub
        // Copilot CLI) consumers work. If the image cannot be saved and the
        // clipboard rewritten, DO NOT paste: Ctrl-V would type whatever
        // text/plain the clipboard's author put alongside the image.
        guard clipboardWatcher.enrichWithSavedImage() != nil else {
            NSLog("Hotshot: could not save/enrich clipboard image; refusing to auto-paste untrusted clipboard")
            showNotification(
                title: "Hotshot",
                body: "Clipboard image could not be saved \u{2014} auto-paste skipped")
            return
        }

        guard let bid = lastTerminalBundleID else {
            NSLog("Hotshot: clipboard image detected but no terminal tracked")
            showNotification(title: "Hotshot", body: "Clipboard image detected but no terminal session tracked")
            return
        }

        let injected = sendCtrlV(terminalBundleID: bid)
        if autoFocus {
            focusTerminal(bundleID: bid)
        }
        if injected {
            showNotification(title: "Hotshot", body: "Clipboard image injected via Ctrl-V")
        } else {
            showNotification(title: "Hotshot", body: "Injection FAILED \u{2014} allow Hotshot to control your terminal: System Settings \u{2192} Privacy & Security \u{2192} Automation")
        }
    }

    @discardableResult
    func sendCtrlV(terminalBundleID bid: String) -> Bool {
        let script = ctrlVScript(bundleID: bid)
        NSLog("Hotshot: sending Ctrl-V to \(lastTerminalName ?? bid)")
        return runAppleScript(script)
    }

    @objc func injectLastScreenshot() {
        let dir = (screenshotDir as NSString).expandingTildeInPath
        guard let bid = lastTerminalBundleID else {
            showNotification(title: "Hotshot", body: "No terminal session tracked yet. Focus a terminal first.")
            return
        }

        guard let latest = findMostRecentScreenshot(in: dir) else {
            showNotification(title: "Hotshot", body: "No screenshot files found in \(dir)")
            return
        }

        diag("screenshot.inject_last", path: latest)
        injectPath(latest, terminalBundleID: bid)
        if autoFocus {
            focusTerminal(bundleID: bid)
        }
        showNotification(title: "Hotshot", body: "Injected \u{2192} \(latest)")
    }

    // MARK: - Screenshot Folder Watcher

    func startWatchingScreenshots() {
        stopWatchingScreenshots()

        let dir = (screenshotDir as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        lastSeenScreenshots = snapshotScreenshotFiles(in: dir)

        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            diag("watcher.open_failed", severity: .error, path: dir)
            return
        }
        watcherFD = fd

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
        watcherSource = source
        diag("watcher.started", path: dir)
    }

    func stopWatchingScreenshots() {
        watchDebounceTimer?.cancel()
        watchDebounceTimer = nil
        watcherSource?.cancel()
        watcherSource = nil
        watcherFD = -1
        NSLog("Hotshot: stopped watching for screenshots")
    }

    func handleDirectoryChange() {
        // Verbose-only: this fires on every filesystem event, so normal
        // diagnostics stay bounded to the debounced outcome logged below.
        if verboseDiagnostics {
            diag("watcher.directory_change", severity: .info)
        }
        watchDebounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + WATCH_DEBOUNCE_SECONDS)
        timer.setEventHandler { [weak self] in
            self?.checkForNewScreenshots()
        }
        timer.resume()
        watchDebounceTimer = timer
    }

    func checkForNewScreenshots() {
        let dir = (screenshotDir as NSString).expandingTildeInPath
        let current = snapshotScreenshotFiles(in: dir)
        let newFiles = newScreenshotFiles(previous: lastSeenScreenshots, current: current)
        lastSeenScreenshots = current

        // Bounded, per-debounced-cycle: only log when there is something to
        // report, and only a count in normal diagnostics — filenames may be
        // revealing and are never included unless HOTSHOT_VERBOSE_LOGGING=1.
        guard !newFiles.isEmpty else { return }
        diag("watcher.new_files", count: newFiles.count)
        if verboseDiagnostics {
            diag("watcher.new_files", severity: .info, path: newFiles.sorted().joined(separator: ", "))
        }

        let fm = FileManager.default
        var candidates: [ScreenshotFileCandidate] = []

        for file in newFiles {
            let fullPath = (dir as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            candidates.append(ScreenshotFileCandidate(fileName: file, modifiedAt: modified))
        }

        guard let path = newestInjectableScreenshot(from: candidates, directory: dir) else { return }

        diag("watcher.new_screenshot", path: path)

        guard let bid = lastTerminalBundleID else {
            NSLog("Hotshot: new screenshot detected but no terminal tracked")
            showNotification(title: "Hotshot", body: "Screenshot detected but no terminal session tracked")
            return
        }

        let injected = injectPath(path, terminalBundleID: bid)
        if autoFocus {
            focusTerminal(bundleID: bid)
        }
        if injected {
            showNotification(title: "Hotshot", body: "Auto-injected \u{2192} \((path as NSString).lastPathComponent)")
        } else {
            showNotification(title: "Hotshot", body: "Injection FAILED \u{2014} allow Hotshot to control your terminal: System Settings \u{2192} Privacy & Security \u{2192} Automation")
        }
    }

    @objc func chooseScreenshotDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select folder for hotshot screenshots"
        panel.directoryURL = URL(fileURLWithPath: screenshotDir)

        if panel.runModal() == .OK, let url = panel.url {
            screenshotDir = url.path
            rebuildMenu()
        }
    }

    func updateTargetLabel() {
        guard let menuItem = statusItem.menu?.item(withTag: 100) else { return }
        guard let pid = lastTerminalPID else { return }
        if let app = workspace.runningApplications.first(where: { $0.processIdentifier == pid }),
           let title = windowTitle(for: app), !title.isEmpty {
            lastTerminalName = title
        }
        menuItem.title = "Target: \(lastTerminalName ?? "unknown")"
    }

    // MARK: - App Activation Observer

    func observeAppActivation() {
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
            let bid = app.bundleIdentifier
        else { return }

        if TERMINAL_BUNDLE_IDS.contains(bid) {
            setTarget(app)
            updateTargetLabel()
            NSLog("Hotshot: target changed to \(lastTerminalName ?? "unknown")")
        }
    }

    // MARK: - Path Injection

    func runAppleScriptForResult(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    /// List the commands of processes attached to a tty (e.g. "ttys003").
    func commands(onTTY tty: String) -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-t", tty, "-o", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let out = String(data: data, encoding: .utf8) else { return [] }
            return parsePSOutput(out)
        } catch {
            return []
        }
    }

    /// Detect which CLI is running in the target terminal's focused session.
    /// Fetches the tty (AppleScript) and its commands (`ps`) as the only
    /// side effects; the tty-to-CLI decision itself is `resolveTargetCLI`,
    /// a pure HotshotCore function covered by unit tests.
    func detectTargetCLI(terminalBundleID bid: String) -> TargetCLI {
        let ttyPath = ttyScript(forBundleID: bid).flatMap(runAppleScriptForResult)
        if ttyPath == nil || ttyPath?.isEmpty == true {
            NSLog("Hotshot: cannot determine tty for \(bid); defaulting to bracketed format")
        }
        let cli = resolveTargetCLI(ttyPath: ttyPath, commandsForTTY: { self.commands(onTTY: $0) })
        NSLog("Hotshot: detected CLI=\(String(describing: cli)) for \(bid)")
        return cli
    }

    @discardableResult
    func injectPath(_ path: String, terminalBundleID bid: String) -> Bool {
        let targetCLI = detectTargetCLI(terminalBundleID: bid)
        guard let text = typedScreenshotText(path: path, targetCLI: targetCLI) else {
            diag("injection.control_chars_refused", severity: .warn, path: path)
            showNotification(
                title: "Hotshot",
                body: "Refused to inject a file whose name contains control characters")
            return false
        }
        // Load the pasteboard with image + file URL + plain-text path so
        // CLIs that read the clipboard (GitHub Copilot CLI via ⌘V, Claude
        // Code via Ctrl-V) can consume the screenshot too.
        clipboardWatcher.loadPasteboard(withFile: path)

        // Type the format the CLI in the target session understands:
        // Claude Code expects "[path] "; GitHub Copilot CLI and friends
        // need a bare shell-escaped path (as Finder drag-and-drop inserts).
        switch injectionTarget(forBundleID: bid) {
        case .iTerm2:
            return injectViaITerm2(text)
        case .generic:
            return injectViaGenericAppleScript(text, bundleID: bid)
        }
    }

    func injectViaITerm2(_ path: String) -> Bool {
        let script = iterm2InjectionScript(text: path, autoReturn: autoReturn, autoFocus: autoFocus)
        diag("injection.iterm2", path: path)
        if verboseDiagnostics {
            diag("injection.iterm2.script", severity: .info, script: script)
        }
        return runAppleScript(script)
    }

    func injectViaGenericAppleScript(_ path: String, bundleID: String) -> Bool {
        return runAppleScript(
            genericInjectionScript(text: path, bundleID: bundleID, autoReturn: autoReturn))
    }

    func focusTerminal(bundleID: String) {
        let script = """
            tell application id "\(bundleID)"
                activate
            end tell
            """
        runAppleScript(script)
    }

    @discardableResult
    func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            let result = script.executeAndReturnError(&error)
            if let err = error {
                diag("applescript.error", severity: .error, detail: "\(err)")
                return false
            }
            if verboseDiagnostics {
                diag("applescript.result", severity: .info, path: result.stringValue ?? "(none)")
            }
            return true
        }
        diag("applescript.unavailable", severity: .error)
        return false
    }

    func showNotification(title: String, body: String) {
        guard notifications else { return }
        runAppleScript(notificationScript(title: title, body: body))
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = HotshotApp()
app.delegate = delegate
app.run()
