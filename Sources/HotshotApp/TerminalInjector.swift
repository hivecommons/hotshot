import AppKit
import HotshotCore

/// Owns AppleScript execution and injection-strategy selection, extracted
/// from the app delegate. Follows the same seam pattern as `ClipboardWatcher`:
/// side-effecting AppKit/AppleScript/`ps` calls live here, while the actual
/// decisions (`injectionTarget`, `resolveTargetCLI`, `typedScreenshotText`)
/// stay in HotshotCore as pure, unit-tested functions.
public final class TerminalInjector {
    public typealias Diagnostic = (
        _ event: String, _ severity: DiagnosticSeverity, _ path: String?, _ script: String?,
        _ detail: String?
    ) -> Void

    private let diagnostic: Diagnostic
    private let loadPasteboard: (String) -> Void
    private let autoReturn: () -> Bool
    private let autoFocus: () -> Bool
    private let notificationsEnabled: () -> Bool
    private let verboseDiagnostics: () -> Bool

    public init(
        diagnostic: @escaping Diagnostic,
        loadPasteboard: @escaping (String) -> Void,
        autoReturn: @escaping () -> Bool,
        autoFocus: @escaping () -> Bool,
        notificationsEnabled: @escaping () -> Bool,
        verboseDiagnostics: @escaping () -> Bool
    ) {
        self.diagnostic = diagnostic
        self.loadPasteboard = loadPasteboard
        self.autoReturn = autoReturn
        self.autoFocus = autoFocus
        self.notificationsEnabled = notificationsEnabled
        self.verboseDiagnostics = verboseDiagnostics
    }

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
    public func sendCtrlV(terminalBundleID bid: String, terminalName: String?) -> Bool {
        let script = ctrlVScript(bundleID: bid)
        NSLog("Hotshot: sending Ctrl-V to \(terminalName ?? bid)")
        return runAppleScript(script)
    }

    @discardableResult
    public func injectPath(_ path: String, terminalBundleID bid: String) -> Bool {
        let targetCLI = detectTargetCLI(terminalBundleID: bid)
        guard let text = typedScreenshotText(path: path, targetCLI: targetCLI) else {
            if containsControlCharacters(path) {
                diagnostic("injection.control_chars_refused", .warn, path, nil, nil)
                showNotification(
                    title: "Hotshot",
                    body: "Refused to inject a file whose name contains control characters")
            } else {
                diagnostic("injection.shell_metachars_refused", .warn, path, nil, nil)
                showNotification(
                    title: "Hotshot",
                    body: "Refused to inject a file whose name contains shell metacharacters")
            }
            return false
        }
        // Load the pasteboard with image + file URL + plain-text path so
        // CLIs that read the clipboard (GitHub Copilot CLI via ⌘V, Claude
        // Code via Ctrl-V) can consume the screenshot too.
        loadPasteboard(path)

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
        let script = iterm2InjectionScript(text: path, autoReturn: autoReturn(), autoFocus: autoFocus())
        diagnostic("injection.iterm2", .info, path, nil, nil)
        if verboseDiagnostics() {
            diagnostic("injection.iterm2.script", .info, nil, script, nil)
        }
        return runAppleScript(script)
    }

    func injectViaGenericAppleScript(_ path: String, bundleID: String) -> Bool {
        return runAppleScript(
            genericInjectionScript(text: path, bundleID: bundleID, autoReturn: autoReturn()))
    }

    public func focusTerminal(bundleID: String) {
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
                diagnostic("applescript.error", .error, nil, nil, "\(err)")
                return false
            }
            if verboseDiagnostics() {
                diagnostic("applescript.result", .info, result.stringValue ?? "(none)", nil, nil)
            }
            return true
        }
        diagnostic("applescript.unavailable", .error, nil, nil, nil)
        return false
    }

    public func showNotification(title: String, body: String) {
        guard notificationsEnabled() else { return }
        runAppleScript(notificationScript(title: title, body: body))
    }
}
