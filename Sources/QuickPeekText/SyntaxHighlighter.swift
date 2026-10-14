import AppKit
import JavaScriptCore

public struct HighlightToken: Equatable, Sendable {
    /// UTF-16 range in the highlighted text (NSString indexing, as NSAttributedString uses).
    public var range: NSRange
    /// highlight.js scope with sub-scopes joined by dots, for example "title.function".
    public var scope: String
}

public enum HighlighterError: Error {
    case javaScript(String)
}

/// Runs highlight.js inside JavaScriptCore — in process, no WebKit — and turns its output
/// into token ranges and attributed text. Not thread-safe: use one instance per thread.
public final class SyntaxHighlighter {
    /// Beyond this many UTF-16 units the rest of a file is shown unhighlighted, so huge files open fast.
    public static let maxHighlightedLength = 512 * 1024

    private let context: JSContext
    private let highlight: JSValue

    public init(vendorDirectory: URL) throws {
        guard let context = JSContext() else { throw HighlighterError.javaScript("JavaScriptCore unavailable") }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }

        func evaluate(_ file: URL) throws {
            context.evaluateScript(try String(contentsOf: file, encoding: .utf8), withSourceURL: file)
            if let failure { throw HighlighterError.javaScript("\(file.lastPathComponent): \(failure)") }
        }
        try evaluate(vendorDirectory.appendingPathComponent("highlight.min.js"))
        let languages = vendorDirectory.appendingPathComponent("languages", isDirectory: true)
        for file in try FileManager.default.contentsOfDirectory(at: languages, includingPropertiesForKeys: nil)
            where file.pathExtension == "js" {
            try evaluate(file)
        }
        context.evaluateScript("""
        function quickPeekHighlight(code, language) {
          if (!hljs.getLanguage(language)) { return null; }
          return hljs.highlight(code, { language: language, ignoreIllegals: true }).value;
        }
        """)
        guard let highlight = context.objectForKeyedSubscript("quickPeekHighlight"), !highlight.isUndefined else {
            throw HighlighterError.javaScript(failure ?? "highlight.js did not load")
        }
        self.context = context
        self.highlight = highlight
    }

    public func supports(_ language: String) -> Bool {
        context.evaluateScript("hljs.getLanguage(\(Self.javaScriptString(language))) !== undefined")?.toBool() ?? false
    }

    /// Scoped ranges of `code`, or nil when the language is unknown.
    public func tokens(_ code: String, language: String) -> [HighlightToken]? {
        guard let markup = markup(code, language: language) else { return nil }
        return Self.tokens(fromHighlightedHTML: markup, expectedLength: (code as NSString).length)
    }

    /// highlight.js markup for `code`, or nil when the language is unknown.
    func markup(_ code: String, language: String) -> String? {
        guard let html = highlight.call(withArguments: [code, language]), html.isString else { return nil }
        return html.toString()
    }

    public func highlight(
        _ code: String,
        language: String,
        theme: CodeTheme = .github,
        font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(string: code, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let length = (code as NSString).length
        let highlighted = length > Self.maxHighlightedLength
            ? String((code as NSString).substring(to: Self.lineBoundary(in: code, near: Self.maxHighlightedLength)))
            : code
        guard let tokens = tokens(highlighted, language: language) else { return text }
        Self.apply(tokens, to: text, theme: theme, font: font)
        return text
    }

    /// Colours `text` in place; also used to recolour text that is already on screen.
    public static func apply(_ tokens: [HighlightToken], to text: NSMutableAttributedString, theme: CodeTheme, font: NSFont) {
        var cache: [String: [NSAttributedString.Key: Any]] = [:]
        text.beginEditing()
        for token in tokens where NSMaxRange(token.range) <= text.length {
            let attributes = cache[token.scope] ?? theme.attributes(for: token.scope, font: font)
            cache[token.scope] = attributes
            text.addAttributes(attributes, range: token.range)
        }
        text.endEditing()
    }

    // MARK: - highlight.js output

    /// highlight.js returns the input with `<span class="hljs-…">` wrappers and HTML escaping.
    /// Walks that markup, tracking the position in the unescaped text, and records the
    /// innermost scope for each run of text. Returns nil if the text does not line up.
    static func tokens(fromHighlightedHTML html: String, expectedLength: Int) -> [HighlightToken]? {
        var tokens: [HighlightToken] = []
        var scopes: [String?] = []
        var position = 0
        var runStart = 0

        func closeRun() {
            guard position > runStart, let scope = scopes.last(where: { $0 != nil }) ?? nil else { return }
            if var last = tokens.last, last.scope == scope, NSMaxRange(last.range) == runStart {
                last.range.length += position - runStart
                tokens[tokens.count - 1] = last
            } else {
                tokens.append(HighlightToken(range: NSRange(location: runStart, length: position - runStart), scope: scope))
            }
        }

        // Markup is ASCII, so the native UTF-8 bytes can be scanned directly. Text positions
        // count UTF-16 units (NSString indexing): one per scalar, two for scalars above U+FFFF.
        var html = html
        html.makeContiguousUTF8()
        var scopeCache: [[UInt8]: String?] = [:]
        let parsed: Bool = html.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "<") {
                    var end = index + 1
                    while end < bytes.count && bytes[end] != UInt8(ascii: ">") { end += 1 }
                    guard end < bytes.count else { return false }
                    closeRun()
                    runStart = position
                    if index + 1 < end && bytes[index + 1] == UInt8(ascii: "/") {
                        _ = scopes.popLast()
                    } else {
                        // A file has thousands of tags but only a few distinct ones.
                        let tag = [UInt8](bytes[(index + 1)..<end])
                        if let cached = scopeCache[tag] {
                            scopes.append(cached)
                        } else {
                            let scope = scope(fromTag: String(decoding: tag, as: UTF8.self))
                            scopeCache[tag] = scope
                            scopes.append(scope)
                        }
                    }
                    index = end + 1
                } else if byte == UInt8(ascii: "&") {
                    var end = index + 1
                    while end < bytes.count && end - index < 8 && bytes[end] != UInt8(ascii: ";") { end += 1 }
                    guard end < bytes.count, bytes[end] == UInt8(ascii: ";") else { return false }
                    position += 1
                    index = end + 1
                } else {
                    if byte & 0xC0 != 0x80 { position += 1 }
                    if byte >= 0xF0 { position += 1 }
                    index += 1
                }
            }
            return true
        } ?? false
        guard parsed else { return nil }
        closeRun()
        return position == expectedLength ? tokens : nil
    }

    /// `span class="hljs-title function_"` → "title.function". Sub-language wrappers
    /// (`class="language-css"`) carry no colour of their own.
    private static func scope(fromTag tag: String) -> String? {
        guard let start = tag.range(of: "class=\""), let end = tag[start.upperBound...].firstIndex(of: "\"") else { return nil }
        let classes = tag[start.upperBound..<end].split(separator: " ")
        guard let first = classes.first, first.hasPrefix("hljs-") else { return nil }
        let parts = [String(first.dropFirst(5))] + classes.dropFirst().map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "_")) }
        return parts.joined(separator: ".")
    }

    /// Cuts at the end of a line so highlighting never stops mid-token.
    private static func lineBoundary(in text: String, near limit: Int) -> Int {
        let string = text as NSString
        let newline = string.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: limit))
        return newline.location == NSNotFound ? limit : newline.location + 1
    }

    private static func javaScriptString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
