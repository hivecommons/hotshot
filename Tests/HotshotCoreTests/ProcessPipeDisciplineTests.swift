import Foundation
import XCTest

/// Regression gate for the subprocess pipe deadlock fixed in #241/#243:
/// a `Process` whose stdout is a `Pipe` must be drained
/// (`readDataToEndOfFile()` or a `readabilityHandler`) *before*
/// `waitUntilExit()`, and stderr must never be parked on a `Pipe()` nobody
/// reads. Either mistake lets a chatty child fill the pipe buffer, block on
/// write, and never exit while the caller sits in `waitUntilExit`.
///
/// The rule is enforced on source text so a third call site cannot
/// reintroduce the ordering silently — the deadlock only shows up at runtime
/// with a large enough child output, which no unit test reproduces reliably.
final class ProcessPipeDisciplineTests: XCTestCase {
    private static let ownFileName = "ProcessPipeDisciplineTests.swift"

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HotshotCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
    }

    private func swiftFiles(under directory: String) throws -> [(name: String, text: String)] {
        let root = packageRoot.appendingPathComponent(directory)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [(name: String, text: String)] = []
        for case let url as URL in enumerator
        where url.pathExtension == "swift" && url.lastPathComponent != Self.ownFileName {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return files.sorted { $0.name < $1.name }
    }

    /// One `Process()` construction site and what the gate found there.
    struct Site: Equatable {
        var pipesStdout: Bool
        var waits: Bool
        var drainedBeforeWait: Bool
        var unreadStderrPipe: Bool
    }

    /// Splits `text` at every `Process()` and inspects the code that follows
    /// each one up to the next construction. Pure so it can be fixture-tested.
    static func sites(in text: String) -> [Site] {
        let chunks = text.components(separatedBy: "Process()").dropFirst()
        return chunks.map { chunk in
            let pipesStdout = chunk.contains("Pipe()")
            let unreadStderrPipe =
                chunk.range(of: "standardError\\s*=\\s*Pipe\\(\\)", options: .regularExpression) != nil
            guard let wait = chunk.range(of: "waitUntilExit()") else {
                return Site(
                    pipesStdout: pipesStdout, waits: false, drainedBeforeWait: false,
                    unreadStderrPipe: unreadStderrPipe)
            }
            let before = chunk[..<wait.lowerBound]
            let drained =
                before.contains("readDataToEndOfFile()") || before.contains("readabilityHandler")
            return Site(
                pipesStdout: pipesStdout, waits: true, drainedBeforeWait: drained,
                unreadStderrPipe: unreadStderrPipe)
        }
    }

    static func violations(in text: String) -> [String] {
        var out: [String] = []
        for (index, site) in sites(in: text).enumerated() {
            let label = "Process() #\(index + 1)"
            if site.pipesStdout && site.waits && !site.drainedBeforeWait {
                out.append("\(label) calls waitUntilExit() before draining its Pipe (deadlock, see #241)")
            }
            if site.unreadStderrPipe {
                out.append("\(label) parks standardError on an unread Pipe(); use FileHandle.nullDevice")
            }
        }
        return out
    }

    // MARK: - Fixture self-tests (the gate must reject what #241 fixed)

    func testFixtureWaitBeforeDrainIsAViolation() {
        let bad = """
            let task = Process()
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            """
        XCTAssertEqual(
            Self.violations(in: bad),
            ["Process() #1 calls waitUntilExit() before draining its Pipe (deadlock, see #241)"])
    }

    func testFixtureUnreadStderrPipeIsAViolation() {
        let bad = """
            let task = Process()
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            """
        XCTAssertEqual(
            Self.violations(in: bad),
            ["Process() #1 parks standardError on an unread Pipe(); use FileHandle.nullDevice"])
    }

    func testFixtureDrainBeforeWaitWithNullStderrIsClean() {
        let good = """
            let task = Process()
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            """
        XCTAssertEqual(Self.violations(in: good), [])
    }

    func testFixtureReadabilityHandlerCountsAsDraining() {
        let good = """
            let task = Process()
            let pipe = Pipe()
            task.standardOutput = pipe
            pipe.fileHandleForReading.readabilityHandler = { _ in }
            try task.run()
            task.waitUntilExit()
            """
        XCTAssertEqual(Self.violations(in: good), [])
    }

    func testFixtureProcessWithoutPipeOrWaitIsIgnored() {
        let plain = """
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try task.run()
            """
        XCTAssertEqual(Self.violations(in: plain), [])
        XCTAssertEqual(
            Self.sites(in: plain),
            [Site(pipesStdout: false, waits: false, drainedBeforeWait: false, unreadStderrPipe: false)])
    }

    func testFixtureEachProcessSiteIsJudgedIndependently() {
        let mixed = """
            let a = Process()
            let p = Pipe()
            a.standardOutput = p
            try a.run()
            let d = p.fileHandleForReading.readDataToEndOfFile()
            a.waitUntilExit()

            let b = Process()
            let q = Pipe()
            b.standardOutput = q
            try b.run()
            b.waitUntilExit()
            let e = q.fileHandleForReading.readDataToEndOfFile()
            """
        XCTAssertEqual(
            Self.violations(in: mixed),
            ["Process() #2 calls waitUntilExit() before draining its Pipe (deadlock, see #241)"])
    }

    // MARK: - Repository gate

    func testEveryPipedProcessInSourcesDrainsBeforeWaiting() throws {
        var pipedSites = 0
        for file in try swiftFiles(under: "Sources") {
            let sites = Self.sites(in: file.text)
            pipedSites += sites.filter { $0.pipesStdout && $0.waits }.count
            for violation in Self.violations(in: file.text) {
                XCTFail("\(file.name): \(violation)")
            }
        }
        // commands(onTTY:) is the remaining site #241 fixed (the
        // macOSScreenshotLocation() fork was replaced by a CFPreferences read
        // in #286); the gate is vacuous if it stops seeing it.
        XCTAssertGreaterThanOrEqual(
            pipedSites, 1, "expected the known piped Process site under Sources/ to be scanned")
    }

    func testEveryPipedProcessInTestsDrainsBeforeWaiting() throws {
        var pipedSites = 0
        for file in try swiftFiles(under: "Tests") {
            let sites = Self.sites(in: file.text)
            pipedSites += sites.filter { $0.pipesStdout && $0.waits }.count
            for violation in Self.violations(in: file.text) {
                XCTFail("\(file.name): \(violation)")
            }
        }
        // readScreenCaptureLocationPreference() in HotshotCoreTests is the
        // helper #243 fixed.
        XCTAssertGreaterThanOrEqual(
            pipedSites, 1, "expected the known piped Process helper under Tests/ to be scanned")
    }
}
