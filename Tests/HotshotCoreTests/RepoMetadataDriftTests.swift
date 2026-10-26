import Foundation
import XCTest

@testable import HotshotCore

/// The issue forms under `.github/ISSUE_TEMPLATE/` and the prow `OWNERS`
/// file restate facts that live in code: which terminals macOS hotshot
/// recognises, which AI CLIs it classifies, the verbose-logging switch, the
/// shape of a diagnostic line, and the repo paths the forms link to. Nothing
/// executes that prose, so a new terminal, a renamed env var or a moved
/// runbook leaves the forms quietly wrong. These tests pin the prose to the
/// constants it describes, the same way `DiagnosticEventTests` pins event
/// names to `Sources/`.
final class RepoMetadataDriftTests: XCTestCase {
    private static let issueFormDirectory = ".github/ISSUE_TEMPLATE"
    private static let bugReportForm = ".github/ISSUE_TEMPLATE/bug_report.yml"
    private static let targetRequestForm = ".github/ISSUE_TEMPLATE/target_request.yml"
    private static let classificationSource = "Sources/HotshotCore/TargetClassification.swift"

    /// Display name the bug form uses for each recognised terminal bundle.
    /// Adding a bundle to `TERMINAL_BUNDLE_IDS` without a row here (and a
    /// mention in the form) fails `testBugReportNamesEveryRecognisedTerminal`.
    private static let terminalDisplayNames: [String: String] = [
        "com.googlecode.iterm2": "iTerm2",
        "com.apple.Terminal": "Terminal.app",
        "net.kovidgoyal.kitty": "Kitty",
        "io.alacritty": "Alacritty",
        "dev.warp.Warp-Stable": "Warp",
        "com.mitchellh.ghostty": "Ghostty",
    ]

