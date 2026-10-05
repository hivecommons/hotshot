import Foundation
import XCTest
@testable import HotshotCore

/// Keeps diagnostic event names a closed, bounded vocabulary (issue #136):
/// every event emitted from Sources/ must be a `DiagnosticEvent` case, and
/// every case must be a lowercase dotted identifier so log filters stay stable.
final class DiagnosticEventTests: XCTestCase {
    private static let eventNamePattern = "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$"

    /// Generous ceiling: the set is meant to stay small and reviewable, so
    /// growing past this should be a deliberate decision, not drift.
    private static let maxEventCount = 64

    private var knownEvents: Set<String> {
        Set(DiagnosticEvent.allCases.map(\.rawValue))
    }

    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HotshotCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources")
    }

    private func swiftSources() throws -> [(name: String, text: String)] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil))
        var files: [(name: String, text: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    private func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    func testEventNamesAreLowercaseDottedIdentifiers() {
        for event in DiagnosticEvent.allCases {
            XCTAssertNotNil(
                event.rawValue.range(of: Self.eventNamePattern, options: .regularExpression),
                "\(event.rawValue) is not a lowercase dotted identifier")
        }
    }

    func testEventNameSetIsBoundedAndUnique() {
        XCTAssertFalse(DiagnosticEvent.allCases.isEmpty)
        XCTAssertLessThanOrEqual(DiagnosticEvent.allCases.count, Self.maxEventCount)
        XCTAssertEqual(knownEvents.count, DiagnosticEvent.allCases.count, "event names must be unique")
    }

    func testEveryEventNameUsedInSourcesIsInTheClosedSet() throws {
        let sources = try swiftSources()
        XCTAssertFalse(sources.isEmpty, "no Swift sources found under \(sourcesDirectory.path)")

        // String literals passed as the event to a diagnostic seam
        // (`diag("…"`, `diagnostic("…"`) or straight to `diagnosticLine(event:)`.
        let literalPatterns = [
            "\\b(?:diag|diagnostic)\\(\\s*\"([^\"]+)\"",
            "diagnosticLine\\(\\s*event:\\s*\"([^\"]+)\"",
        ]
        var used: [String] = []
        for file in sources {
            for pattern in literalPatterns {
                for event in try matches(pattern, in: file.text) {
                    used.append(event)
                    XCTAssertTrue(
                        knownEvents.contains(event),
                        "\(file.name) emits '\(event)', which is not a DiagnosticEvent case")
                }
            }
        }
        XCTAssertFalse(used.isEmpty, "expected to find diagnostic event literals in Sources/")
    }

    func testNoFreeFormHotshotNSLogRemainsInSources() throws {
        for file in try swiftSources() {
            XCTAssertFalse(
                file.text.contains("NSLog(\"Hotshot:"),
                "\(file.name) logs a free-form NSLog line instead of diagnosticLine")
        }
    }

    func testScreenshotLocationLookupFailureIsAWarnLine() {
        XCTAssertEqual(
            diagnosticLine(
                event: DiagnosticEvent.screenshotLocationLookupFailed.rawValue,
                severity: .warn,
                detail: "boom"),
            "Hotshot [WARN] screenshot.location_lookup_failed: boom")
    }
}
