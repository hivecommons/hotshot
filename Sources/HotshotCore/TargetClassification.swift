import Foundation

public let TERMINAL_BUNDLE_IDS: Set<String> = [
    "com.googlecode.iterm2",
    "com.apple.Terminal",
    "net.kovidgoyal.kitty",
    "io.alacritty",
    "dev.warp.Warp-Stable",
    "com.mitchellh.ghostty",
]

public enum TargetCLI: Equatable {
    case claude  // expects "[path] " bracketed form
    case plainPath  // GitHub Copilot CLI, aider, ... expect a bare escaped path
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

/// Split `ps -t <tty> -o command=` output into one command per line,
/// dropping empty lines (mirrors `String.split`, which omits empties).
public func parsePSOutput(_ output: String) -> [String] {
    output.split(separator: "\n").map(String.init)
}
