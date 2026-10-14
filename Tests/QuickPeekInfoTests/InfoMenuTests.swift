import AppKit
import Testing
@testable import QuickPeekInfo

@Suite("InfoMenu")
struct InfoMenuTests {
    @MainActor
    @Test("Summary first, a disabled header per section, copyable values by tag, Copy All last")
    func structure() throws {
        let info = FileInfo(sections: [
            InfoSection("General", symbol: "doc", items: [InfoItem("Name", "a.mkv")]),
            InfoSection("Video", symbol: "video", items: [InfoItem("Codec", "H.264"), InfoItem("Profile", String(repeating: "x", count: 100))]),
        ], summary: "1920×1080 · H.264")
        let (menu, values) = InfoMenu.build(info, action: #selector(NSText.copy(_:)), target: nil)
        let root = try #require(menu.items.first)
        #expect(root.title == "QuickPeek Info")
        let items = try #require(root.submenu?.items)
        #expect(items[0].title == "1920×1080 · H.264")
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
}
