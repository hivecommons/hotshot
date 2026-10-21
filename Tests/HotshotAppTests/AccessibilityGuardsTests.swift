import ApplicationServices
import Foundation
import XCTest

@testable import HotshotApp

final class AccessibilityGuardsTests: XCTestCase {
    func testNilFocusedWindowIsRejected() {
        XCTAssertNil(focusedWindowElement(nil))
    }

    func testNonAXFocusedWindowIsRejected() {
        XCTAssertNil(focusedWindowElement("title" as CFString))
        XCTAssertNil(focusedWindowElement(NSNumber(value: 1)))
    }

    func testAXFocusedWindowIsPreserved() throws {
        let element = AXUIElementCreateSystemWide()
        let focused = try XCTUnwrap(focusedWindowElement(element))
        XCTAssertEqual(CFGetTypeID(focused), AXUIElementGetTypeID())
        XCTAssertTrue(focused === element)
    }
}
