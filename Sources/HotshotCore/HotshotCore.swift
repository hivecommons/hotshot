import Foundation

// MARK: - Constants

public let TERMINAL_BUNDLE_IDS: Set<String> = [
    "com.googlecode.iterm2",
    "com.apple.Terminal",
    "net.kovidgoyal.kitty",
    "io.alacritty",
    "dev.warp.Warp-Stable",
    "com.mitchellh.ghostty",
]

public let REFOCUS_DELAY_SECONDS = 0.3

// MARK: - Preferences keys

public let PREF_AUTO_FOCUS = "hotshotAutoFocus"
public let PREF_AUTO_RETURN = "hotshotAutoReturn"
public let PREF_NOTIFICATIONS = "hotshotNotifications"
public let PREF_AUTO_WATCH = "hotshotAutoWatch"
public let PREF_CLIPBOARD_WATCH = "hotshotClipboardWatch"
public let SCREENSHOT_EXTENSIONS: Set<String> = ["png", "jpg", "jpeg", "tiff", "bmp", "gif", "webp"]
public let WATCH_DEBOUNCE_SECONDS = 1.5
public let WATCH_FILE_AGE_MAX_SECONDS = 10.0
public let CLIPBOARD_POLL_INTERVAL_SECONDS = 0.5
public let PREF_SCREENSHOT_DIR = "hotshotScreenshotDir"

/// Set to enable verbose local diagnostics that may include screenshot
/// directory paths, filenames, generated AppleScript, or clipboard text.
/// Diagnostics stay local-only either way; this only widens what appears
/// in NSLog/stderr for debugging (see issue #77).
public let VERBOSE_LOGGING_ENV_VAR = "HOTSHOT_VERBOSE_LOGGING"

// MARK: - Diagnostic logging

/// Stable severities for local diagnostic lines, independent of the
/// human-readable event text so failures stay filterable/identifiable.
public enum DiagnosticSeverity: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// True when verbose local diagnostics were explicitly requested via
/// `HOTSHOT_VERBOSE_LOGGING=1`. Verbose mode is local-only (no exporter or
/// network flow is introduced) and should be documented as potentially
/// containing local paths, filenames, generated scripts, or clipboard text.
public func verboseDiagnosticsEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    environment[VERBOSE_LOGGING_ENV_VAR] == "1"
}

/// Redact a value that may reveal screenshot directory paths, filenames,
/// generated AppleScript, or clipboard text so it never appears in normal
/// diagnostics. Returns the raw value unchanged only when `verbose` is true.
public func redacted(_ value: @autoclosure () -> String, verbose: Bool) -> String {
    verbose ? value() : "<redacted>"
}

/// Format a stable, bounded diagnostic line of the form
/// "Hotshot [SEVERITY] event.name: detail" so common capture, clipboard,
/// watcher, and injection failures stay identifiable by event name and
/// severity even though `detail` is redacted by default. Pass an already
/// redacted (or non-sensitive) `detail`.
public func diagnosticLine(
    event: String,
    severity: DiagnosticSeverity = .info,
    detail: String? = nil
) -> String {
    guard let detail, !detail.isEmpty else {
        return "Hotshot [\(severity.rawValue)] \(event)"
    }
    return "Hotshot [\(severity.rawValue)] \(event): \(detail)"
}

// MARK: - Preferences storage

/// Backs a `Bool` property with a `UserDefaults` value stored under `key`,
/// falling back to `defaultValue` when the key has never been set.
/// Collapses the five near-identical get/set pairs in `HotshotApp` into
/// one-line declarations.
@propertyWrapper
public struct UserDefault {
    public let key: String
    public let defaultValue: Bool

    public init(_ key: String, defaultValue: Bool) {
        self.key = key
        self.defaultValue = defaultValue
    }

    public var wrappedValue: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

public func normalizedMacOSScreenshotLocation(_ path: String?) -> String? {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
        return nil
    }
    return (path as NSString).expandingTildeInPath
}

public func macOSScreenshotLocation() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    task.arguments = ["read", "com.apple.screencapture", "location"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = normalizedMacOSScreenshotLocation(String(data: data, encoding: .utf8)) {
            return path
        }
    } catch {}
    return NSHomeDirectory() + "/Desktop"
}

