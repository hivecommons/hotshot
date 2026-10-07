import Foundation

public let SCREENSHOT_EXTENSIONS: Set<String> = ["png", "jpg", "jpeg", "tiff", "bmp", "gif", "webp"]
public let WATCH_DEBOUNCE_SECONDS = 1.5
public let WATCH_FILE_AGE_MAX_SECONDS = 10.0

public func normalizedMacOSScreenshotLocation(_ path: String?) -> String? {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
        return nil
    }
    return (path as NSString).expandingTildeInPath
}

public func macOSScreenshotLocation() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    task.arguments = ["read", "com.apple.screencapture", "location"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = normalizedMacOSScreenshotLocation(String(data: data, encoding: .utf8)) {
            return path
        }
    } catch {
        NSLog(
            diagnosticLine(
                event: DiagnosticEvent.screenshotLocationLookupFailed.rawValue,
                severity: .warn,
                detail: "\(error.localizedDescription); falling back to ~/Desktop"))
    }
    return NSHomeDirectory() + "/Desktop"
}

public func findMostRecentScreenshot(in dir: String) -> String? {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

    var newest: String?
    var newestDate = Date.distantPast

    for file in files {
        guard !isHiddenScreenshotFileName(file) else { continue }
        let ext = (file as NSString).pathExtension.lowercased()
        guard SCREENSHOT_EXTENSIONS.contains(ext) else { continue }
        let fullPath = (dir as NSString).appendingPathComponent(file)
        guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
              let modified = attrs[.modificationDate] as? Date else { continue }
        if modified > newestDate {
            newestDate = modified
            newest = fullPath
        }
    }
    return newest
}

public func snapshotScreenshotFiles(in dir: String) -> Set<String> {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    var result = Set<String>()
    for file in files {
        guard !isHiddenScreenshotFileName(file) else { continue }
        let ext = (file as NSString).pathExtension.lowercased()
        if SCREENSHOT_EXTENSIONS.contains(ext) {
            result.insert(file)
        }
    }
    return result
}

public struct ScreenshotFileCandidate: Equatable {
    public let fileName: String
    public let modifiedAt: Date
    /// True when the file carries the `com.apple.quarantine` extended
    /// attribute, i.e. it was written by a browser, Mail, Messages, AirDrop
    /// or another download path rather than by `screencapture`.
    public let quarantined: Bool

    public init(fileName: String, modifiedAt: Date, quarantined: Bool = false) {
        self.fileName = fileName
        self.modifiedAt = modifiedAt
        self.quarantined = quarantined
    }
}

/// Extended attribute macOS sets on files written by browsers, Mail,
/// Messages, AirDrop and other download paths. Files written by
/// `screencapture` never carry it, so its presence means "this is not a
/// screenshot the user just took" and the watcher must not inject it.
public let QUARANTINE_XATTR = "com.apple.quarantine"

/// True when `path` carries the `com.apple.quarantine` extended attribute.
public func isQuarantinedFile(atPath path: String) -> Bool {
    getxattr(path, QUARANTINE_XATTR, nil, 0, 0, XATTR_NOFOLLOW) >= 0
}

public func newScreenshotFiles(previous: Set<String>, current: Set<String>) -> Set<String> {
    current.subtracting(previous)
}

/// True for dotfile names. macOS writes a capture to the screenshot folder
/// as a hidden `.Screenshot … .png` while the floating thumbnail is shown
/// and renames it to the visible name when the thumbnail dismisses, so a
/// hidden name is an in-progress capture whose path is about to vanish and
/// must never be snapshotted, injected, or treated as the last screenshot.
public func isHiddenScreenshotFileName(_ name: String) -> Bool {
    name.hasPrefix(".")
}

/// Build candidates for newly seen files, skipping any whose modification
/// date cannot be read (e.g. the file vanished between snapshot and lookup).
/// `isQuarantined` reports whether the file carries the quarantine xattr;
/// it defaults to "no" so pure callers need not touch the filesystem.
public func screenshotCandidates(
    for fileNames: Set<String>,
    directory: String,
    isQuarantined: (String) -> Bool = { _ in false },
    modificationDate: (String) -> Date?
) -> [ScreenshotFileCandidate] {
    fileNames.compactMap { file in
        let fullPath = (directory as NSString).appendingPathComponent(file)
        return modificationDate(fullPath).map {
            ScreenshotFileCandidate(
                fileName: file, modifiedAt: $0, quarantined: isQuarantined(fullPath))
        }
    }
}

/// Newest candidate the watcher may inject, or nil. Skips hotshot's own
/// saves, hidden in-progress captures, stale files and — because watch
/// mode types the path into an AI session that will read the image —
/// quarantined files, which were downloaded or received rather than
/// captured by the user.
public func newestInjectableScreenshot(
    from candidates: [ScreenshotFileCandidate],
    directory: String,
    now: Date = Date(),
    maxAge: TimeInterval = WATCH_FILE_AGE_MAX_SECONDS
) -> String? {
    let newest = candidates
        .filter { !$0.fileName.hasPrefix("hotshot-") }
        .filter { !isHiddenScreenshotFileName($0.fileName) }
        .filter { !$0.quarantined }
        .filter { now.timeIntervalSince($0.modifiedAt) < maxAge }
        .max { $0.modifiedAt < $1.modifiedAt }
    guard let newest else { return nil }
    return (directory as NSString).appendingPathComponent(newest.fileName)
}

/// Path under `directory` where a clipboard image is saved before injection.
/// The `hotshot-` prefix is a contract with `newestInjectableScreenshot`,
/// which skips such files so the watcher never re-injects its own output.
/// The name carries milliseconds and, when that name is already taken, a
/// `-N` suffix, so two saves in the same instant never overwrite each other
/// (parity with the Linux and Windows ports).
public func screenshotSavePath(
    directory: String,
    date: Date = Date(),
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    let base = "hotshot-\(formatter.string(from: date))"
    var path = (directory as NSString).appendingPathComponent("\(base).png")
    var suffix = 1
    while fileExists(path) {
        path = (directory as NSString).appendingPathComponent("\(base)-\(suffix).png")
        suffix += 1
    }
    return path
}
