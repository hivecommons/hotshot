import Foundation
import XCTest

@testable import HotshotApp

/// Menu items carry no explicit target, so each `MenuAction.selectorName`
/// is resolved along the responder chain at click time: `.quit` by
/// `NSApplication.terminate(_:)`, every other case by an `@objc` method on
/// `HotshotAppDelegate` in `Sources/hotshot/main.swift`. That delegate lives
/// in the executable target, which the test bundle cannot link, and the
/// `assert` in `setupStatusBar` that checks the wiring only runs in a debug
/// launch of the app — never under `swift test`, and never in the release
/// bundle. A renamed or deleted handler would therefore compile, pass every
/// test, and ship as a menu item AppKit silently disables. This suite reads
/// `main.swift` and pins the wiring in CI.
final class MenuActionHandlerTests: XCTestCase {
    /// `Sources/hotshot/main.swift`, located relative to this file so the
    /// test is independent of the working directory `swift test` runs in.
    private static let mainSwiftURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // HotshotAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("Sources/hotshot/main.swift")

    private static func mainSwiftSource() throws -> String {
        try String(contentsOf: mainSwiftURL, encoding: .utf8)
    }

    /// Selector names the delegate must implement: every action except
    /// `.quit`, which `MenuBuilderTests.testQuitSelectorIsHandledByNSApplication`
    /// already pins to `NSApplication`.
    private static var delegateActions: [MenuAction] {
        MenuAction.allCases.filter { $0 != .quit }
    }

    func testMainSwiftIsWhereTheDelegateLives() throws {
        let source = try Self.mainSwiftSource()
        XCTAssertTrue(
            source.contains("class HotshotAppDelegate"),
            "expected the app delegate in \(Self.mainSwiftURL.path); update this test if it moved")
    }

    func testDelegateActionsAreZeroArgumentSelectors() {
        for action in Self.delegateActions {
            XCTAssertFalse(
                action.selectorName.contains(":"),
                "\(action): delegate handlers are declared `@objc func name()`; a selector with arguments needs a different handler pattern")
        }
    }

    func testEveryDelegateMenuActionHasAnObjCHandlerInMainSwift() throws {
        let source = try Self.mainSwiftSource()
        for action in Self.delegateActions {
            let name = action.selectorName
            let pattern = "@objc\\s+func\\s+\(NSRegularExpression.escapedPattern(for: name))\\s*\\(\\s*\\)"
            XCTAssertNotNil(
                source.range(of: pattern, options: .regularExpression),
                "MenuAction.\(action) dispatches to `\(name)` but Sources/hotshot/main.swift declares no `@objc func \(name)()`; the menu item would be disabled at runtime")
        }
    }

    func testEveryDelegateMenuActionHasExactlyOneHandler() throws {
        let source = try Self.mainSwiftSource()
        for action in Self.delegateActions {
            let name = action.selectorName
            let pattern = "@objc\\s+func\\s+\(NSRegularExpression.escapedPattern(for: name))\\s*\\("
            let regex = try NSRegularExpression(pattern: pattern)
            let matches = regex.numberOfMatches(
                in: source, range: NSRange(source.startIndex..., in: source))
            XCTAssertEqual(matches, 1, "expected exactly one `@objc func \(name)(` in main.swift, found \(matches)")
        }
    }
}
