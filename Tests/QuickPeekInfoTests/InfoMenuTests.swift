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

    /// Finder redraws extension menus in its own process and loses SF Symbols' template flag,
    /// so icons are drawn ahead of time in a colour that suits the current appearance.
    @Test("Icons are light in dark mode and dark in light mode", arguments: [
        (NSAppearance.Name.darkAqua, true), (NSAppearance.Name.aqua, false),
    ])
    func iconContrast(appearance: NSAppearance.Name, expectLight: Bool) throws {
        let (menu, _) = build(info, appearance: appearance)
        let image = try #require(menu.items.first?.image)
        #expect(!image.isTemplate)
        let brightness = try #require(Self.averageBrightness(of: image))
        #expect(expectLight ? brightness > 0.7 : brightness < 0.3)
    }

    /// Mean brightness of the opaque pixels.
    static func averageBrightness(of image: NSImage) -> Double? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0.0, count = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 128 {
            let alpha = Double(pixels[index + 3])
            total += (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])) / 3 / alpha
            count += 1
        }
        return count > 0 ? total / count : nil
    }
}
