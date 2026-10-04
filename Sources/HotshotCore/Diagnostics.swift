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
