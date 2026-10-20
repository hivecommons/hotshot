import Foundation

public let REFOCUS_DELAY_SECONDS = 0.3

/// Result a System Events script returns instead of typing when the target
/// terminal did not come to the front (parity with the Linux and Windows
/// ports' `injection.focus_lost`). `TerminalInjector` turns it into a
/// refusal so keystrokes never land in whichever app happens to be focused.
public let FOCUS_LOST_RESULT = "focus_lost"

/// AppleScript line that aborts a System Events script with
/// `FOCUS_LOST_RESULT` unless a process with `bundleID` is frontmost.
/// `activate` is asynchronous and may be deferred or refused by macOS, the
/// user may switch apps during the refocus delay, and a quit terminal is
/// relaunched rather than focused, so the frontmost state is re-read right
/// before the keystrokes rather than assumed. Must be emitted inside a
/// `tell application "System Events"` block.
func focusGuardLine(bundleID: String) -> String {
    "if (count of (application processes whose bundle identifier is \"\(bundleID)\" and frontmost is true)) is 0 then return \"\(FOCUS_LOST_RESULT)\""
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
/// NSRunningApplication and is interpolated as-is. The script returns
/// `FOCUS_LOST_RESULT` without typing when that app is not frontmost after
/// the refocus delay.
public func genericInjectionScript(text: String, bundleID: String, autoReturn: Bool) -> String {
    let escaped = appleScriptEscaped(text)
    var script = """
        tell application id "\(bundleID)"
            activate
        end tell
        delay \(REFOCUS_DELAY_SECONDS)
        tell application "System Events"
            \(focusGuardLine(bundleID: bundleID))
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
/// Returns `FOCUS_LOST_RESULT` without pressing anything when that app is
/// not frontmost after the refocus delay.
public func ctrlVScript(bundleID: String) -> String {
    """
    tell application id "\(bundleID)"
        activate
    end tell
    delay \(REFOCUS_DELAY_SECONDS)
    tell application "System Events"
        \(focusGuardLine(bundleID: bundleID))
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