public func findMostRecentScreenshot(in dir: String) -> String? {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

    var newest: String?
    var newestDate = Date.distantPast

    for file in files {
        guard !isHiddenScreenshotFileName(file) else { continue }
        let ext = (file as NSString).pathExtension.lowercased()
        guard SCREENSHOT_EXTENSIONS.contains(ext) else { continue }
        let fullPath = (dir as NSString).appendingPathComponent(file)
        guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
              let modified = attrs[.modificationDate] as? Date else { continue }
        if modified > newestDate {
            newestDate = modified
            newest = fullPath
        }
    }
    return newest
}

public func snapshotScreenshotFiles(in dir: String) -> Set<String> {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    var result = Set<String>()
    for file in files {
        guard !isHiddenScreenshotFileName(file) else { continue }
        let ext = (file as NSString).pathExtension.lowercased()
        if SCREENSHOT_EXTENSIONS.contains(ext) {
            result.insert(file)
        }
    }
    return result
}

public struct ScreenshotFileCandidate: Equatable {
    public let fileName: String
    public let modifiedAt: Date

    public init(fileName: String, modifiedAt: Date) {
        self.fileName = fileName
        self.modifiedAt = modifiedAt
    }
}

public func newScreenshotFiles(previous: Set<String>, current: Set<String>) -> Set<String> {
    current.subtracting(previous)
}

/// True for dotfile names. macOS writes a capture to the screenshot folder
/// as a hidden `.Screenshot … .png` while the floating thumbnail is shown
/// and renames it to the visible name when the thumbnail dismisses, so a
/// hidden name is an in-progress capture whose path is about to vanish and
/// must never be snapshotted, injected, or treated as the last screenshot.
public func isHiddenScreenshotFileName(_ name: String) -> Bool {
    name.hasPrefix(".")
}

/// Build candidates for newly seen files, skipping any whose modification
/// date cannot be read (e.g. the file vanished between snapshot and lookup).
public func screenshotCandidates(
    for fileNames: Set<String>,
    directory: String,
    modificationDate: (String) -> Date?
) -> [ScreenshotFileCandidate] {
    fileNames.compactMap { file in
        let fullPath = (directory as NSString).appendingPathComponent(file)
        return modificationDate(fullPath).map { ScreenshotFileCandidate(fileName: file, modifiedAt: $0) }
    }
}

public func newestInjectableScreenshot(
    from candidates: [ScreenshotFileCandidate],
    directory: String,
    now: Date = Date(),
    maxAge: TimeInterval = WATCH_FILE_AGE_MAX_SECONDS
) -> String? {
    let newest = candidates
        .filter { !$0.fileName.hasPrefix("hotshot-") }
        .filter { !isHiddenScreenshotFileName($0.fileName) }
        .filter { now.timeIntervalSince($0.modifiedAt) < maxAge }
        .max { $0.modifiedAt < $1.modifiedAt }
    guard let newest else { return nil }
    return (directory as NSString).appendingPathComponent(newest.fileName)
}

/// Backslash-escape a path the way Terminal does on drag-and-drop, so
/// CLIs that parse bare paths (GitHub Copilot CLI, aider, ...) accept it.
/// Claude Code accepts the same escaped form, so no brackets are needed.
public func shellEscapedPath(_ path: String) -> String {
    let specials: Set<Character> = [
        " ", "\t", "!", "\"", "#", "$", "&", "'", "(", ")", "*",
        ",", ";", "<", ">", "?", "[", "]", "\\", "^", "`", "{", "}", "|",
    ]
    var out = ""
    for ch in path {
        if specials.contains(ch) { out.append("\\") }
        out.append(ch)
    }
    return out
}

public enum TargetCLI: Equatable {
    case claude  // expects "[path] " bracketed form
    case plainPath  // GitHub Copilot CLI, aider, ... expect a bare escaped path
}

/// AppleScript expression returning the tty of the terminal's focused
/// session, per terminal app. Returns nil for terminals without
/// scriptable tty access.
public func ttyScript(forBundleID bid: String) -> String? {
    switch bid {
    case "com.googlecode.iterm2":
        return "tell application \"iTerm2\" to get tty of current session of current window"
    case "com.apple.Terminal":
        return "tell application \"Terminal\" to get tty of selected tab of front window"
    default:
        return nil
    }
}

