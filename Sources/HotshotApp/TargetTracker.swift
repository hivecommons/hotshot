import Foundation
import HotshotCore

/// Owns the tracked-terminal state and the target-tracking decisions
/// extracted from the app delegate: which activations change the target,
/// when the live window title replaces the remembered name, and when the
/// menu-open fallback seeds a target. Window-title lookup, running-app
/// lookup, the menu label and diagnostics are closure seams, the same
/// pattern as `InjectionCoordinator`.
public final class TargetTracker {
    public private(set) var bundleID: String?
    public private(set) var pid: pid_t?
    public private(set) var name: String?

    public typealias Diagnostic = (_ event: String, _ detail: String?) -> Void

    private let windowTitle: (pid_t) -> String?
    private let isRunning: (pid_t) -> Bool
    private let hasTargetLabel: () -> Bool
    private let setTargetLabel: (String) -> Void
    private let verbose: () -> Bool
    private let diagnostic: Diagnostic
    private let terminalBundleIDs: Set<String>

    /// - Parameters:
    ///   - windowTitle: focused-window title of the app with this pid, or nil.
    ///   - isRunning: whether an app with this pid is currently running.
    ///   - hasTargetLabel: whether the menu's target item exists.
    ///   - setTargetLabel: set the menu's target item title.
    ///   - verbose: whether diagnostics may include the terminal name.
    ///   - diagnostic: emit a diagnostic line (event, already-redacted detail).
    public init(
        windowTitle: @escaping (pid_t) -> String?,
        isRunning: @escaping (pid_t) -> Bool,
        hasTargetLabel: @escaping () -> Bool,
        setTargetLabel: @escaping (String) -> Void,
        verbose: @escaping () -> Bool = { false },
        diagnostic: @escaping Diagnostic = { _, _ in },
        terminalBundleIDs: Set<String> = TERMINAL_BUNDLE_IDS
    ) {
        self.windowTitle = windowTitle
        self.isRunning = isRunning
        self.hasTargetLabel = hasTargetLabel
        self.setTargetLabel = setTargetLabel
        self.verbose = verbose
        self.diagnostic = diagnostic
        self.terminalBundleIDs = terminalBundleIDs
    }

    /// Track an app as the terminal target, naming it by its window title
    /// (if non-empty), else its localized name, else "unknown".
    public func setTarget(bundleID: String?, pid: pid_t, localizedName: String?) {
        self.bundleID = bundleID
        self.pid = pid
        let title = windowTitle(pid)
        name = (title?.isEmpty == false ? title : nil) ?? localizedName ?? "unknown"
    }

    /// Refresh the menu's target label. The remembered name is replaced by
    /// the live window title only when the app is still running and the
    /// title is non-empty. No-op without a label item or a tracked pid.
    public func refreshTargetLabel() {
        guard hasTargetLabel() else { return }
        guard let pid = pid else { return }
        if isRunning(pid), let title = windowTitle(pid), !title.isEmpty {
            name = title
        }
        setTargetLabel(MenuModel.targetTitle(name))
    }

    /// An app was activated. Only apps whose bundle ID is a known terminal
    /// become the target; activations without a bundle ID are ignored.
    /// Returns whether the target changed.
    @discardableResult
    public func appDidActivate(bundleID: String?, pid: pid_t, localizedName: String?) -> Bool {
        guard let bundleID, terminalBundleIDs.contains(bundleID) else { return false }
        setTarget(bundleID: bundleID, pid: pid, localizedName: localizedName)
        refreshTargetLabel()
        diagnostic(
            DiagnosticEvent.targetChanged.rawValue,
            redacted(name ?? "unknown", verbose: verbose()))
        return true
    }

    /// An app quit. When it is the tracked terminal the target is cleared so
    /// injection falls back to the no-target branch instead of relaunching
    /// it. Returns whether the target was cleared.
    @discardableResult
    public func appDidTerminate(pid terminatedPID: pid_t) -> Bool {
        guard let pid, pid == terminatedPID else { return false }
        let terminatedName = name ?? "unknown"
        clearTarget()
        diagnostic(
            DiagnosticEvent.targetTerminated.rawValue,
            redacted(terminatedName, verbose: verbose()))
        return true
    }

    /// The tracked terminal for injection, or nil when none is tracked or
    /// its process has quit (the stale target is dropped as a side effect).
    public func currentTarget() -> (bundleID: String, name: String?)? {
        dropTargetIfQuit()
        guard let bundleID else { return nil }
        return (bundleID, name)
    }

    /// Clear the target when its process is no longer running, so a missed
    /// terminate notification cannot leave a stale terminal tracked.
    private func dropTargetIfQuit() {
        if let pid, !isRunning(pid) {
            appDidTerminate(pid: pid)
        }
    }

    private func clearTarget() {
        bundleID = nil
        pid = nil
        name = nil
        if hasTargetLabel() {
            setTargetLabel(MenuModel.targetTitle(nil))
        }
    }

    /// The status-bar menu is about to open: drop the target if its process
    /// has quit, seed a target only when none is tracked, then refresh the
    /// label.
    public func menuWillOpen(seed: () -> Void) {
        dropTargetIfQuit()
        if bundleID == nil {
            seed()
        }
        refreshTargetLabel()
    }
}
