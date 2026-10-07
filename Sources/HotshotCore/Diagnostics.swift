import Foundation

/// Set to enable verbose local diagnostics that may include screenshot
/// directory paths, filenames, generated AppleScript, or clipboard text.
/// Diagnostics stay local-only either way; this only widens what appears
/// in NSLog/stderr for debugging (see issue #77).
public let VERBOSE_LOGGING_ENV_VAR = "HOTSHOT_VERBOSE_LOGGING"

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

/// The closed set of stable diagnostic event names. Every `diagnosticLine`
/// call site uses one of these (directly via `rawValue`, or as the matching
/// string literal passed to a `diagnostic` seam), so log filters can rely on
/// a bounded, lowercase dotted vocabulary. Add a case here before emitting a
/// new event; `DiagnosticEventTests` enforces this.
public enum DiagnosticEvent: String, CaseIterable {
    case appLaunched = "app.launched"

    case targetSeeded = "target.seeded"
    case targetFoundRunning = "target.found_running"
    case targetChanged = "target.changed"

    case clipboardWatchStarted = "clipboard.watch_started"
    case clipboardWatchStopped = "clipboard.watch_stopped"
    case clipboardImageDetected = "clipboard.image_detected"
    case clipboardManualInject = "clipboard.manual_inject"
    case clipboardUntrustedRefused = "clipboard.untrusted_refused"
    case clipboardNoTerminal = "clipboard.no_terminal"
    case clipboardSaveFailed = "clipboard.save_failed"

    case pasteboardLoaded = "pasteboard.loaded"
    case pasteboardReadFailed = "pasteboard.read_failed"
    case pasteboardWriteFailed = "pasteboard.write_failed"
    case pasteboardPNGConversionFailed = "pasteboard.png_conversion_failed"

    case screenshotInjectLast = "screenshot.inject_last"
    case screenshotNoTerminal = "screenshot.no_terminal"
    case screenshotLocationLookupFailed = "screenshot.location_lookup_failed"

    case watcherStarted = "watcher.started"
    case watcherStopped = "watcher.stopped"
    case watcherOpenFailed = "watcher.open_failed"
    case watcherDirectoryChange = "watcher.directory_change"
    case watcherNewFiles = "watcher.new_files"
    case watcherNewScreenshot = "watcher.new_screenshot"
    case watcherQuarantinedSkipped = "watcher.quarantined_skipped"

    case terminalTTYUnknown = "terminal.tty_unknown"
    case terminalCLIDetected = "terminal.cli_detected"

    case injectionCtrlV = "injection.ctrl_v"
    case injectionITerm2 = "injection.iterm2"
    case injectionITerm2Script = "injection.iterm2.script"
    case injectionControlCharsRefused = "injection.control_chars_refused"
    case injectionShellMetacharsRefused = "injection.shell_metachars_refused"

    case appleScriptResult = "applescript.result"
    case appleScriptError = "applescript.error"
    case appleScriptUnavailable = "applescript.unavailable"
}
