import AppKit
import XCTest

@testable import HotshotApp

/// Covers the `MenuModel.Item` → `NSMenuItem` mapping moved out of the app
/// delegate's `rebuildMenu()` in #191: separators, copied tag / enabled flag
/// / key equivalent, checkmark state, action selectors, and that the target
/// label can be found again by its tag.
final class MenuBuilderTests: XCTestCase {
    private let prefs = MenuPrefs(
        autoFocus: true, autoReturn: false, notifications: true, autoWatch: false,
        clipboardWatch: true)

    private func menu() -> NSMenu {
        MenuModel.makeMenu(items: MenuModel.items(prefs: prefs, screenshotDir: "~/Desktop"))
    }

    func testMenuMirrorsModelItemsInOrder() {
        let items = MenuModel.items(prefs: prefs, screenshotDir: "~/Desktop")
        let built = menu().items
        XCTAssertEqual(built.count, items.count)
        for (menuItem, item) in zip(built, items) {
            XCTAssertEqual(menuItem.isSeparatorItem, item.isSeparator)
            if !item.isSeparator {
                XCTAssertEqual(menuItem.title, item.title)
                XCTAssertEqual(menuItem.tag, item.tag, item.title)
                XCTAssertEqual(menuItem.isEnabled, item.isEnabled, item.title)
                XCTAssertEqual(menuItem.keyEquivalent, item.keyEquivalent, item.title)
                XCTAssertEqual(menuItem.action, item.action.map { Selector($0.selectorName) }, item.title)
                XCTAssertEqual(menuItem.state, item.isOn == true ? .on : .off, item.title)
            }
        }
    }

    func testSeparatorBecomesSeparatorItem() {
        XCTAssertTrue(MenuModel.makeMenuItem(.separator).isSeparatorItem)
    }

    func testTargetLabelIsFoundByTag() {
        let target = menu().item(withTag: MenuModel.targetItemTag)
        XCTAssertNotNil(target)
        XCTAssertEqual(target?.title, MenuModel.initialTargetTitle)
        XCTAssertNil(target?.action)
    }

    func testCopiesTagEnabledAndKeyEquivalent() {
        let menuItem = MenuModel.makeMenuItem(
            MenuModel.Item(title: "X", action: .quit, keyEquivalent: "q", isEnabled: false, tag: 7))
        XCTAssertFalse(menuItem.isSeparatorItem)
        XCTAssertEqual(menuItem.title, "X")
        XCTAssertEqual(menuItem.tag, 7)
        XCTAssertFalse(menuItem.isEnabled)
        XCTAssertEqual(menuItem.keyEquivalent, "q")
        XCTAssertEqual(menuItem.action, #selector(NSApplication.terminate(_:)))
        XCTAssertNil(menuItem.target)
    }

    func testCheckmarkState() {
        XCTAssertEqual(MenuModel.makeMenuItem(MenuModel.Item(title: "on", action: nil, isOn: true)).state, .on)
        XCTAssertEqual(MenuModel.makeMenuItem(MenuModel.Item(title: "off", action: nil, isOn: false)).state, .off)
        XCTAssertEqual(MenuModel.makeMenuItem(MenuModel.Item(title: "none", action: nil)).state, .off)
    }

    func testToggleItemsShowPrefState() {
        let built = menu()
        func state(_ action: MenuAction) -> NSControl.StateValue? {
            built.items.first { $0.action == Selector(action.selectorName) }?.state
        }
        XCTAssertEqual(state(.toggleAutoFocus), .on)
        XCTAssertEqual(state(.toggleAutoReturn), .off)
        XCTAssertEqual(state(.toggleNotifications), .on)
        XCTAssertEqual(state(.toggleAutoWatch), .off)
        XCTAssertEqual(state(.toggleClipboardWatch), .on)
    }

    func testQuitSelectorIsHandledByNSApplication() {
        XCTAssertTrue(NSApplication.instancesRespond(to: Selector(MenuAction.quit.selectorName)))
    }
}
