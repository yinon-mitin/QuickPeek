import AppKit
import Foundation
import Testing
@testable import QuickPeekText

let vendorDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Vendor", isDirectory: true)

@Suite("SyntaxHighlighter")
struct SyntaxHighlighterTests {
    let highlighter: SyntaxHighlighter

    init() throws {
        highlighter = try SyntaxHighlighter(vendorDirectory: vendorDirectory)
    }

    private func scope(of text: String, in code: String, tokens: [HighlightToken]) -> String? {
        let range = (code as NSString).range(of: text)
        return tokens.first { NSIntersectionRange($0.range, range).length == range.length }?.scope
    }

    @Test("YAML keys, values and comments get scopes")
    func yaml() throws {
        let code = "name: QuickPeek # app\ncount: 3\n"
        let tokens = try #require(highlighter.tokens(code, language: "yaml"))
        #expect(scope(of: "name", in: code, tokens: tokens) == "attr")
        #expect(scope(of: "# app", in: code, tokens: tokens) == "comment")
        #expect(scope(of: "3", in: code, tokens: tokens) == "number")
    }

    @Test("Nested scopes keep the most specific one")
    func nested() throws {
        let code = "func greet() -> String { return \"hi\" }"
        let tokens = try #require(highlighter.tokens(code, language: "swift"))
        #expect(scope(of: "func", in: code, tokens: tokens) == "keyword")
        #expect(scope(of: "greet", in: code, tokens: tokens) == "title.function")
        #expect(scope(of: "\"hi\"", in: code, tokens: tokens) == "string")
    }

    @Test("Token ranges index the original text, including characters HTML escapes")
    func escaping() throws {
        let code = "if a < b && c > \"d\" { x = 'é😀' }"
        let tokens = try #require(highlighter.tokens(code, language: "javascript"))
        let text = highlighter.highlight(code, language: "javascript")
        #expect(text.string == code)
        for token in tokens {
            #expect(NSMaxRange(token.range) <= (code as NSString).length)
        }
    }

    @Test("Languages from the extra grammar files are available")
    func extraLanguages() throws {
        let code = "FROM swift:6.2\nRUN swift build\n"
        let tokens = try #require(highlighter.tokens(code, language: "dockerfile"))
        #expect(scope(of: "FROM", in: code, tokens: tokens) == "keyword")
    }

    @Test("Unknown languages fall back to plain text")
    func unknown() {
        #expect(highlighter.tokens("x", language: "no-such-language") == nil)
        #expect(highlighter.highlight("x", language: "no-such-language").string == "x")
    }

    @Test("Highlighted text carries the theme colour and a monospaced font")
    func attributes() throws {
        let code = "return 42"
        let text = highlighter.highlight(code, language: "swift")
        let keywordColor = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(keywordColor == CodeTheme.github.color(for: "keyword"))
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch)
    }

    @Test("Theme lookup falls back from sub-scopes to their parent")
    func themeFallback() {
        let theme = CodeTheme.github
        #expect(theme.color(for: "title.function") == theme.color(for: "title"))
        #expect(theme.color(for: "no-such-scope") == nil)
    }

    @Test("Turning 200 KB of highlight.js output into attributed text is fast")
    func performance() throws {
        // JavaScript speed depends on whether the process may JIT; this measures QuickPeek's part.
        let line = "let value = compute(index: 42, name: \"item\") // note\n"
        let code = String(repeating: line, count: 4_000)
        let markup = try #require(highlighter.markup(code, language: "swift"))
        let start = Date()
        let tokens = try #require(SyntaxHighlighter.tokens(fromHighlightedHTML: markup, expectedLength: (code as NSString).length))
        let text = NSMutableAttributedString(string: code)
        SyntaxHighlighter.apply(tokens, to: text, theme: .github, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        #expect(Date().timeIntervalSince(start) < 0.5)
    }
}
