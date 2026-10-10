import Foundation
import HotshotCore

/// The menu actions the status-bar menu can trigger. Each case names the
/// `@objc` selector it dispatches to (see `selectorName`).
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

    /// Objective-C selector name of the handler: an `@objc` method on the
    /// app delegate, or `NSApplication.terminate(_:)` for `.quit`. Menu
    /// items have no explicit target, so the action travels the responder
    /// chain to whichever of the two implements it.
    public var selectorName: String {
        switch self {
        case .toggleAutoFocus: return "toggleAutoFocus"
        case .toggleAutoReturn: return "toggleAutoReturn"
        case .toggleNotifications: return "toggleNotifications"
        case .toggleAutoWatch: return "toggleAutoWatch"
        case .toggleClipboardWatch: return "toggleClipboardWatch"
        case .injectLastScreenshot: return "injectLastScreenshot"
        case .injectClipboardNow: return "injectClipboardNow"
        case .chooseScreenshotDir: return "chooseScreenshotDir"
        case .quit: return "terminate:"
        }
    }
}

/// One of the five boolean preferences behind the menu checkmarks.
public enum PrefKey: Equatable, CaseIterable {
    case autoFocus
    case autoReturn
    case notifications
    case autoWatch
    case clipboardWatch

    /// The `UserDefaults` key the pref is persisted under.
    public var defaultsKey: String {
        switch self {
        case .autoFocus: return PREF_AUTO_FOCUS
        case .autoReturn: return PREF_AUTO_RETURN
        case .notifications: return PREF_NOTIFICATIONS
        case .autoWatch: return PREF_AUTO_WATCH
        case .clipboardWatch: return PREF_CLIPBOARD_WATCH
        }
    }
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

extension MenuPrefs {
    /// The value of one pref.
    public subscript(key: PrefKey) -> Bool {
        switch key {
        case .autoFocus: return autoFocus
        case .autoReturn: return autoReturn
        case .notifications: return notifications
        case .autoWatch: return autoWatch
        case .clipboardWatch: return clipboardWatch
        }
    }
}

/// The watcher side effect a preference toggle requires.
public enum WatcherCommand: Equatable {
    case startScreenshots
    case stopScreenshots
    case startClipboard
    case stopClipboard
}

/// The four watcher operations a `WatcherCommand` can trigger.
public struct WatcherControls {
    public let startScreenshots: () -> Void
    public let stopScreenshots: () -> Void
    public let startClipboard: () -> Void
    public let stopClipboard: () -> Void

    public init(
        startScreenshots: @escaping () -> Void,
        stopScreenshots: @escaping () -> Void,
        startClipboard: @escaping () -> Void,
        stopClipboard: @escaping () -> Void
    ) {
        self.startScreenshots = startScreenshots
        self.stopScreenshots = stopScreenshots
        self.startClipboard = startClipboard
        self.stopClipboard = stopClipboard
    }

    /// Run the operation `command` names.
    public func run(_ command: WatcherCommand) {
        switch command {
        case .startScreenshots: startScreenshots()
        case .stopScreenshots: stopScreenshots()
        case .startClipboard: startClipboard()
        case .stopClipboard: stopClipboard()
        }
    }
}

/// Owns the status-bar menu decisions extracted from the app delegate:
/// item order, titles, which pref drives each checkmark, the tag the target
/// label is looked up by, which prefs a toggle persists and which watcher it
/// starts or stops. `makeMenu` (MenuBuilder.swift) turns the items into an
/// `NSMenu`; the delegate only installs it and wires the real watchers, so
/// the test bundle covers every decision.
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

    /// The prefs whose values differ between `current` and `next`, in
    /// `PrefKey.allCases` order.
    public static func changedPrefs(from current: MenuPrefs, to next: MenuPrefs) -> [PrefKey] {
        PrefKey.allCases.filter { current[$0] != next[$0] }
    }

    /// Apply a toggle action: persist only the pref(s) `toggle` changed,
    /// then run its watcher command, if any. Returns the new prefs.
    @discardableResult
    public static func applyToggle(
        _ action: MenuAction,
        prefs: MenuPrefs,
        persist: (PrefKey, Bool) -> Void,
        watchers: WatcherControls
    ) -> MenuPrefs {
        let result = toggle(action, prefs: prefs)
        for key in changedPrefs(from: prefs, to: result.prefs) {
            persist(key, result.prefs[key])
        }
        if let command = result.command {
            watchers.run(command)
        }
        return result.prefs
    }
}
