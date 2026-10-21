import ApplicationServices

/// `as?` does not runtime-check CF types, so validate the type ID before casting.
public func focusedWindowElement(_ value: AnyObject?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
