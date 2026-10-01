import AppKit
import HotshotCore

/// Shared body for every injection failure so the manual menu actions and
/// the automatic watchers point at the same Automation-permission fix.
let INJECTION_FAILED_NOTIFICATION_BODY =
    "Injection FAILED \u{2014} allow Hotshot to control your terminal: System Settings \u{2192} Privacy & Security \u{2192} Automation"

// MARK: - App Delegate

class HotshotApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var lastTerminalBundleID: String?
    var lastTerminalPID: pid_t?
    var lastTerminalName: String?
    var workspace = NSWorkspace.shared

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

    lazy var screenshotWatcher: ScreenshotWatcher = {
        let watcher = ScreenshotWatcher(
            screenshotDirectory: { [unowned self] in self.screenshotDir },
            verboseDiagnostics: { [unowned self] in self.verboseDiagnostics },
            diagnostic: { [unowned self] event, severity, path, count in
                self.diag(event, severity: severity, path: path, count: count)
            })
        watcher.onNewScreenshot = { [unowned self] path in
            self.handleNewScreenshot(path)
        }
        return watcher
    }()

    lazy var terminalInjector: TerminalInjector = {
        TerminalInjector(
            diagnostic: { [unowned self] event, severity, path, script, detail in
                self.diag(event, severity: severity, path: path, script: script, detail: detail)
            },
            loadPasteboard: { [unowned self] path in
                self.clipboardWatcher.loadPasteboard(withFile: path)
            },
            autoReturn: { [unowned self] in self.autoReturn },
            autoFocus: { [unowned self] in self.autoFocus },
            notificationsEnabled: { [unowned self] in self.notifications },
            verboseDiagnostics: { [unowned self] in self.verboseDiagnostics }
        )
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
        let injected = terminalInjector.sendCtrlV(terminalBundleID: bid, terminalName: lastTerminalName)
        if autoFocus {
            terminalInjector.focusTerminal(bundleID: bid)
        }
        if injected {
            showNotification(title: "Hotshot", body: "Clipboard image injected via Ctrl-V")
        } else {
            showNotification(title: "Hotshot", body: INJECTION_FAILED_NOTIFICATION_BODY)
        }
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

        let injected = terminalInjector.sendCtrlV(terminalBundleID: bid, terminalName: lastTerminalName)
        if autoFocus {
            terminalInjector.focusTerminal(bundleID: bid)
        }
        if injected {
            showNotification(title: "Hotshot", body: "Clipboard image injected via Ctrl-V")
        } else {
            showNotification(title: "Hotshot", body: INJECTION_FAILED_NOTIFICATION_BODY)
        }
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
        let injected = terminalInjector.injectPath(latest, terminalBundleID: bid)
        if autoFocus {
            terminalInjector.focusTerminal(bundleID: bid)
        }
        if injected {
            showNotification(title: "Hotshot", body: "Injected \u{2192} \(latest)")
        } else {
            showNotification(title: "Hotshot", body: INJECTION_FAILED_NOTIFICATION_BODY)
        }
    }

    // MARK: - Screenshot Folder Watcher

    func startWatchingScreenshots() { screenshotWatcher.start() }

    func stopWatchingScreenshots() { screenshotWatcher.stop() }

    func handleNewScreenshot(_ path: String) {
        guard let bid = lastTerminalBundleID else {
            NSLog("Hotshot: new screenshot detected but no terminal tracked")
            showNotification(title: "Hotshot", body: "Screenshot detected but no terminal session tracked")
            return
        }

        let injected = terminalInjector.injectPath(path, terminalBundleID: bid)
        if autoFocus {
            terminalInjector.focusTerminal(bundleID: bid)
        }
        if injected {
            showNotification(title: "Hotshot", body: "Auto-injected \u{2192} \((path as NSString).lastPathComponent)")
        } else {
            showNotification(title: "Hotshot", body: INJECTION_FAILED_NOTIFICATION_BODY)
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

    func showNotification(title: String, body: String) {
        terminalInjector.showNotification(title: title, body: body)
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = HotshotApp()
app.delegate = delegate
app.run()
