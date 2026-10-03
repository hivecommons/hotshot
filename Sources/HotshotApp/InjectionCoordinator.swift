import Foundation
import HotshotCore

/// Shared body for every injection failure so the manual menu actions and
/// the automatic watchers point at the same Automation-permission fix.
public let INJECTION_FAILED_NOTIFICATION_BODY =
    "Injection FAILED \u{2014} allow Hotshot to control your terminal: System Settings \u{2192} Privacy & Security \u{2192} Automation"

/// Join the optional pieces of a diagnostic line into its `detail` field.
/// `path` and `script` may reveal screenshot directory paths, filenames,
/// generated AppleScript, or clipboard text, so both are redacted unless
/// `verbose`. `count` and `detail` are for non-sensitive, bounded information
/// (e.g. a file count or an AppleScript error description) that is always
/// safe in normal logs. Order is path, script, count, detail.
public func diagnosticDetail(
    path: String? = nil,
    script: String? = nil,
    count: Int? = nil,
    detail: String? = nil,
    verbose: Bool
) -> String? {
    var parts: [String] = []
    if let path {
        parts.append(redacted(path, verbose: verbose))
    }
    if let script {
        parts.append(redacted(script, verbose: verbose))
    }
    if let count {
        parts.append("\(count) file(s)")
    }
    if let detail {
        parts.append(detail)
    }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
}

/// Owns the injection decisions extracted from the app delegate: which
/// guard fires first, when the untrusted clipboard is refused, and what the
/// user is told. Collaborators (pasteboard, `TerminalInjector`, running-app
/// lookup, notifications) are closure seams so the test bundle can drive
/// every branch without AppKit side effects — the same pattern as
/// `TerminalInjector`'s `ScriptRunner`.
public final class InjectionCoordinator {
    /// The tracked terminal the coordinator injects into.
    public struct Target: Equatable {
        public let bundleID: String
        public let name: String?

        public init(bundleID: String, name: String?) {
            self.bundleID = bundleID
            self.name = name
        }
    }

    /// What a coordinator entry point decided; returned so tests (and
    /// callers, if they ever care) can assert the branch taken.
    public enum Outcome: Equatable {
        case noTarget
        case noClipboardImage
        case untrustedClipboard
        case noScreenshot(dir: String)
        case injected(successBody: String)
        case failed
    }

    public typealias Diagnostic = (
        _ event: String, _ severity: DiagnosticSeverity, _ path: String?
    ) -> Void

    private let target: () -> Target?
    private let enrichClipboard: () -> String?
    private let hasClipboardImage: () -> Bool
    private let mostRecentScreenshot: (String) -> String?
    private let sendCtrlV: (_ bundleID: String, _ name: String?) -> Bool
    private let injectPath: (_ path: String, _ bundleID: String) -> Bool
    private let focusTerminal: (_ bundleID: String) -> Void
    private let autoFocus: () -> Bool
    private let notify: (_ body: String) -> Void
    private let diagnostic: Diagnostic

    /// - Parameters:
    ///   - target: the currently tracked terminal, or nil if none yet.
    ///   - enrichClipboard: save the clipboard image and rewrite the
    ///     clipboard with trusted path text; nil when that failed
    ///     (`ClipboardWatcher.enrichWithSavedImage`).
    ///   - hasClipboardImage: whether the clipboard holds an image.
    ///   - mostRecentScreenshot: newest screenshot in a directory, or nil.
    ///   - sendCtrlV / injectPath / focusTerminal: `TerminalInjector` calls.
    ///   - autoFocus: whether to focus the terminal after injecting.
    ///   - notify: post a "Hotshot" notification with the given body.
    ///   - diagnostic: emit a redactable diagnostic line.
    public init(
        target: @escaping () -> Target?,
        enrichClipboard: @escaping () -> String?,
        hasClipboardImage: @escaping () -> Bool,
        mostRecentScreenshot: @escaping (String) -> String? = findMostRecentScreenshot(in:),
        sendCtrlV: @escaping (_ bundleID: String, _ name: String?) -> Bool,
        injectPath: @escaping (_ path: String, _ bundleID: String) -> Bool,
        focusTerminal: @escaping (_ bundleID: String) -> Void,
        autoFocus: @escaping () -> Bool,
        notify: @escaping (_ body: String) -> Void,
        diagnostic: @escaping Diagnostic = { _, _, _ in }
    ) {
        self.target = target
        self.enrichClipboard = enrichClipboard
        self.hasClipboardImage = hasClipboardImage
        self.mostRecentScreenshot = mostRecentScreenshot
        self.sendCtrlV = sendCtrlV
        self.injectPath = injectPath
        self.focusTerminal = focusTerminal
        self.autoFocus = autoFocus
        self.notify = notify
        self.diagnostic = diagnostic
    }

