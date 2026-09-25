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
        let ext = (file as NSString).pathExtension.lowercased()
        if SCREENSHOT_EXTENSIONS.contains(ext) {
            result.insert(file)
        }
    }
    return result
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

/// Escape a string for embedding in an AppleScript double-quoted literal.
/// Backslashes must be escaped first so shell-escaped paths survive intact.
public func appleScriptEscaped(_ s: String) -> String {
    return s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