/// Which AppleScript injection path a terminal bundle ID uses. iTerm2 gets
/// its own `write text` script (see `iterm2InjectionScript`); every other
/// terminal is typed via System Events (`genericInjectionScript`).
public enum InjectionTarget: Equatable {
    case iTerm2
    case generic
}

/// Decide the injection path for a terminal bundle ID. Pulled out of
/// `HotshotApp.injectPath` so the ctrl-v/iTerm2-vs-generic branching can be
/// unit-tested without executing AppleScript.
public func injectionTarget(forBundleID bid: String) -> InjectionTarget {
    switch bid {
    case "com.googlecode.iterm2":
        return .iTerm2
    default:
        return .generic
    }
}

/// Classify the commands running on a tty. Claude wins ties since the
/// bracketed form was hotshot's historical default.
public func classifyCommands(_ commands: [String]) -> TargetCLI? {
    var sawPlainPathCLI = false
    for cmd in commands {
        for token in cmd.split(separator: " ") {
            let name = (String(token) as NSString).lastPathComponent.lowercased()
            if name == "claude" { return .claude }
            if name == "copilot" || name == "aider" || name == "opencode" {
                sawPlainPathCLI = true
            }
        }
    }
    return sawPlainPathCLI ? .plainPath : nil
}

/// Resolve which CLI is running in a terminal's focused session from an
/// already-fetched tty path (or nil/empty when it could not be determined),
/// deferring only the `ps` lookup to `commandsForTTY`. Falls back to
/// `.claude` when the tty is unknown or no known CLI is running, matching
/// `HotshotApp`'s historical default. Pulled out of `HotshotApp.detectTargetCLI`
/// so the tty-to-CLI decision can be unit-tested with a fake `commandsForTTY`
/// instead of shelling out to `ps`.
public func resolveTargetCLI(
    ttyPath: String?,
    commandsForTTY: (String) -> [String]
) -> TargetCLI {
    guard let ttyPath, !ttyPath.isEmpty else { return .claude }
    let tty = (ttyPath as NSString).lastPathComponent
    return classifyCommands(commandsForTTY(tty)) ?? .claude
}

/// True when the string contains control characters (U+0000–U+001F, U+007F)
/// or Unicode line/paragraph separators. macOS filenames may contain CR/LF;
/// typing such a name into a terminal presses Return mid-string, so paths
/// containing these characters must never be injected.
public func containsControlCharacters(_ s: String) -> Bool {
    for scalar in s.unicodeScalars {
        if scalar.value < 0x20 || scalar.value == 0x7F
            || scalar.value == 0x2028 || scalar.value == 0x2029
        {
            return true
        }
    }
    return false
}

public func typedScreenshotText(path: String, targetCLI: TargetCLI) -> String? {
    guard !containsControlCharacters(path) else { return nil }
    switch targetCLI {
    case .plainPath:
        return shellEscapedPath(path) + " "
    case .claude:
        return "[\(path)] "
    }
}

/// Decide whether text already on the clipboard can be trusted as the
/// enriched plain-text path accompanying a clipboard image. Only hotshot's
/// own enrichment qualifies: the text must be free of control characters
/// (so a Ctrl-V paste can never press Return or emit escape sequences) and,
/// once the drag-and-drop backslash escapes are removed, name an existing
/// `hotshot-*.png` file directly inside `screenshotDirectory` — the only
/// shape `writePasteboard` ever produces. Any other text (including paths
/// to unrelated existing files an attacker can predict, like /etc/passwd)
/// is untrusted, so the caller rewrites the pasteboard before any paste.
public func trustedEnrichedClipboardPath(
    _ text: String?,
    screenshotDirectory: String,
    fileExists: (String) -> Bool
) -> String? {
    guard let text, !containsControlCharacters(text) else { return nil }
    let unescaped = text.replacingOccurrences(of: "\\", with: "")
    let dir = ((screenshotDirectory as NSString).expandingTildeInPath as NSString)
        .standardizingPath
    let parent = ((unescaped as NSString).deletingLastPathComponent as NSString)
        .standardizingPath
    let name = (unescaped as NSString).lastPathComponent
    guard parent == dir,
        name.hasPrefix("hotshot-"),
        name.lowercased().hasSuffix(".png"),
        fileExists(unescaped)
    else { return nil }
    return text
}

