import XCTest

@testable import HotshotApp

/// Covers the status-bar menu decisions extracted from the app delegate in
/// #143: item order and titles, which pref drives each checkmark, the
/// target item's tag, the Save-to label, and which watcher a toggle
/// starts or stops.
final class MenuModelTests: XCTestCase {
    private let allOff = MenuPrefs(
        autoFocus: false, autoReturn: false, notifications: false, autoWatch: false,
        clipboardWatch: false)

    private func items(_ prefs: MenuPrefs, dir: String = "~/Desktop") -> [MenuModel.Item] {
        MenuModel.items(prefs: prefs, screenshotDir: dir)
    }

    private func item(_ action: MenuAction, in items: [MenuModel.Item]) -> MenuModel.Item? {
        items.first { $0.action == action }
    }

    // MARK: - items

    func testItemOrderTitlesAndSeparators() {
        let titles = items(allOff).map { $0.isSeparator ? "---" : $0.title }
        XCTAssertEqual(
            titles,
            [
                "Target: none",
                "Save to: ~/Desktop",
                "---",
                "Auto-focus terminal after paste",
                "Auto-press Return after paste",
                "Show notifications",
                "Auto-inject new screenshots (⌘⇧3/4)",
                "Auto-inject from clipboard (⌃⌘⇧3/4)",
                "---",
                "Inject last screenshot",
                "Inject clipboard image (Ctrl-V)",
                "---",
                "Change screenshot folder\u{2026}",
                "---",
                "Quit Hotshot",
            ])
    }

    func testEveryActionAppearsExactlyOnce() {
        let actions = items(allOff).compactMap(\.action)
        XCTAssertEqual(actions, MenuAction.allCases)
    }

    func testTargetItemIsTaggedLabel() {
        let target = items(allOff)[0]
        XCTAssertEqual(target.title, MenuModel.initialTargetTitle)
        XCTAssertEqual(target.tag, MenuModel.targetItemTag)
        XCTAssertEqual(MenuModel.targetItemTag, 100)
        XCTAssertNil(target.action)
        XCTAssertNil(target.isOn)
        XCTAssertTrue(target.isEnabled)
        let tagged = items(allOff).filter { $0.tag == MenuModel.targetItemTag }
        XCTAssertEqual(tagged.count, 1)
    }

    func testSaveToLabelShowsDirectoryAndIsDisabled() {
        let dir = items(allOff, dir: "/Users/me/Shots")[1]
        XCTAssertEqual(dir.title, "Save to: /Users/me/Shots")
        XCTAssertFalse(dir.isEnabled)
        XCTAssertNil(dir.action)
        XCTAssertEqual(dir.tag, 0)
    }

    func testAllPrefsOffUncheckToggles() {
        let menu = items(allOff)
        for action in [
            MenuAction.toggleAutoFocus, .toggleAutoReturn, .toggleNotifications, .toggleAutoWatch,
            .toggleClipboardWatch,
        ] {
            XCTAssertEqual(item(action, in: menu)?.isOn, false, "\(action)")
        }
    }

    func testEachCheckmarkFollowsOnlyItsOwnPref() {
        let toggles: [(MenuAction, WritableKeyPath<MenuPrefs, Bool>)] = [
            (.toggleAutoFocus, \.autoFocus),
            (.toggleAutoReturn, \.autoReturn),
            (.toggleNotifications, \.notifications),
            (.toggleAutoWatch, \.autoWatch),
            (.toggleClipboardWatch, \.clipboardWatch),
        ]
        for (onAction, keyPath) in toggles {
            var prefs = allOff
            prefs[keyPath: keyPath] = true
            let menu = items(prefs)
            for (action, _) in toggles {
                XCTAssertEqual(
                    item(action, in: menu)?.isOn, action == onAction,
                    "\(action) with only \(onAction) on")
            }
        }
    }

