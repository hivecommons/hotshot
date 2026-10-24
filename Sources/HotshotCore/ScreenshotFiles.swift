import Foundation

public let SCREENSHOT_EXTENSIONS: Set<String> = ["png", "jpg", "jpeg", "tiff", "bmp", "gif", "webp"]
public let WATCH_DEBOUNCE_SECONDS = 1.5
/// How often the app re-checks that the watch is bound to the current
/// screenshot folder (see `ScreenshotWatcher.reconcileDirectory`).
public let WATCH_DIRECTORY_RECONCILE_SECONDS = 30.0
/// Max age of a new file, measured from when it became visible in the folder
/// (see `fileVisibilityDate`), not from its last write.
public let WATCH_FILE_AGE_MAX_SECONDS = 10.0

public func normalizedMacOSScreenshotLocation(_ path: String?) -> String? {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
        return nil
    }
    return (path as NSString).expandingTildeInPath
}

public func macOSScreenshotLocation() -> String {
    // Authoritative: the same cfprefsd store `defaults read` prints, without
    // forking a process. Synchronizing drops this process's cached copy so an
    // external change is seen; an unset key goes straight to the fallback
    // because this runs on the main run loop every
    // WATCH_DIRECTORY_RECONCILE_SECONDS.
    let domain = "com.apple.screencapture" as CFString
    CFPreferencesAppSynchronize(domain)
    if let path = normalizedMacOSScreenshotLocation(
        CFPreferencesCopyAppValue("location" as CFString, domain) as? String)
    {
        return path
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

/// The later of a file's mtime and ctime. macOS renames the hidden in-progress
/// capture to its visible name when the thumbnail is dismissed; rename(2)
/// leaves mtime untouched but bumps ctime, so this is when the watcher could
/// first see the file.
public func laterDate(_ a: Date?, _ b: Date?) -> Date? {
    switch (a, b) {
    case let (a?, b?): return max(a, b)
    case let (a?, nil): return a
    case let (nil, b?): return b
    case (nil, nil): return nil
    }
}

/// When the file at `path` became visible in its folder: max(mtime, ctime).
public func fileVisibilityDate(atPath path: String) -> Date? {
    let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    var st = stat()
    var ctime: Date?
    if stat(path, &st) == 0 {
        ctime = Date(
            timeIntervalSince1970: Double(st.st_ctimespec.tv_sec)
                + Double(st.st_ctimespec.tv_nsec) / 1e9)
    }
    return laterDate(mtime, ctime)
}

/// Names of the non-quarantined, user-visible candidates that
/// `newestInjectableScreenshot` refuses only because they are too old.
public func staleScreenshotCandidates(
    from candidates: [ScreenshotFileCandidate],
    now: Date = Date(),
    maxAge: TimeInterval = WATCH_FILE_AGE_MAX_SECONDS
) -> [String] {
    candidates
        .filter { !$0.fileName.hasPrefix("hotshot-") }
        .filter { !isHiddenScreenshotFileName($0.fileName) }
        .filter { !$0.quarantined }
        .filter { now.timeIntervalSince($0.modifiedAt) >= maxAge }
        .map(\.fileName)
}

/// Newest candidate the watcher may inject, or nil. Skips hotshot's own
/// saves, hidden in-progress captures, stale files (`modifiedAt` is the
/// visibility date: the rename that reveals a capture bumps ctime, so age
/// is measured from then, not from the last write) and — because watch
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
