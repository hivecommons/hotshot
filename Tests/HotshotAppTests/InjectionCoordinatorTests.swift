import HotshotCore
import XCTest

@testable import HotshotApp

/// Covers the injection coordination extracted from the app delegate in
/// #120. Every collaborator is a recording closure, so no pasteboard,
/// AppleScript or running app is touched; the suite asserts which guard
/// fires first and that early exits call nothing downstream — in particular
/// that an un-enriched (untrusted) clipboard is never pasted.
final class InjectionCoordinatorTests: XCTestCase {
    private var calls: [String] = []
    private var notifications: [String] = []
    private var events: [(event: String, severity: DiagnosticSeverity, path: String?)] = []

    private let terminal = InjectionCoordinator.Target(
        bundleID: "com.googlecode.iterm2", name: "zsh")

    override func setUpWithError() throws {
        try super.setUpWithError()
        calls = []
        notifications = []
        events = []
    }

    private func makeCoordinator(
        target: InjectionCoordinator.Target?,
        enriched: String? = "/shots/clip.png",
        hasImage: Bool = true,
        latest: String? = "/shots/latest.png",
        injectResult: Bool = true,
        autoFocus: Bool = false
    ) -> InjectionCoordinator {
        InjectionCoordinator(
            target: { [weak self] in
                self?.calls.append("target")
                return target
            },
            enrichClipboard: { [weak self] in
                self?.calls.append("enrich")
                return enriched
            },
            hasClipboardImage: { [weak self] in
                self?.calls.append("hasImage")
                return hasImage
            },
            mostRecentScreenshot: { [weak self] dir in
                self?.calls.append("mostRecent:\(dir)")
                return latest
            },
            sendCtrlV: { [weak self] bid, name in
                self?.calls.append("sendCtrlV:\(bid):\(name ?? "nil")")
                return injectResult
            },
            injectPath: { [weak self] path, bid in
                self?.calls.append("injectPath:\(path):\(bid)")
                return injectResult
            },
            focusTerminal: { [weak self] bid in self?.calls.append("focus:\(bid)") },
            autoFocus: { autoFocus },
            notify: { [weak self] body in self?.notifications.append(body) },
            diagnostic: { [weak self] event, severity, path in
                self?.events.append((event, severity, path))
            })
    }

    private var downstreamCalls: [String] {
        calls.filter {
            $0.hasPrefix("sendCtrlV") || $0.hasPrefix("injectPath") || $0.hasPrefix("focus")
        }
    }

    // MARK: - clipboardImageDetected (handleClipboardImage)

    func testClipboardImageDetectedRefusesUntrustedClipboard() {
        let coordinator = makeCoordinator(target: terminal, enriched: nil, autoFocus: true)

        let outcome = coordinator.clipboardImageDetected(changeCount: 7)

        XCTAssertEqual(outcome, .untrustedClipboard)
        XCTAssertEqual(downstreamCalls, [], "untrusted clipboard must never be pasted")
        XCTAssertEqual(
            notifications, ["Clipboard image could not be saved \u{2014} auto-paste skipped"])
    }

    func testClipboardImageDetectedRefusesUntrustedClipboardBeforeTargetGuard() {
        let coordinator = makeCoordinator(target: nil, enriched: nil)

        XCTAssertEqual(coordinator.clipboardImageDetected(changeCount: 1), .untrustedClipboard)
        XCTAssertEqual(calls, ["enrich"])
    }

    func testClipboardImageDetectedWithoutTargetDoesNotPaste() {
        let coordinator = makeCoordinator(target: nil)

        XCTAssertEqual(coordinator.clipboardImageDetected(changeCount: 1), .noTarget)
        XCTAssertEqual(calls, ["enrich", "target"])
        XCTAssertEqual(
            notifications, ["Clipboard image detected but no terminal session tracked"])
    }

    func testClipboardImageDetectedSendsCtrlVToTarget() {
        let coordinator = makeCoordinator(target: terminal)

        let outcome = coordinator.clipboardImageDetected(changeCount: 1)

        XCTAssertEqual(outcome, .injected(successBody: "Clipboard image injected via Ctrl-V"))
        XCTAssertEqual(downstreamCalls, ["sendCtrlV:com.googlecode.iterm2:zsh"])
        XCTAssertEqual(notifications, ["Clipboard image injected via Ctrl-V"])
    }

    // MARK: - injectClipboardNow

    func testInjectClipboardNowWithoutTargetStopsFirst() {
        let coordinator = makeCoordinator(target: nil)

        XCTAssertEqual(coordinator.injectClipboardNow(), .noTarget)
        XCTAssertEqual(calls, ["target"])
        XCTAssertEqual(
            notifications, ["No terminal session tracked yet. Focus a terminal first."])
    }

