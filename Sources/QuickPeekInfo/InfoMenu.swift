import AppKit

/// Builds the "QuickPeek Info" context menu for Finder. Finder copies the menu into its own
/// process keeping only titles, images, actions and tags, so each item's tag indexes `values`
/// (tag -1 means "copy everything").
public enum InfoMenu {
    public static let copyAllTag = -1
    static let maxTitleLength = 70

    public static func build(_ info: FileInfo, action: Selector, target: AnyObject?) -> (menu: NSMenu, values: [String]) {
        var values = [info.summary]
        func item(_ title: String, tag: Int) -> NSMenuItem {
            let shortened = title.count > maxTitleLength ? String(title.prefix(maxTitleLength - 1)) + "…" : title
            let item = NSMenuItem(title: shortened, action: action, keyEquivalent: "")
            item.target = target
            item.tag = tag
            return item
        }

        let submenu = NSMenu(title: "QuickPeek Info")
        submenu.addItem(item(info.summary, tag: 0))
        for section in info.sections where section.title != "General" {
            submenu.addItem(.separator())
            let header = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
            submenu.addItem(header)
            for entry in section.items {
                values.append(entry.value)
                submenu.addItem(item(entry.label.isEmpty ? entry.value : "\(entry.label): \(entry.value)", tag: values.count - 1))
            }
        }
        submenu.addItem(.separator())
        let copyAll = item("Copy All Details", tag: copyAllTag)
        copyAll.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        submenu.addItem(copyAll)

        let root = NSMenuItem(title: "QuickPeek Info", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        root.submenu = submenu
        let menu = NSMenu(title: "")
        menu.addItem(root)
        return (menu, values)
    }
}