    func testNonToggleItemsHaveNoCheckmarkAndOnlyQuitHasKeyEquivalent() {
        let menu = items(allOff)
        for action in [MenuAction.injectLastScreenshot, .injectClipboardNow, .chooseScreenshotDir, .quit] {
            XCTAssertNil(item(action, in: menu)?.isOn, "\(action)")
            XCTAssertEqual(item(action, in: menu)?.isEnabled, true, "\(action)")
        }
        XCTAssertEqual(item(.quit, in: menu)?.keyEquivalent, "q")
        XCTAssertEqual(menu.filter { !$0.keyEquivalent.isEmpty }.count, 1)
    }

    func testSeparatorShape() {
        let separator = MenuModel.Item.separator
        XCTAssertTrue(separator.isSeparator)
        XCTAssertNil(separator.action)
        XCTAssertNil(separator.isOn)
        XCTAssertEqual(items(allOff).filter(\.isSeparator).count, 4)
    }

    // MARK: - targetTitle

    func testTargetTitleUsesNameOrUnknown() {
        XCTAssertEqual(MenuModel.targetTitle("zsh"), "Target: zsh")
        XCTAssertEqual(MenuModel.targetTitle(nil), "Target: unknown")
    }

    // MARK: - toggle

    func testSimpleTogglesFlipOnlyTheirPrefWithNoWatcherCommand() {
        let cases: [(MenuAction, WritableKeyPath<MenuPrefs, Bool>)] = [
            (.toggleAutoFocus, \.autoFocus),
            (.toggleAutoReturn, \.autoReturn),
            (.toggleNotifications, \.notifications),
        ]
        for (action, keyPath) in cases {
            var expectedOn = allOff
            expectedOn[keyPath: keyPath] = true
            XCTAssertEqual(
                MenuModel.toggle(action, prefs: allOff),
                MenuModel.ToggleResult(prefs: expectedOn, command: nil), "\(action) on")
            XCTAssertEqual(
                MenuModel.toggle(action, prefs: expectedOn),
                MenuModel.ToggleResult(prefs: allOff, command: nil), "\(action) off")
        }
    }

    func testAutoWatchToggleStartsAndStopsOnlyScreenshotWatcher() {
        var on = allOff
        on.autoWatch = true
        XCTAssertEqual(
            MenuModel.toggle(.toggleAutoWatch, prefs: allOff),
            MenuModel.ToggleResult(prefs: on, command: .startScreenshots))

        var clipOnWatchOn = on
        clipOnWatchOn.clipboardWatch = true
        var clipOnWatchOff = allOff
        clipOnWatchOff.clipboardWatch = true
        XCTAssertEqual(
            MenuModel.toggle(.toggleAutoWatch, prefs: clipOnWatchOn),
            MenuModel.ToggleResult(prefs: clipOnWatchOff, command: .stopScreenshots))
    }

    func testClipboardWatchToggleStartsAndStopsOnlyClipboardWatcher() {
        var on = allOff
        on.clipboardWatch = true
        XCTAssertEqual(
            MenuModel.toggle(.toggleClipboardWatch, prefs: allOff),
            MenuModel.ToggleResult(prefs: on, command: .startClipboard))

        var watchOnClipOn = on
        watchOnClipOn.autoWatch = true
        var watchOnClipOff = allOff
        watchOnClipOff.autoWatch = true
        XCTAssertEqual(
            MenuModel.toggle(.toggleClipboardWatch, prefs: watchOnClipOn),
            MenuModel.ToggleResult(prefs: watchOnClipOff, command: .stopClipboard))
    }

    func testNonToggleActionsLeavePrefsAndWatchersAlone() {
        let prefs = MenuPrefs(
            autoFocus: true, autoReturn: false, notifications: true, autoWatch: false,
            clipboardWatch: true)
        for action in [MenuAction.injectLastScreenshot, .injectClipboardNow, .chooseScreenshotDir, .quit] {
            XCTAssertEqual(
                MenuModel.toggle(action, prefs: prefs),
                MenuModel.ToggleResult(prefs: prefs, command: nil), "\(action)")
        }
    }
}