/// What to do with the clipboard when an image lands on it.
public enum ClipboardEnrichmentDecision: Equatable {
    /// Already carries a PNG plus a trusted existing path; use this path as-is.
    case alreadyEnriched(path: String)
    /// Save the image to disk and rewrite the pasteboard.
    case saveAndRewrite
}

/// Decide whether the clipboard is already enriched. Untrusted text is never
/// reused, so a Ctrl-V paste cannot type attacker-controlled clipboard text.
public func clipboardEnrichmentDecision(
    hasPNG: Bool,
    text: String?,
    screenshotDirectory: String,
    fileExists: (String) -> Bool
) -> ClipboardEnrichmentDecision {
    guard hasPNG,
        let existing = trustedEnrichedClipboardPath(
            text, screenshotDirectory: screenshotDirectory, fileExists: fileExists)
    else {
        return .saveAndRewrite
    }
    return .alreadyEnriched(path: existing)
}

/// Escape a string for embedding in an AppleScript double-quoted literal.
/// Backslashes must be escaped first so shell-escaped paths survive intact.
/// CR/LF/TAB become AppleScript escapes and any remaining control character
/// is dropped, so untrusted text can never break out of the literal or emit
/// a Return keystroke.
public func appleScriptEscaped(_ s: String) -> String {
    let base = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
    var out = String.UnicodeScalarView()
    for scalar in base.unicodeScalars
    where !(scalar.value < 0x20 || scalar.value == 0x7F
        || scalar.value == 0x2028 || scalar.value == 0x2029)
    {
        out.append(scalar)
    }
    return String(out)
}

// MARK: - AppleScript source builders

/// AppleScript that writes `text` into iTerm2's current session.
/// `text` is escaped here so it can never break out of the quoted literal.
public func iterm2InjectionScript(text: String, autoReturn: Bool, autoFocus: Bool) -> String {
    let escaped = appleScriptEscaped(text)
    var script: String
    if autoReturn {
        script = """
            tell application "iTerm2"
                tell current session of current window
                    write text "\(escaped)"
                end tell
            end tell
            """
    } else {
        script = """
            tell application "iTerm2"
                tell current session of current window
                    write text "\(escaped)" newline NO
                end tell
            end tell
            """
    }
    if autoFocus {
        script += """

            tell application "iTerm2" to activate
            """
    }
    return script
}

/// AppleScript that focuses the app with `bundleID` and types `text` via
/// System Events. `text` is escaped here; `bundleID` comes from
/// NSRunningApplication and is interpolated as-is.
public func genericInjectionScript(text: String, bundleID: String, autoReturn: Bool) -> String {
    let escaped = appleScriptEscaped(text)
    var script = """
        tell application id "\(bundleID)"
            activate
        end tell
        delay \(REFOCUS_DELAY_SECONDS)
        tell application "System Events"
            keystroke "\(escaped)"
        """
    if autoReturn {
        script += """

            keystroke return
        """
    }
    script += """

        end tell
        """
    return script
}

/// AppleScript that focuses the app with `bundleID` and presses Ctrl-V.
public func ctrlVScript(bundleID: String) -> String {
    """
    tell application id "\(bundleID)"
        activate
    end tell
    delay \(REFOCUS_DELAY_SECONDS)
    tell application "System Events"
        keystroke "v" using {control down}
    end tell
    """
}

/// AppleScript for a user notification; title and body are escaped here.
public func notificationScript(title: String, body: String) -> String {
    """
    display notification "\(appleScriptEscaped(body))" with title "\(appleScriptEscaped(title))"
    """
}

// MARK: - Screenshot save path

/// Path under `directory` where a clipboard image is saved before injection.
/// The `hotshot-` prefix is a contract with `newestInjectableScreenshot`,
/// which skips such files so the watcher never re-injects its own output.
public func screenshotSavePath(directory: String, date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return (directory as NSString).appendingPathComponent(
        "hotshot-\(formatter.string(from: date)).png")
}

// MARK: - ps output parsing

/// Split `ps -t <tty> -o command=` output into one command per line,
/// dropping empty lines (mirrors `String.split`, which omits empties).
public func parsePSOutput(_ output: String) -> [String] {
    output.split(separator: "\n").map(String.init)
}