    /// GitHub login rule: alphanumerics and single hyphens, no leading or
    /// trailing hyphen, at most 39 characters.
    private static let githubLoginPattern = "^[A-Za-z0-9](?:-?[A-Za-z0-9]){0,38}$"

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HotshotCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
    }

    private func repoText(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func repoFileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(relativePath).path)
    }

    private func issueForms() throws -> [(name: String, text: String)] {
        let dir = packageRoot.appendingPathComponent(Self.issueFormDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
            .sorted()
        return try names.map { name in
            (name: name, text: try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))
        }
    }

    /// First capture group of every match of `pattern` in `text`.
    private func captures(
        _ pattern: String, in text: String, options: NSRegularExpression.Options = []
    ) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The YAML block of the form element whose `id:` is `id`, up to the
    /// next element (`- type:`) or end of file. Text-level on purpose: the
    /// forms are small and Foundation has no YAML parser.
    private func formElement(id: String, in form: String) throws -> String {
        let start = try XCTUnwrap(form.range(of: "id: \(id)\n"), "form has no element with id \(id)")
        let rest = form[start.upperBound...]
        let end = rest.range(of: "- type:")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    // MARK: - issue forms: shape

    func testEveryIssueFormHasTheRequiredTopLevelKeys() throws {
        let forms = try issueForms()
        XCTAssertFalse(forms.isEmpty, "no issue forms found under \(Self.issueFormDirectory)")
        for form in forms {
            if form.name == "config.yml" {
                XCTAssertTrue(form.text.contains("blank_issues_enabled:"), "config.yml must set blank_issues_enabled")
                XCTAssertTrue(form.text.contains("contact_links:"), "config.yml must declare contact_links")
                continue
            }
            for key in ["name:", "description:", "title:", "labels:", "body:"] {
                XCTAssertTrue(
                    form.text.contains("\n\(key)") || form.text.hasPrefix(key),
                    "\(form.name) lacks top-level \(key)")
            }
            XCTAssertTrue(form.text.contains("\n  - type: "), "\(form.name) body has no elements")
        }
    }

    func testIssueFormElementIdsAreUniquePerForm() throws {
        for form in try issueForms() where form.name != "config.yml" {
            let ids = try captures("^    id: ([a-z][a-z0-9-]*)$", in: form.text, options: .anchorsMatchLines)
            XCTAssertEqual(ids.count, Set(ids).count, "\(form.name) repeats an element id: \(ids)")
        }
    }

    // MARK: - issue forms: facts pinned to code

    func testBugReportNamesEveryRecognisedTerminal() throws {
        XCTAssertEqual(
            Set(Self.terminalDisplayNames.keys), TERMINAL_BUNDLE_IDS,
            "TERMINAL_BUNDLE_IDS changed: update terminalDisplayNames and the Terminal field of bug_report.yml")
        let terminalField = try formElement(id: "terminal", in: try repoText(Self.bugReportForm))
        for (bundleID, name) in Self.terminalDisplayNames.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(
                terminalField.contains(name),
                "bug_report.yml Terminal field does not mention \(name) (\(bundleID))")
        }
    }

    func testBugReportCLIDropdownMatchesTheClassifier() throws {
        let cliField = try formElement(id: "cli", in: try repoText(Self.bugReportForm))
        // Options read "Claude Code (claude)" or, when the product name is the
        // executable, just "aider"; the escape hatch "other / none" is skipped.
        let options = try captures("^ *- (.+)$", in: cliField, options: .anchorsMatchLines)
        let formNames = try options.filter { $0 != "other / none" }.map { option -> String in
            try captures("\\(([a-z0-9-]+)\\)", in: option).first ?? option
        }
        XCTAssertFalse(formNames.isEmpty, "bug_report.yml CLI dropdown lists no AI CLIs")

        let source = try repoText(Self.classificationSource)
        let classifiedNames = Set(try captures("name == \"([a-z0-9-]+)\"", in: source))
        XCTAssertEqual(
            Set(formNames), classifiedNames,
            "bug_report.yml CLI options must list exactly the executables classifyCommands recognises")

        for name in formNames {
            let cli = classifyCommands([name])
            XCTAssertNotNil(cli, "\(name) is offered in the form but classifyCommands ignores it")
            XCTAssertEqual(cli, classifyCommands(["/usr/local/bin/\(name) --flag"]), "\(name) must classify by basename")
        }
        XCTAssertTrue(cliField.contains("other / none"), "the dropdown needs an escape hatch for unrecognised CLIs")
    }

    func testTargetRequestFormDescribesTheInjectionFormats() throws {
        let form = try repoText(Self.targetRequestForm)
        XCTAssertTrue(form.contains("Claude Code gets `[path] `"), "target_request.yml must say Claude gets the bracketed form")
        XCTAssertEqual(classifyCommands(["claude"]), .claude)
        for name in ["copilot", "aider", "opencode"] {
            XCTAssertEqual(classifyCommands([name]), .plainPath, "\(name) is documented as a bare-path CLI")
        }
        XCTAssertEqual(classifyCommands(["gemini"]), .atPath)
        XCTAssertTrue(form.contains("Gemini CLI gets `@path `"), "target_request.yml must name the @path CLI")
        XCTAssertTrue(
            form.contains("GitHub Copilot CLI, aider and OpenCode get a bare escaped path"),
            "target_request.yml must name the bare-path CLIs")
        XCTAssertTrue(form.contains("`osascript -e 'id of app"), "the form must tell reporters how to find a bundle id")
    }

    func testBugReportDiagnosticGuidanceMatchesLogging() throws {
        let logsField = try formElement(id: "logs", in: try repoText(Self.bugReportForm))
        XCTAssertTrue(
            logsField.contains("`\(VERBOSE_LOGGING_ENV_VAR)=1`"),
            "bug_report.yml must name \(VERBOSE_LOGGING_ENV_VAR)=1 as the verbose switch")
        XCTAssertTrue(logsField.contains("`Hotshot [LEVEL] event.name`"), "bug_report.yml must show the diagnostic line shape")
        XCTAssertEqual(diagnosticLine(event: "event.name", severity: .warn), "Hotshot [WARN] event.name")
        XCTAssertTrue(logsField.contains("redact"), "the form must say the default output is redacted")
        XCTAssertTrue(repoFileExists("linux/hotshot-capture.sh"), "the form names `hotshot-capture`; its source moved")
        XCTAssertTrue(repoFileExists("windows/hotshot-capture.ps1"), "the form names `hotshot-capture.ps1`; it moved")
    }

    func testRepoLinksInIssueFormsResolveToCheckedInFiles() throws {
        var linked = 0
        for form in try issueForms() {
            let paths = try captures("https://github\\.com/hivecommons/hotshot/blob/main/([^)\\s\"]+)", in: form.text)
            for path in paths {
                linked += 1
                XCTAssertTrue(repoFileExists(path), "\(form.name) links blob/main/\(path), which is not in the checkout")
            }
        }
        XCTAssertGreaterThan(linked, 0, "expected the forms to link SECURITY.md / ROADMAP.md / the runbook")
    }

    // MARK: - OWNERS

    func testOwnersListsValidApproversAndReviewers() throws {
        let owners = try repoText("OWNERS")
        var sections: [String: [String]] = [:]
        var current: String?
        for rawLine in owners.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if rawLine.first != " ", line.hasSuffix(":") {
                let key = String(line.dropLast())
                current = key
                sections[key] = []
            } else if line.hasPrefix("- "), let key = current {
                sections[key, default: []].append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else {
                XCTFail("OWNERS has a line prow will not parse: \(rawLine)")
            }
        }

        XCTAssertEqual(Set(sections.keys), ["approvers", "reviewers"], "OWNERS must declare exactly approvers and reviewers")
        for (key, handles) in sections {
            XCTAssertFalse(handles.isEmpty, "OWNERS \(key) is empty: nobody can /approve or /lgtm")
            XCTAssertEqual(handles.count, Set(handles).count, "OWNERS \(key) repeats a handle: \(handles)")
            for handle in handles {
                XCTAssertNotNil(
                    handle.range(of: Self.githubLoginPattern, options: .regularExpression),
                    "OWNERS \(key) entry \(handle) is not a GitHub login")
            }
        }
    }
}
