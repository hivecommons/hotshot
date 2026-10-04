import Foundation

public let REFOCUS_DELAY_SECONDS = 0.3

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
