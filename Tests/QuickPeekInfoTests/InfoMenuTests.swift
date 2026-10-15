import AppKit
import Testing
@testable import QuickPeekInfo

@Suite("InfoMenu")
@MainActor
struct InfoMenuTests {
    let info = FileInfo(sections: [
        InfoSection("General", symbol: "doc", items: [InfoItem("Name", "a.mkv")]),
        InfoSection("Video", symbol: "video", items: [InfoItem("Codec", "H.264"), InfoItem("Profile", String(repeating: "x", count: 100))]),
    ], summary: "1920×1080 · H.264 · 24 fps · 1:42:05")

    private func build(_ info: FileInfo, appearance: NSAppearance.Name = .aqua) -> (menu: NSMenu, values: [String]) {
        InfoMenu.build(info, action: #selector(NSText.copy(_:)), target: nil, appearance: NSAppearance(named: appearance)!)
    }

    @Test("The menu item is the file's summary; the submenu has a disabled header per section")
    func structure() throws {
        let (menu, values) = build(info)
        let root = try #require(menu.items.first)
        #expect(root.title == "1920×1080 · H.264 · 24 fps · 1:42:05")
        let items = try #require(root.submenu?.items)
        #expect(!items.contains { $0.title == "General" }) // Finder already shows name, size and dates
        let header = try #require(items.first { $0.title == "Video" })
        #expect(!header.isEnabled)
        let codec = try #require(items.first { $0.title == "Codec: H.264" })
        #expect(values[codec.tag] == "H.264")
        let long = try #require(items.first { $0.title.hasPrefix("Profile:") })
        #expect(long.title.count == InfoMenu.maxTitleLength)
        #expect(values[long.tag].count == 100) // the full value is copied
        #expect(items.last?.tag == InfoMenu.copyAllTag)
    }

    @Test("Files without a summary fall back to the app's name")
    func fallbackTitle() throws {
        let (menu, _) = build(FileInfo(sections: [], summary: ""))
        #expect(menu.items.first?.title == "QuickPeek Info")
    }

    /// Finder redraws extension menus in its own process, where SF Symbols' vector images and
    /// the template flag do not survive. Icons are bitmaps in the text colour of the system theme.
    @Test("Icons are bitmaps in the menu text colour: dark in light mode, light in dark mode")
    func themedIcons() throws {
        for (appearance, isDark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let (menu, _) = build(info, appearance: appearance)
            let image = try #require(menu.items.first?.image)
            #expect(image.representations.allSatisfy { $0 is NSBitmapImageRep })
            let (coverage, brightness) = try #require(Self.measure(image))
            #expect(coverage > 0.05 && coverage < 0.9) // a glyph, not an empty or solid square
            #expect(isDark ? brightness > 0.8 : brightness < 0.2, "\(appearance.rawValue): \(brightness)")
        }
    }

    /// Share of pixels that are mostly opaque, and their mean brightness (0 black, 1 white).
    static func measure(_ image: NSImage) -> (coverage: Double, brightness: Double)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let opaque = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 128 }
        guard !opaque.isEmpty else { return (0, 0) }
        // Premultiplied: divide the red channel by alpha to get the colour back.
        let brightness = opaque.map { Double(pixels[$0 - 3]) / Double(pixels[$0]) }.reduce(0, +) / Double(opaque.count)
        return (Double(opaque.count) / Double(width * height), brightness)
    }
}