    func testInjectClipboardNowWithoutImageStopsBeforeEnrich() {
        let coordinator = makeCoordinator(target: terminal, hasImage: false)

        XCTAssertEqual(coordinator.injectClipboardNow(), .noClipboardImage)
        XCTAssertEqual(calls, ["target", "hasImage"])
        XCTAssertEqual(notifications, ["No image on clipboard"])
    }

    func testInjectClipboardNowRefusesUntrustedClipboard() {
        let coordinator = makeCoordinator(target: terminal, enriched: nil, autoFocus: true)

        XCTAssertEqual(coordinator.injectClipboardNow(), .untrustedClipboard)
        XCTAssertEqual(calls, ["target", "hasImage", "enrich"])
        XCTAssertEqual(downstreamCalls, [], "untrusted clipboard must never be pasted")
        XCTAssertEqual(notifications, ["Could not save the clipboard image \u{2014} paste skipped"])
    }

    func testInjectClipboardNowSendsCtrlVAfterAllGuards() {
        let coordinator = makeCoordinator(target: terminal)

        let outcome = coordinator.injectClipboardNow()

        XCTAssertEqual(outcome, .injected(successBody: "Clipboard image injected via Ctrl-V"))
        XCTAssertEqual(
            calls, ["target", "hasImage", "enrich", "sendCtrlV:com.googlecode.iterm2:zsh"])
    }

    // MARK: - injectLastScreenshot

    func testInjectLastScreenshotWithoutTargetStopsFirst() {
        let coordinator = makeCoordinator(target: nil)

        XCTAssertEqual(coordinator.injectLastScreenshot(dir: "/shots"), .noTarget)
        XCTAssertEqual(calls, ["target"])
        XCTAssertEqual(
            notifications, ["No terminal session tracked yet. Focus a terminal first."])
    }

    func testInjectLastScreenshotWithEmptyDirectoryNeverInjects() {
        let coordinator = makeCoordinator(target: terminal, latest: nil)

        XCTAssertEqual(coordinator.injectLastScreenshot(dir: "/shots"), .noScreenshot(dir: "/shots"))
        XCTAssertEqual(downstreamCalls, [])
        XCTAssertEqual(notifications, ["No screenshot files found in /shots"])
        XCTAssertTrue(events.isEmpty)
    }

    func testInjectLastScreenshotInjectsLatestPath() {
        let coordinator = makeCoordinator(target: terminal)

        let outcome = coordinator.injectLastScreenshot(dir: "/shots")

        XCTAssertEqual(outcome, .injected(successBody: "Injected \u{2192} /shots/latest.png"))
        XCTAssertEqual(
            calls,
            [
                "target", "mostRecent:/shots",
                "injectPath:/shots/latest.png:com.googlecode.iterm2",
            ])
        XCTAssertEqual(events.map { $0.event }, ["screenshot.inject_last"])
        XCTAssertEqual(events.first?.severity, .info)
        XCTAssertEqual(events.first?.path, "/shots/latest.png")
    }

    // MARK: - newScreenshot (handleNewScreenshot)

    func testNewScreenshotWithoutTargetDoesNotInject() {
        let coordinator = makeCoordinator(target: nil, autoFocus: true)

        XCTAssertEqual(coordinator.newScreenshot("/shots/a.png"), .noTarget)
        XCTAssertEqual(downstreamCalls, [])
        XCTAssertEqual(notifications, ["Screenshot detected but no terminal session tracked"])
    }

    func testNewScreenshotInjectsPathAndReportsFilename() {
        let coordinator = makeCoordinator(target: terminal)

        let outcome = coordinator.newScreenshot("/shots/a.png")

        XCTAssertEqual(outcome, .injected(successBody: "Auto-injected \u{2192} a.png"))
        XCTAssertEqual(downstreamCalls, ["injectPath:/shots/a.png:com.googlecode.iterm2"])
        XCTAssertEqual(notifications, ["Auto-injected \u{2192} a.png"])
    }

    // MARK: - completeInjection

    func testCompleteInjectionFocusesOnlyWhenAutoFocusIsOn() {
        makeCoordinator(target: terminal, autoFocus: false).newScreenshot("/shots/a.png")
        XCTAssertFalse(calls.contains { $0.hasPrefix("focus") })

        calls = []
        makeCoordinator(target: terminal, autoFocus: true).newScreenshot("/shots/a.png")
        XCTAssertEqual(calls.last, "focus:com.googlecode.iterm2")
    }

