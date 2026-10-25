import Foundation

public let CLIPBOARD_POLL_INTERVAL_SECONDS = 0.5

/// True when `name` has the shape `screenshotSavePath` produces:
/// `hotshot-` followed by digits and hyphens, then `.png`. Nothing else is
/// ever written by hotshot, so a `hotshot-` file whose name carries any
/// other character was put in the folder by someone else.
public func isHotshotSavedFileName(_ name: String) -> Bool {
    guard name.hasPrefix("hotshot-"), name.lowercased().hasSuffix(".png") else { return false }
    let stem = name.dropFirst("hotshot-".count).dropLast(".png".count)
    guard !stem.isEmpty else { return false }
    return stem.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "-") }
}

/// Decide whether text already on the clipboard can be trusted as the
/// enriched plain-text path accompanying a clipboard image. Only hotshot's
/// own enrichment qualifies: the text must be free of control characters
/// (so a Ctrl-V paste can never press Return or emit escape sequences),
/// must be exactly the drag-and-drop escaped form `writePasteboard` stores
/// (`shellEscapedPath`, so an unescaped shell metacharacter can never be
/// pasted) and, once those escapes are removed, must name an existing file
/// directly inside `screenshotDirectory` whose name has the digits-and-
/// hyphens shape `screenshotSavePath` writes. Any other text (including
/// paths to unrelated existing files an attacker can predict, like
/// /etc/passwd, or a foreign `hotshot-$(cmd).png` dropped into the folder)
/// is untrusted, so the caller rewrites the pasteboard before any paste.
public func trustedEnrichedClipboardPath(
    _ text: String?,
    screenshotDirectory: String,
    fileExists: (String) -> Bool
) -> String? {
    guard let text, !containsControlCharacters(text) else { return nil }
    // A backslash escapes the next character (a literal backslash is `\\`),
    // so only the escape prefixes are dropped, not every backslash.
    var unescaped = ""
    var escaping = false
    for ch in text {
        if ch == "\\" && !escaping {
            escaping = true
        } else {
            unescaped.append(ch)
            escaping = false
        }
    }
    guard text == shellEscapedPath(unescaped) else { return nil }
    let dir = ((screenshotDirectory as NSString).expandingTildeInPath as NSString)
        .standardizingPath
    let parent = ((unescaped as NSString).deletingLastPathComponent as NSString)
        .standardizingPath
    let name = (unescaped as NSString).lastPathComponent
    guard parent == dir,
        isHotshotSavedFileName(name),
        fileExists(unescaped)
    else { return nil }
    return text
}

/// What to do with the clipboard when an image lands on it.
public enum ClipboardEnrichmentDecision: Equatable {
    /// Already carries a PNG plus a trusted existing path; use this path as-is.
    case alreadyEnriched(path: String)
    /// Save the image to disk and rewrite the pasteboard.
    case saveAndRewrite
}

/// Decide whether the clipboard is already enriched. Untrusted text is never
/// reused, so a Ctrl-V paste cannot type attacker-controlled clipboard text.
public func clipboardEnrichmentDecision(
    hasPNG: Bool,
    text: String?,
    screenshotDirectory: String,
    fileExists: (String) -> Bool
) -> ClipboardEnrichmentDecision {
    guard hasPNG,
        let existing = trustedEnrichedClipboardPath(
            text, screenshotDirectory: screenshotDirectory, fileExists: fileExists)
    else {
        return .saveAndRewrite
    }
    return .alreadyEnriched(path: existing)
}
