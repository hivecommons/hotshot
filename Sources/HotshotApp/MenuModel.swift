import Foundation

/// The menu actions the status-bar menu can trigger. The app delegate maps
/// each case onto its `@objc` selector.
public enum MenuAction: Equatable, CaseIterable {
    case toggleAutoFocus
    case toggleAutoReturn
    case toggleNotifications
    case toggleAutoWatch
    case toggleClipboardWatch
    case injectLastScreenshot
    case injectClipboardNow
    case chooseScreenshotDir
    case quit
}

/// Snapshot of the five boolean `@UserDefault` preferences the menu shows
/// as checkmarks.
public struct MenuPrefs: Equatable {
    public var autoFocus: Bool
    public var autoReturn: Bool
    public var notifications: Bool
    public var autoWatch: Bool
    public var clipboardWatch: Bool

    public init(
        autoFocus: Bool, autoReturn: Bool, notifications: Bool, autoWatch: Bool, clipboardWatch: Bool
    ) {
        self.autoFocus = autoFocus
        self.autoReturn = autoReturn
        self.notifications = notifications
        self.autoWatch = autoWatch
        self.clipboardWatch = clipboardWatch
    }
}

/// The watcher side effect a preference toggle requires.
public enum WatcherCommand: Equatable {
    case startScreenshots
    case stopScreenshots
    case startClipboard
    case stopClipboard
}

/// Owns the status-bar menu decisions extracted from the app delegate:
/// item order, titles, which pref drives each checkmark, the tag the target
/// label is looked up by, and which watcher a toggle starts or stops. The
/// delegate only maps these values onto `NSMenu`/`NSMenuItem` and the real
/// watchers, so the test bundle covers every decision without AppKit.
public enum MenuModel {
    /// Tag of the "Target: …" item, used to find it again when the tracked
    /// terminal changes.
    public static let targetItemTag = 100

    /// Title of the target item before any target label refresh.
    public static let initialTargetTitle = "Target: none"

    /// A value-type description of one `NSMenuItem`.
    public struct Item: Equatable {
        public let title: String
        public let action: MenuAction?
        public let keyEquivalent: String
        /// Checkmark state; nil for items that are not toggles.
        public let isOn: Bool?
        public let isEnabled: Bool
        public let tag: Int
        public let isSeparator: Bool

        public init(
            title: String,
            action: MenuAction?,
            keyEquivalent: String = "",
            isOn: Bool? = nil,
            isEnabled: Bool = true,
            tag: Int = 0,
            isSeparator: Bool = false
        ) {
            self.title = title
            self.action = action
            self.keyEquivalent = keyEquivalent
            self.isOn = isOn
            self.isEnabled = isEnabled
            self.tag = tag
            self.isSeparator = isSeparator
        }

        public static let separator = Item(title: "", action: nil, isSeparator: true)
    }

    /// The full status-bar menu, top to bottom: 2 labels, 5 pref toggles,
    /// 2 inject actions, the folder picker and Quit, with separators.
    public static func items(prefs: MenuPrefs, screenshotDir: String) -> [Item] {
        [
            Item(title: initialTargetTitle, action: nil, tag: targetItemTag),
            Item(title: "Save to: \(screenshotDir)", action: nil, isEnabled: false),
            .separator,
            Item(
                title: "Auto-focus terminal after paste", action: .toggleAutoFocus,
                isOn: prefs.autoFocus),
            Item(
                title: "Auto-press Return after paste", action: .toggleAutoReturn,
                isOn: prefs.autoReturn),
            Item(title: "Show notifications", action: .toggleNotifications, isOn: prefs.notifications),
            Item(
                title: "Auto-inject new screenshots (⌘⇧3/4)", action: .toggleAutoWatch,
                isOn: prefs.autoWatch),
            Item(
                title: "Auto-inject from clipboard (⌃⌘⇧3/4)", action: .toggleClipboardWatch,
                isOn: prefs.clipboardWatch),
            .separator,
            Item(title: "Inject last screenshot", action: .injectLastScreenshot),
            Item(title: "Inject clipboard image (Ctrl-V)", action: .injectClipboardNow),
            .separator,
            Item(title: "Change screenshot folder\u{2026}", action: .chooseScreenshotDir),
            .separator,
            Item(title: "Quit Hotshot", action: .quit, keyEquivalent: "q"),
        ]
    }

    /// Title of the target item for a tracked terminal name.
    public static func targetTitle(_ name: String?) -> String {
        "Target: \(name ?? "unknown")"
    }

    /// The result of toggling a preference from the menu.
    public struct ToggleResult: Equatable {
        public let prefs: MenuPrefs
        public let command: WatcherCommand?

        public init(prefs: MenuPrefs, command: WatcherCommand?) {
            self.prefs = prefs
            self.command = command
        }
    }

    /// Flip the pref behind a toggle action and say which watcher (if any)
    /// to start or stop. Only the auto-watch and clipboard-watch toggles
    /// have a side effect, and each only touches its own watcher.
    /// Non-toggle actions return `prefs` unchanged with no command.
    public static func toggle(_ action: MenuAction, prefs: MenuPrefs) -> ToggleResult {
        var next = prefs
        switch action {
        case .toggleAutoFocus:
            next.autoFocus.toggle()
            return ToggleResult(prefs: next, command: nil)
        case .toggleAutoReturn:
            next.autoReturn.toggle()
            return ToggleResult(prefs: next, command: nil)
        case .toggleNotifications:
            next.notifications.toggle()
            return ToggleResult(prefs: next, command: nil)
        case .toggleAutoWatch:
            next.autoWatch.toggle()
            return ToggleResult(
                prefs: next, command: next.autoWatch ? .startScreenshots : .stopScreenshots)
        case .toggleClipboardWatch:
            next.clipboardWatch.toggle()
            return ToggleResult(
                prefs: next, command: next.clipboardWatch ? .startClipboard : .stopClipboard)
        case .injectLastScreenshot, .injectClipboardNow, .chooseScreenshotDir, .quit:
            return ToggleResult(prefs: prefs, command: nil)
        }
    }
}
