import HotshotCore
import XCTest

@testable import HotshotApp

/// Covers the target-tracking decisions extracted from the app delegate in
/// #143. Window titles, running-app lookup, the menu label and diagnostics
/// are recording closures, so no AX API, workspace or menu is touched.
final class TargetTrackerTests: XCTestCase {
    private let terminal = "com.googlecode.iterm2"
    private var titles: [pid_t: String] = [:]
    private var running: Set<pid_t> = []
    private var hasLabel = true
    private var verbose = false
    private var labels: [String] = []
    private var events: [(event: String, detail: String?)] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        titles = [:]
        running = []
        hasLabel = true
        verbose = false
        labels = []
        events = []
    }

    private func makeTracker() -> TargetTracker {
        TargetTracker(
            windowTitle: { [unowned self] pid in self.titles[pid] },
            isRunning: { [unowned self] pid in self.running.contains(pid) },
            hasTargetLabel: { [unowned self] in self.hasLabel },
            setTargetLabel: { [unowned self] title in self.labels.append(title) },
            verbose: { [unowned self] in self.verbose },
            diagnostic: { [unowned self] event, detail in self.events.append((event, detail)) },
            terminalBundleIDs: [terminal])
    }

    func testStartsWithNoTarget() {
        let tracker = makeTracker()
        XCTAssertNil(tracker.bundleID)
        XCTAssertNil(tracker.pid)
        XCTAssertNil(tracker.name)
    }

    func testDefaultsUseRealTerminalSetAndSilentSeams() {
        let tracker = TargetTracker(
            windowTitle: { _ in nil }, isRunning: { _ in true }, hasTargetLabel: { true },
            setTargetLabel: { _ in })
        XCTAssertTrue(
            tracker.appDidActivate(bundleID: "com.apple.Terminal", pid: 1, localizedName: "Terminal"))
        XCTAssertFalse(
            tracker.appDidActivate(bundleID: "com.apple.Safari", pid: 2, localizedName: "Safari"))
        XCTAssertEqual(tracker.bundleID, "com.apple.Terminal")
    }

    // MARK: - setTarget

    func testSetTargetPrefersWindowTitle() {
        titles[42] = "vim — project"
        let tracker = makeTracker()
        tracker.setTarget(bundleID: terminal, pid: 42, localizedName: "iTerm2")
        XCTAssertEqual(tracker.bundleID, terminal)
        XCTAssertEqual(tracker.pid, 42)
        XCTAssertEqual(tracker.name, "vim — project")
    }

    func testSetTargetFallsBackToLocalizedNameThenUnknown() {
        let tracker = makeTracker()
        tracker.setTarget(bundleID: terminal, pid: 42, localizedName: "iTerm2")
        XCTAssertEqual(tracker.name, "iTerm2")
        tracker.setTarget(bundleID: nil, pid: 43, localizedName: nil)
        XCTAssertNil(tracker.bundleID)
        XCTAssertEqual(tracker.pid, 43)
        XCTAssertEqual(tracker.name, "unknown")
    }

    // MARK: - refreshTargetLabel

    func testRefreshWithoutLabelItemDoesNothing() {
        let tracker = makeTracker()
        tracker.setTarget(bundleID: terminal, pid: 42, localizedName: "iTerm2")
        hasLabel = false
        running = [42]
        titles[42] = "new title"
        tracker.refreshTargetLabel()
        XCTAssertTrue(labels.isEmpty)
        XCTAssertEqual(tracker.name, "iTerm2")
    }

    func testRefreshWithoutTrackedPidDoesNothing() {
        makeTracker().refreshTargetLabel()
        XCTAssertTrue(labels.isEmpty)
    }

    func testRefreshAdoptsNonEmptyLiveTitle() {
        let tracker = makeTracker()
        tracker.setTarget(bundleID: terminal, pid: 42, localizedName: "iTerm2")
        running = [42]
        titles[42] = "ssh prod"
        tracker.refreshTargetLabel()
        XCTAssertEqual(tracker.name, "ssh prod")
        XCTAssertEqual(labels, ["Target: ssh prod"])
    }

    func testRefreshKeepsOldNameWhenLiveTitleEmpty() {
        let tracker = makeTracker()
        tracker.setTarget(bundleID: terminal, pid: 42, localizedName: "iTerm2")
        running = [42]
        titles[42] = ""
        tracker.refreshTargetLabel()
        XCTAssertEqual(tracker.name, "iTerm2")
        XCTAssertEqual(labels, ["Target: iTerm2"])
    }

    func testRefreshKeepsOldNameWhenNoLiveTitle() {
        let tracker = makeTracker()
        tracker.setTarget(bundleID: terminal, pid: 42, localizedName: "iTerm2")
        running = [42]
        tracker.refreshTargetLabel()
        XCTAssertEqual(labels, ["Target: iTerm2"])
    }

    func testRefreshIgnoresTitleWhenAppNoLongerRunning() {
        let tracker = makeTracker()
        tracker.setTarget(bundleID: terminal, pid: 42, localizedName: "iTerm2")
        titles[42] = "stale"
        tracker.refreshTargetLabel()
        XCTAssertEqual(tracker.name, "iTerm2")
        XCTAssertEqual(labels, ["Target: iTerm2"])
    }

    // MARK: - appDidActivate

    func testNonTerminalActivationIsIgnored() {
        let tracker = makeTracker()
        XCTAssertFalse(
            tracker.appDidActivate(bundleID: "com.apple.Safari", pid: 7, localizedName: "Safari"))
        XCTAssertNil(tracker.bundleID)
        XCTAssertNil(tracker.pid)
        XCTAssertTrue(labels.isEmpty)
        XCTAssertTrue(events.isEmpty)
    }

    func testActivationWithoutBundleIDIsIgnored() {
        let tracker = makeTracker()
        tracker.setTarget(bundleID: terminal, pid: 42, localizedName: "iTerm2")
        XCTAssertFalse(tracker.appDidActivate(bundleID: nil, pid: 7, localizedName: "helper"))
        XCTAssertEqual(tracker.bundleID, terminal)
        XCTAssertEqual(tracker.pid, 42)
        XCTAssertTrue(events.isEmpty)
    }

    func testTerminalActivationSetsTargetRefreshesLabelAndLogsRedacted() {
        running = [42]
        titles[42] = "zsh"
        let tracker = makeTracker()
        XCTAssertTrue(tracker.appDidActivate(bundleID: terminal, pid: 42, localizedName: "iTerm2"))
        XCTAssertEqual(tracker.bundleID, terminal)
        XCTAssertEqual(tracker.pid, 42)
        XCTAssertEqual(tracker.name, "zsh")
        XCTAssertEqual(labels, ["Target: zsh"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, DiagnosticEvent.targetChanged.rawValue)
        XCTAssertEqual(events.first?.detail, "<redacted>")
    }

    func testTerminalActivationLogsNameWhenVerbose() {
        verbose = true
        let tracker = makeTracker()
        tracker.appDidActivate(bundleID: terminal, pid: 42, localizedName: "iTerm2")
        XCTAssertEqual(events.first?.detail, "iTerm2")
    }

    func testTerminalActivationWithoutNamesLogsUnknown() {
        verbose = true
        let tracker = makeTracker()
        tracker.appDidActivate(bundleID: terminal, pid: 42, localizedName: nil)
        XCTAssertEqual(tracker.name, "unknown")
        XCTAssertEqual(labels, ["Target: unknown"])
        XCTAssertEqual(events.first?.detail, "unknown")
    }

    // MARK: - menuWillOpen

    func testMenuWillOpenSeedsWhenNoTargetTracked() {
        let tracker = makeTracker()
        var seeds = 0
        tracker.menuWillOpen {
            seeds += 1
            tracker.setTarget(bundleID: self.terminal, pid: 42, localizedName: "iTerm2")
        }
        XCTAssertEqual(seeds, 1)
        XCTAssertEqual(labels, ["Target: iTerm2"])
    }

    func testMenuWillOpenDoesNotSeedWhenTargetTracked() {
        let tracker = makeTracker()
        tracker.setTarget(bundleID: terminal, pid: 42, localizedName: "iTerm2")
        var seeds = 0
        tracker.menuWillOpen { seeds += 1 }
        XCTAssertEqual(seeds, 0)
        XCTAssertEqual(labels, ["Target: iTerm2"])
    }

    func testMenuWillOpenWithFailedSeedLeavesLabelUntouched() {
        let tracker = makeTracker()
        var seeds = 0
        tracker.menuWillOpen { seeds += 1 }
        XCTAssertEqual(seeds, 1)
        XCTAssertNil(tracker.bundleID)
        XCTAssertTrue(labels.isEmpty)
    }
}
