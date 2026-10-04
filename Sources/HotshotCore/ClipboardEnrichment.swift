import Foundation

public let CLIPBOARD_POLL_INTERVAL_SECONDS = 0.5

/// Decide whether text already on the clipboard can be trusted as the
/// enriched plain-text path accompanying a clipboard image. Only hotshot's
/// own enrichment qualifies: the text must be free of control characters
/// (so a Ctrl-V paste can never press Return or emit escape sequences) and,
/// once the drag-and-drop backslash escapes are removed, name an existing
/// `hotshot-*.png` file directly inside `screenshotDirectory` — the only
/// shape `writePasteboard` ever produces. Any other text (including paths
/// to unrelated existing files an attacker can predict, like /etc/passwd)
/// is untrusted, so the caller rewrites the pasteboard before any paste.
public func trustedEnrichedClipboardPath(
    _ text: String?,
    screenshotDirectory: String,
    fileExists: (String) -> Bool
) -> String? {
    guard let text, !containsControlCharacters(text) else { return nil }
    let unescaped = text.replacingOccurrences(of: "\\", with: "")
    let dir = ((screenshotDirectory as NSString).expandingTildeInPath as NSString)
        .standardizingPath
    let parent = ((unescaped as NSString).deletingLastPathComponent as NSString)
        .standardizingPath
    let name = (unescaped as NSString).lastPathComponent
    guard parent == dir,
        name.hasPrefix("hotshot-"),
        name.lowercased().hasSuffix(".png"),
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
