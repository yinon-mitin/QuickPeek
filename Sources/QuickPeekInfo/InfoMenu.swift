import AppKit

/// Builds the context menu for Finder: the file's summary as the menu item, details in its
/// submenu. Finder copies the menu into its own process keeping only titles, images, actions
/// and tags, so each item's tag indexes `values` (tag -1 means "copy everything").
public enum InfoMenu {
    public static let copyAllTag = -1
    static let maxTitleLength = 70

    public static func build(_ info: FileInfo, action: Selector, target: AnyObject?,
                             appearance: NSAppearance) -> (menu: NSMenu, values: [String]) {
        var values = [info.summary]
        func item(_ title: String, tag: Int) -> NSMenuItem {
            let item = NSMenuItem(title: shortened(title), action: action, keyEquivalent: "")
            item.target = target
            item.tag = tag
            return item
        }

        let submenu = NSMenu(title: "QuickPeek Info")
        for section in info.sections where section.title != "General" {
            if !submenu.items.isEmpty { submenu.addItem(.separator()) }
            let header = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.image = icon(section.symbol, appearance: appearance)
            submenu.addItem(header)
            for entry in section.items {
                values.append(entry.value)
                submenu.addItem(item(entry.label.isEmpty ? entry.value : "\(entry.label): \(entry.value)", tag: values.count - 1))
            }
        }
        if !submenu.items.isEmpty { submenu.addItem(.separator()) }
        let copySummary = item("Copy Summary", tag: 0)
        copySummary.image = icon("text.quote", appearance: appearance)
        submenu.addItem(copySummary)
        let copyAll = item("Copy All Details", tag: copyAllTag)
        copyAll.image = icon("doc.on.doc", appearance: appearance)
        submenu.addItem(copyAll)

        let root = NSMenuItem(title: info.summary.isEmpty ? "QuickPeek Info" : shortened(info.summary), action: nil, keyEquivalent: "")
        root.image = icon("info.circle", appearance: appearance)
        root.submenu = submenu
        let menu = NSMenu(title: "")
        menu.addItem(root)
        return (menu, values)
    }

    private static func shortened(_ title: String) -> String {
        title.count > maxTitleLength ? String(title.prefix(maxTitleLength - 1)) + "…" : title
    }

    /// An SF Symbol rasterised in the menu's text colour. Finder loses the template flag of
    /// symbol images, which then render black — invisible on a dark menu.
    static func icon(_ symbol: String, appearance: NSAppearance) -> NSImage? {
        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return nil }
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = isDark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.1, alpha: 1)

        let size = symbolImage.size
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let rect = NSRect(origin: .zero, size: size)
        symbolImage.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }
}
