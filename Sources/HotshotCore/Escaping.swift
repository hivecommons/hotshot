import Foundation

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

/// Characters that make a typed word run or redirect when a POSIX shell
/// reads it: command substitution (`$`, backtick), command separators
/// (`;`, `|`, `&`), redirections (`<`, `>`) and history expansion (`!`,
/// which bash and zsh rewrite mid-word into the previous command line —
/// separators included — before parsing). None of them appear in macOS's
/// own screenshot names.
let SHELL_COMMAND_METACHARACTERS: Set<Character> = ["$", "`", ";", "|", "&", "<", ">", "!"]

/// True when the string contains a character from
/// `SHELL_COMMAND_METACHARACTERS`. The bracketed `[path] ` form types the
/// path verbatim, and `resolveTargetCLI` falls back to it whenever the
/// focused session cannot be inspected (every terminal other than
/// iTerm2/Terminal.app, or no known CLI running), so the text may land on
/// a plain shell prompt. With Auto-Return on, a foreign file dropped into
/// the watched folder named `` `cmd`.png `` or `a;cmd;.png` would then be
/// executed, and one named `!!.png` would replay the previous command line
/// via history expansion, so such paths are refused rather than typed
/// unescaped.
public func containsShellCommandMetacharacters(_ s: String) -> Bool {
    s.contains { SHELL_COMMAND_METACHARACTERS.contains($0) }
}

public func typedScreenshotText(path: String, targetCLI: TargetCLI) -> String? {
    guard !containsControlCharacters(path) else { return nil }
    switch targetCLI {
    case .plainPath:
        return shellEscapedPath(path) + " "
    case .claude:
        guard !containsShellCommandMetacharacters(path) else { return nil }
        return "[\(path)] "
    }
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
