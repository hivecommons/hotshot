import AppKit
import HotshotApp
import HotshotCore

// MARK: - App Delegate

class HotshotAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var workspace = NSWorkspace.shared

    /// Target-tracking decisions live in `TargetTracker` (HotshotApp) so the
    /// test bundle covers them; the delegate only wires collaborators.
    lazy var targetTracker: TargetTracker = {
        TargetTracker(
            windowTitle: { [unowned self] pid in self.windowTitle(pid: pid) },
            isRunning: { [unowned self] pid in
                self.workspace.runningApplications.contains { $0.processIdentifier == pid }
            },
            hasTargetLabel: { [unowned self] in self.targetMenuItem != nil },
            setTargetLabel: { [unowned self] title in self.targetMenuItem?.title = title },
            verbose: { [unowned self] in self.verboseDiagnostics },
            diagnostic: { [unowned self] event, detail in self.diag(event, detail: detail) })
    }()

    var targetMenuItem: NSMenuItem? {
        statusItem.menu?.item(withTag: MenuModel.targetItemTag)
    }

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

    /// Injection decisions live in `InjectionCoordinator` (HotshotApp) so
    /// the test bundle covers them; the delegate only wires collaborators.
    lazy var injectionCoordinator: InjectionCoordinator = {
        InjectionCoordinator(
            target: { [unowned self] in
                self.targetTracker.bundleID.map {
                    InjectionCoordinator.Target(bundleID: $0, name: self.targetTracker.name)
                }
            },
            enrichClipboard: { [unowned self] in self.clipboardWatcher.enrichWithSavedImage() },
            hasClipboardImage: { [unowned self] in self.clipboardWatcher.hasImage() },
            mostRecentScreenshot: { dir in findMostRecentScreenshot(in: dir) },
            sendCtrlV: { [unowned self] bid, name in
                self.terminalInjector.sendCtrlV(terminalBundleID: bid, terminalName: name)
            },
            injectPath: { [unowned self] path, bid in
                self.terminalInjector.injectPath(path, terminalBundleID: bid)
            },
            focusTerminal: { [unowned self] bid in self.terminalInjector.focusTerminal(bundleID: bid) },
            autoFocus: { [unowned self] in self.autoFocus },
            notify: { [unowned self] body in self.showNotification(title: "Hotshot", body: body) },
            diagnostic: { [unowned self] event, severity, path in
                self.diag(event, severity: severity, path: path)
            })
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

    var menuPrefs: MenuPrefs {
        MenuPrefs(
            autoFocus: autoFocus, autoReturn: autoReturn, notifications: notifications,
            autoWatch: autoWatch, clipboardWatch: clipboardWatch)
    }

    var screenshotDir: String {
        get { UserDefaults.standard.string(forKey: PREF_SCREENSHOT_DIR) ?? macOSScreenshotLocation() }
        set { UserDefaults.standard.set(newValue, forKey: PREF_SCREENSHOT_DIR) }
    }

    /// Cached once per process; verbosity is controlled by the
    /// HOTSHOT_VERBOSE_LOGGING env var at launch, not by app state.
    lazy var verboseDiagnostics: Bool = verboseDiagnosticsEnabled()

    /// Emit a stable, local-only diagnostic line (see HotshotCore.diagnosticLine).
    /// Redaction and ordering of `path`/`script`/`count`/`detail` are decided
    /// by `diagnosticDetail` (HotshotApp); `path` and `script` stay redacted
    /// unless HOTSHOT_VERBOSE_LOGGING=1 is set.
    func diag(
        _ event: String,
        severity: DiagnosticSeverity = .info,
        path: String? = nil,
        script: String? = nil,
        count: Int? = nil,
        detail: String? = nil
    ) {
        let joinedDetail = diagnosticDetail(
            path: path, script: script, count: count, detail: detail, verbose: verboseDiagnostics)
        NSLog(diagnosticLine(event: event, severity: severity, detail: joinedDetail))
    }

    func setTarget(_ app: NSRunningApplication) {
        targetTracker.setTarget(
            bundleID: app.bundleIdentifier, pid: app.processIdentifier, localizedName: app.localizedName)
    }

    /// Seed the tracked terminal target from the frontmost application, or
    /// failing that, the first running terminal, when no target is set yet.
    /// Shared by launch-time seeding and the menu-open fallback so both
    /// paths agree on what counts as "a terminal".
    func seedTargetFromRunningApps(logPrefix: String) {
        guard
            let seed = InjectionCoordinator.seedCandidate(
                frontmost: workspace.frontmostApplication,
                running: workspace.runningApplications,
                bundleID: { $0.bundleIdentifier },
                isTerminated: { $0.isTerminated })
        else { return }
        setTarget(seed.app)
        switch seed.source {
        case .frontmost:
            diag(
                DiagnosticEvent.targetSeeded.rawValue,
                detail: "\(logPrefix): \(redacted(targetTracker.name ?? "unknown", verbose: verboseDiagnostics))")
        case .running:
            diag(
                DiagnosticEvent.targetFoundRunning.rawValue,
                detail: "\(logPrefix): \(redacted(targetTracker.name ?? "unknown", verbose: verboseDiagnostics))")
        }
    }

    func windowTitle(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
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
        for item in MenuModel.items(prefs: menuPrefs, screenshotDir: screenshotDir) {
            if item.isSeparator {
                menu.addItem(NSMenuItem.separator())
                continue
            }
            let menuItem = NSMenuItem(
                title: item.title, action: item.action.map { self.selector(for: $0) },
                keyEquivalent: item.keyEquivalent)
            menuItem.tag = item.tag
            menuItem.isEnabled = item.isEnabled
            if let isOn = item.isOn {
                menuItem.state = isOn ? .on : .off
            }
            menu.addItem(menuItem)
        }

        menu.delegate = self
        statusItem.menu = menu
        updateTargetLabel()
    }

    func selector(for action: MenuAction) -> Selector {
        switch action {
        case .toggleAutoFocus: return #selector(toggleAutoFocus)
        case .toggleAutoReturn: return #selector(toggleAutoReturn)
        case .toggleNotifications: return #selector(toggleNotifications)
        case .toggleAutoWatch: return #selector(toggleAutoWatch)
        case .toggleClipboardWatch: return #selector(toggleClipboardWatch)
        case .injectLastScreenshot: return #selector(injectLastScreenshot)
        case .injectClipboardNow: return #selector(injectClipboardNow)
        case .chooseScreenshotDir: return #selector(chooseScreenshotDir)
        case .quit: return #selector(NSApplication.terminate(_:))
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        targetTracker.menuWillOpen { self.seedTargetFromRunningApps(logPrefix: "menuWillOpen") }
    }

    @objc func toggleAutoFocus() { applyToggle(.toggleAutoFocus) }

    @objc func toggleAutoReturn() { applyToggle(.toggleAutoReturn) }

    @objc func toggleNotifications() { applyToggle(.toggleNotifications) }

    @objc func toggleAutoWatch() { applyToggle(.toggleAutoWatch) }

    @objc func toggleClipboardWatch() { applyToggle(.toggleClipboardWatch) }

    /// Persist only the pref `MenuModel.toggle` flipped, run its watcher
    /// command, then rebuild the menu.
    func applyToggle(_ action: MenuAction) {
        let current = menuPrefs
        let result = MenuModel.toggle(action, prefs: current)
        let next = result.prefs
        if next.autoFocus != current.autoFocus { autoFocus = next.autoFocus }
        if next.autoReturn != current.autoReturn { autoReturn = next.autoReturn }
        if next.notifications != current.notifications { notifications = next.notifications }
        if next.autoWatch != current.autoWatch { autoWatch = next.autoWatch }
        if next.clipboardWatch != current.clipboardWatch { clipboardWatch = next.clipboardWatch }
        switch result.command {
        case .startScreenshots?: startWatchingScreenshots()
        case .stopScreenshots?: stopWatchingScreenshots()
        case .startClipboard?: startWatchingClipboard()
        case .stopClipboard?: stopWatchingClipboard()
        case nil: break
        }
        rebuildMenu()
    }

    @objc func injectClipboardNow() {
        injectionCoordinator.injectClipboardNow()
    }

    // MARK: - Clipboard Watcher

    func startWatchingClipboard() { clipboardWatcher.start() }

    func stopWatchingClipboard() { clipboardWatcher.stop() }

    func handleClipboardImage(changeCount: Int) {
        injectionCoordinator.clipboardImageDetected(changeCount: changeCount)
    }

    @objc func injectLastScreenshot() {
        injectionCoordinator.injectLastScreenshot(dir: (screenshotDir as NSString).expandingTildeInPath)
    }

    // MARK: - Screenshot Folder Watcher

    func startWatchingScreenshots() { screenshotWatcher.start() }

    func stopWatchingScreenshots() { screenshotWatcher.stop() }

    func handleNewScreenshot(_ path: String) {
        injectionCoordinator.newScreenshot(path)
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
        targetTracker.refreshTargetLabel()
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
            as? NSRunningApplication
        else { return }
        targetTracker.appDidActivate(
            bundleID: app.bundleIdentifier, pid: app.processIdentifier, localizedName: app.localizedName)
    }

    // MARK: - Path Injection

    func showNotification(title: String, body: String) {
        terminalInjector.showNotification(title: title, body: body)
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = HotshotAppDelegate()
app.delegate = delegate
app.run()
