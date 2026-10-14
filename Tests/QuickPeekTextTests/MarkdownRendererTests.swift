import AppKit
import Foundation
import Testing
@testable import QuickPeekText

@Suite("MarkdownRenderer")
struct MarkdownRendererTests {
    let renderer: MarkdownRenderer

    init() throws {
        renderer = MarkdownRenderer(highlighter: try SyntaxHighlighter(vendorDirectory: vendorDirectory))
    }

    private func font(of substring: String, in text: NSAttributedString) throws -> NSFont {
        let range = (text.string as NSString).range(of: substring)
        try #require(range.location != NSNotFound, "\(substring) not found in \(text.string)")
        return try #require(text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }

    private func paragraphStyle(of substring: String, in text: NSAttributedString) throws -> NSParagraphStyle {
        let range = (text.string as NSString).range(of: substring)
        try #require(range.location != NSNotFound)
        return try #require(text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
    }

    @Test("Blocks are separated and keep their order")
    func blocks() throws {
        let text = try renderer.render("# Title\n\nFirst paragraph.\n\nSecond paragraph.")
        #expect(text.string == "Title\nFirst paragraph.\nSecond paragraph.")
    }

    @Test("Headings are larger and bold, body is regular")
    func headings() throws {
        let text = try renderer.render("# Big\n\n### Small\n\nBody")
        let big = try font(of: "Big", in: text), small = try font(of: "Small", in: text), body = try font(of: "Body", in: text)
        #expect(big.pointSize > small.pointSize)
        #expect(small.pointSize > body.pointSize)
        #expect(big.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(!body.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test("Inline emphasis, code, strikethrough and links")
    func inline() throws {
        let text = try renderer.render("A **bold** _soft_ `code` ~~gone~~ [site](https://example.com).")
        #expect(text.string == "A bold soft code gone site.")
        #expect(try font(of: "bold", in: text).fontDescriptor.symbolicTraits.contains(.bold))
        #expect(try font(of: "soft", in: text).fontDescriptor.symbolicTraits.contains(.italic))
        #expect(try font(of: "code", in: text).isFixedPitch)
        let gone = (text.string as NSString).range(of: "gone")
        #expect(text.attribute(.strikethroughStyle, at: gone.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        let site = (text.string as NSString).range(of: "site")
        #expect(text.attribute(.link, at: site.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
    }

    @Test("Lists get bullets or numbers and a hanging indent; nesting indents further")
    func lists() throws {
        let text = try renderer.render("- one\n- two\n  1. inner\n\n3. three")
        #expect(text.string.contains("•\tone"))
        #expect(text.string.contains("1.\tinner"))
        #expect(text.string.contains("3.\tthree"))
        let outer = try paragraphStyle(of: "one", in: text), inner = try paragraphStyle(of: "inner", in: text)
        #expect(inner.headIndent > outer.headIndent)
        #expect(outer.headIndent > outer.firstLineHeadIndent)
    }

    @Test("Task list items show checkboxes")
    func taskLists() throws {
        let text = try renderer.render("- [ ] todo\n- [x] done")
        #expect(text.string == "☐\ttodo\n☑\tdone")
    }

    @Test("Code blocks are monospaced, shaded and highlighted for their language")
    func codeBlocks() throws {
        let text = try renderer.render("```swift\nlet answer = 42\n```")
        #expect(text.string == "let answer = 42")
        #expect(try font(of: "answer", in: text).isFixedPitch)
        let keyword = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(keyword == CodeTheme.github.color(for: "keyword"))
        let style = try paragraphStyle(of: "answer", in: text)
        #expect(style.textBlocks.first?.backgroundColor != nil)
    }

    @Test("Block quotes are indented")
    func quotes() throws {
        let text = try renderer.render("> quoted\n\nplain")
        #expect(try paragraphStyle(of: "quoted", in: text).headIndent > (try paragraphStyle(of: "plain", in: text)).headIndent)
    }

    @Test("Tables become text table cells with a bold header row")
    func tables() throws {
        let text = try renderer.render("| Name | Size |\n|------|-----:|\n| a.txt | 1 KB |\n| b.bin | 2 KB |")
        let style = try paragraphStyle(of: "b.bin", in: text)
        let cell = try #require(style.textBlocks.first as? NSTextTableBlock)
        #expect(cell.table.numberOfColumns == 2)
        #expect(cell.startingRow == 2)
        #expect(cell.startingColumn == 0)
        #expect(try font(of: "Name", in: text).fontDescriptor.symbolicTraits.contains(.bold))
        let sizeCell = try #require((try paragraphStyle(of: "2 KB", in: text)).textBlocks.first as? NSTextTableBlock)
        #expect(sizeCell.startingColumn == 1)
        #expect(try paragraphStyle(of: "2 KB", in: text).alignment == .right)
    }

    @Test("Raw HTML is not interpreted")
    func html() throws {
        let text = try renderer.render("<script>alert(1)</script>\n\nSafe")
        #expect(text.string.contains("Safe"))
        #expect(text.attribute(.link, at: 0, effectiveRange: nil) == nil)
    }
}
