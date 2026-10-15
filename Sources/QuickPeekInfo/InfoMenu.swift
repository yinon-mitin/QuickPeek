import AppKit

/// Builds the context menu for Finder: the file's summary as the menu item, details in its
/// submenu. Finder copies the menu into its own process keeping only titles, images, actions
/// and tags, so each item's tag indexes `values` (tag -1 means "copy everything").
public enum InfoMenu {
    public static let copyAllTag = -1
    static let maxTitleLength = 70

    /// `appearance` is the system's (light or dark): icons are drawn in its text colour.
    public static func build(_ info: FileInfo, action: Selector, target: AnyObject?,
                             appearance: NSAppearance) -> (menu: NSMenu, values: [String]) {
        var values = [info.summary]
        func icon(_ symbol: String) -> NSImage? { InfoMenu.icon(symbol, appearance: appearance) }
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
            header.image = icon(section.symbol)
            submenu.addItem(header)
            for entry in section.items {
                values.append(entry.value)
                submenu.addItem(item(entry.label.isEmpty ? entry.value : "\(entry.label): \(entry.value)", tag: values.count - 1))
            }
        }
        if !submenu.items.isEmpty { submenu.addItem(.separator()) }
        let copySummary = item("Copy Summary", tag: 0)
        copySummary.image = icon("text.quote")
        submenu.addItem(copySummary)
        let copyAll = item("Copy All Details", tag: copyAllTag)
        copyAll.image = icon("doc.on.doc")
        submenu.addItem(copyAll)

        let root = NSMenuItem(title: info.summary.isEmpty ? "QuickPeek Info" : shortened(info.summary), action: nil, keyEquivalent: "")
        root.image = icon("info.circle")
        root.submenu = submenu
        let menu = NSMenu(title: "")
        menu.addItem(root)
        return (menu, values)
    }

    private static func shortened(_ title: String) -> String {
        title.count > maxTitleLength ? String(title.prefix(maxTitleLength - 1)) + "…" : title
    }

    /// An SF Symbol rasterised into a bitmap in the menu text colour of `appearance`. Finder
    /// rebuilds extension menus in its own process: SF Symbols' vector images do not survive the
    /// trip, and neither does `isTemplate`, so the icon cannot rely on Finder to tint it and
    /// would stay black in dark mode. It is still marked as a template, which costs nothing if
    /// Finder ever honours the flag (and would make it white on the selection highlight).
    static func icon(_ symbol: String, appearance: NSAppearance) -> NSImage? {
        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return nil }
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
        var color = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .black
        }
        color.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }
}