    func testCompleteInjectionFailureUsesSharedFailedBody() {
        let coordinator = makeCoordinator(target: terminal, injectResult: false, autoFocus: true)

        XCTAssertEqual(coordinator.clipboardImageDetected(changeCount: 1), .failed)
        XCTAssertEqual(notifications, [INJECTION_FAILED_NOTIFICATION_BODY])
        XCTAssertTrue(calls.contains("focus:com.googlecode.iterm2"))
    }

    func testCompleteInjectionSuccessUsesSuccessBody() {
        let coordinator = makeCoordinator(target: terminal)

        XCTAssertEqual(
            coordinator.completeInjection(true, successBody: "ok", bundleID: "b"),
            .injected(successBody: "ok"))
        XCTAssertEqual(
            coordinator.completeInjection(false, successBody: "ok", bundleID: "b"), .failed)
        XCTAssertEqual(notifications, ["ok", INJECTION_FAILED_NOTIFICATION_BODY])
    }

    func testFailedBodyPointsAtAutomationPermission() {
        XCTAssertTrue(INJECTION_FAILED_NOTIFICATION_BODY.contains("Automation"))
    }

    // MARK: - seedCandidate (seedTargetFromRunningApps)

    private struct FakeApp: Equatable {
        let bundleID: String?
        var terminated = false
    }

    private func seed(frontmost: FakeApp?, running: [FakeApp])
        -> (app: FakeApp, source: InjectionCoordinator.SeedSource)?
    {
        InjectionCoordinator.seedCandidate(
            frontmost: frontmost, running: running,
            bundleID: { $0.bundleID }, isTerminated: { $0.terminated })
    }

    func testSeedPrefersFrontmostTerminal() {
        let front = FakeApp(bundleID: "com.apple.Terminal")
        let result = seed(
            frontmost: front, running: [FakeApp(bundleID: "com.googlecode.iterm2"), front])

        XCTAssertEqual(result?.app, front)
        XCTAssertEqual(result?.source, .frontmost)
    }

    func testSeedFallsBackToFirstRunningNonTerminatedTerminal() {
        let result = seed(
            frontmost: FakeApp(bundleID: "com.apple.Safari"),
            running: [
                FakeApp(bundleID: "com.apple.finder"),
                FakeApp(bundleID: "com.apple.Terminal", terminated: true),
                FakeApp(bundleID: nil),
                FakeApp(bundleID: "net.kovidgoyal.kitty"),
                FakeApp(bundleID: "com.googlecode.iterm2"),
            ])

        XCTAssertEqual(result?.app, FakeApp(bundleID: "net.kovidgoyal.kitty"))
        XCTAssertEqual(result?.source, .running)
    }

    func testSeedFallsBackWhenFrontmostHasNoBundleID() {
        let result = seed(
            frontmost: FakeApp(bundleID: nil), running: [FakeApp(bundleID: "com.apple.Terminal")])

        XCTAssertEqual(result?.source, .running)
    }

    func testSeedReturnsNilWhenNoTerminalIsRunning() {
        XCTAssertNil(
            seed(
                frontmost: FakeApp(bundleID: "com.apple.Safari"),
                running: [
                    FakeApp(bundleID: "com.apple.finder"),
                    FakeApp(bundleID: "com.apple.Terminal", terminated: true),
                ]))
        XCTAssertNil(seed(frontmost: nil, running: []))
    }

    // MARK: - diagnosticDetail (diag)

    func testDiagnosticDetailRedactsPathAndScriptUnlessVerbose() {
        XCTAssertEqual(
            diagnosticDetail(path: "/Users/me/shot.png", script: "tell app", verbose: false),
            "<redacted>, <redacted>")
        XCTAssertEqual(
            diagnosticDetail(path: "/Users/me/shot.png", script: "tell app", verbose: true),
            "/Users/me/shot.png, tell app")
    }

    func testDiagnosticDetailAlwaysShowsCountAndDetailInOrder() {
        XCTAssertEqual(
            diagnosticDetail(
                path: "/p", script: "s", count: 3, detail: "boom", verbose: false),
            "<redacted>, <redacted>, 3 file(s), boom")
        XCTAssertEqual(diagnosticDetail(count: 1, verbose: false), "1 file(s)")
        XCTAssertEqual(diagnosticDetail(detail: "-1743", verbose: false), "-1743")
    }

    func testDiagnosticDetailIsNilWhenEmpty() {
        XCTAssertNil(diagnosticDetail(verbose: false))
        XCTAssertNil(diagnosticDetail(verbose: true))
    }
}
