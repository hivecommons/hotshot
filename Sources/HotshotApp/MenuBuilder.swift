import AppKit

extension MenuModel {
    /// Build the `NSMenuItem` described by `item`: a separator, or an item
    /// carrying its title, action selector, key equivalent, tag (which
    /// `item(withTag: targetItemTag)` relies on to find the target label),
    /// enabled flag and checkmark state (`isOn == true` → `.on`, otherwise
    /// `.off`). Items have no explicit target, so actions travel the
    /// responder chain.
    public static func makeMenuItem(_ item: Item) -> NSMenuItem {
        if item.isSeparator {
            return NSMenuItem.separator()
        }
        let menuItem = NSMenuItem(
            title: item.title,
            action: item.action.map { Selector($0.selectorName) },
            keyEquivalent: item.keyEquivalent)
        menuItem.tag = item.tag
        menuItem.isEnabled = item.isEnabled
        menuItem.state = item.isOn == true ? .on : .off
        return menuItem
    }

    /// Build an `NSMenu` holding one `makeMenuItem` per item, in order.
    public static func makeMenu(items: [Item]) -> NSMenu {
        let menu = NSMenu()
        for item in items {
            menu.addItem(makeMenuItem(item))
        }
        return menu
    }
}
