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

    public init(fileName: String, modifiedAt: Date) {
        self.fileName = fileName
        self.modifiedAt = modifiedAt
    }
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
public func screenshotCandidates(
    for fileNames: Set<String>,
    directory: String,
    modificationDate: (String) -> Date?
) -> [ScreenshotFileCandidate] {
    fileNames.compactMap { file in
        let fullPath = (directory as NSString).appendingPathComponent(file)
        return modificationDate(fullPath).map { ScreenshotFileCandidate(fileName: file, modifiedAt: $0) }
    }
}

public func newestInjectableScreenshot(
    from candidates: [ScreenshotFileCandidate],
    directory: String,
    now: Date = Date(),
    maxAge: TimeInterval = WATCH_FILE_AGE_MAX_SECONDS
) -> String? {
    let newest = candidates
        .filter { !$0.fileName.hasPrefix("hotshot-") }
        .filter { !isHiddenScreenshotFileName($0.fileName) }
        .filter { now.timeIntervalSince($0.modifiedAt) < maxAge }
        .max { $0.modifiedAt < $1.modifiedAt }
    guard let newest else { return nil }
    return (directory as NSString).appendingPathComponent(newest.fileName)
}

/// Path under `directory` where a clipboard image is saved before injection.
/// The `hotshot-` prefix is a contract with `newestInjectableScreenshot`,
/// which skips such files so the watcher never re-injects its own output.
public func screenshotSavePath(directory: String, date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return (directory as NSString).appendingPathComponent(
        "hotshot-\(formatter.string(from: date)).png")
}