    /// A new image landed on the clipboard (`ClipboardWatcher.onImageDetected`).
    @discardableResult
    public func clipboardImageDetected(changeCount: Int) -> Outcome {
        NSLog("Hotshot: clipboard image detected (changeCount=\(changeCount))")

        // Save to disk and add a plain-text path + file URL alongside the
        // image so both image-paste (Claude Code) and text-paste (GitHub
        // Copilot CLI) consumers work. If the image cannot be saved and the
        // clipboard rewritten, DO NOT paste: Ctrl-V would type whatever
        // text/plain the clipboard's author put alongside the image.
        guard enrichClipboard() != nil else {
            NSLog("Hotshot: could not save/enrich clipboard image; refusing to auto-paste untrusted clipboard")
            notify("Clipboard image could not be saved \u{2014} auto-paste skipped")
            return .untrustedClipboard
        }

        guard let target = target() else {
            NSLog("Hotshot: clipboard image detected but no terminal tracked")
            notify("Clipboard image detected but no terminal session tracked")
            return .noTarget
        }

        let injected = sendCtrlV(target.bundleID, target.name)
        return completeInjection(
            injected, successBody: "Clipboard image injected via Ctrl-V", bundleID: target.bundleID)
    }

    /// "Inject clipboard image (Ctrl-V)" menu action.
    @discardableResult
    public func injectClipboardNow() -> Outcome {
        guard let target = target() else {
            notify("No terminal session tracked yet. Focus a terminal first.")
            return .noTarget
        }

        guard hasClipboardImage() else {
            notify("No image on clipboard")
            return .noClipboardImage
        }

        NSLog("Hotshot: manually injecting clipboard image via Ctrl-V")
        guard enrichClipboard() != nil else {
            NSLog("Hotshot: could not save/enrich clipboard image; refusing to paste untrusted clipboard")
            notify("Could not save the clipboard image \u{2014} paste skipped")
            return .untrustedClipboard
        }
        let injected = sendCtrlV(target.bundleID, target.name)
        return completeInjection(
            injected, successBody: "Clipboard image injected via Ctrl-V", bundleID: target.bundleID)
    }

    /// "Inject last screenshot" menu action. `dir` is already tilde-expanded.
    @discardableResult
    public func injectLastScreenshot(dir: String) -> Outcome {
        guard let target = target() else {
            notify("No terminal session tracked yet. Focus a terminal first.")
            return .noTarget
        }

        guard let latest = mostRecentScreenshot(dir) else {
            notify("No screenshot files found in \(dir)")
            return .noScreenshot(dir: dir)
        }

        diagnostic("screenshot.inject_last", .info, latest)
        let injected = injectPath(latest, target.bundleID)
        return completeInjection(
            injected, successBody: "Injected \u{2192} \(latest)", bundleID: target.bundleID)
    }

    /// A new screenshot file appeared (`ScreenshotWatcher.onNewScreenshot`).
    @discardableResult
    public func newScreenshot(_ path: String) -> Outcome {
        guard let target = target() else {
            NSLog("Hotshot: new screenshot detected but no terminal tracked")
            notify("Screenshot detected but no terminal session tracked")
            return .noTarget
        }

        let injected = injectPath(path, target.bundleID)
        return completeInjection(
            injected,
            successBody: "Auto-injected \u{2192} \((path as NSString).lastPathComponent)",
            bundleID: target.bundleID)
    }

    /// Shared tail of every injection call site: focus the terminal (when
    /// `autoFocus` is on) and post a notification — `successBody` on
    /// success, or the shared `INJECTION_FAILED_NOTIFICATION_BODY` on
    /// failure.
    @discardableResult
    func completeInjection(_ injected: Bool, successBody: String, bundleID: String) -> Outcome {
        if autoFocus() {
            focusTerminal(bundleID)
        }
        notify(injected ? successBody : INJECTION_FAILED_NOTIFICATION_BODY)
        return injected ? .injected(successBody: successBody) : .failed
    }

    /// Where a seeded target came from, so the caller can log it.
    public enum SeedSource: Equatable {
        case frontmost
        case running
    }

    /// Pick the app to seed the tracked terminal from: the frontmost app if
    /// it is a terminal, otherwise the first non-terminated running terminal,
    /// otherwise nil. Generic over the app type so tests need no
    /// `NSRunningApplication`.
    public static func seedCandidate<App>(
        frontmost: App?,
        running: [App],
        bundleID: (App) -> String?,
        isTerminated: (App) -> Bool,
        terminalBundleIDs: Set<String> = TERMINAL_BUNDLE_IDS
    ) -> (app: App, source: SeedSource)? {
        if let front = frontmost,
            let bid = bundleID(front),
            terminalBundleIDs.contains(bid)
        {
            return (front, .frontmost)
        }
        for app in running where !isTerminated(app) {
            if let bid = bundleID(app), terminalBundleIDs.contains(bid) {
                return (app, .running)
            }
        }
        return nil
    }
}
