import Foundation

public let PREF_AUTO_FOCUS = "hotshotAutoFocus"
public let PREF_AUTO_RETURN = "hotshotAutoReturn"
public let PREF_NOTIFICATIONS = "hotshotNotifications"
public let PREF_AUTO_WATCH = "hotshotAutoWatch"
public let PREF_CLIPBOARD_WATCH = "hotshotClipboardWatch"
public let PREF_SCREENSHOT_DIR = "hotshotScreenshotDir"

/// Backs a `Bool` property with a `UserDefaults` value stored under `key`,
/// falling back to `defaultValue` when the key has never been set.
/// Collapses the five near-identical get/set pairs in `HotshotApp` into
/// one-line declarations.
@propertyWrapper
public struct UserDefault {
    public let key: String
    public let defaultValue: Bool

    public init(_ key: String, defaultValue: Bool) {
        self.key = key
        self.defaultValue = defaultValue
    }

    public var wrappedValue: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
