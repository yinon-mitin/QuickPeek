import AppKit
import Foundation

/// Owns the JavaScriptCore highlighter and the Markdown renderer on one background queue, so
/// previews appear instantly as plain text and gain colour when highlighting finishes.
public final class TextServices: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.yinon-mitin.QuickPeek.text", qos: .userInitiated)
    private let vendorDirectory: URL
    // Created lazily on `queue` and only used there.
    private var highlighter: SyntaxHighlighter?
    private var loadFailed = false

    public init(vendorDirectory: URL) {
        self.vendorDirectory = vendorDirectory
    }

    private func loadedHighlighter() -> SyntaxHighlighter? {
        if highlighter == nil && !loadFailed {
            highlighter = try? SyntaxHighlighter(vendorDirectory: vendorDirectory)
            loadFailed = highlighter == nil
        }
        return highlighter
    }

    /// Tokens for the first `SyntaxHighlighter.maxHighlightedLength` units of `code`.
    public func highlight(_ code: String, language: String, completion: @escaping @MainActor @Sendable ([HighlightToken]) -> Void) {
        queue.async {
            let limit = SyntaxHighlighter.maxHighlightedLength
            let string = code as NSString
            let portion = string.length > limit ? string.substring(to: limit) : code
            let tokens = self.loadedHighlighter()?.tokens(portion, language: language) ?? []
            DispatchQueue.main.async { completion(tokens) }
        }
    }

    public func renderMarkdown(_ markdown: String, completion: @escaping @MainActor @Sendable (NSAttributedString?) -> Void) {
        queue.async {
            let rendered = try? MarkdownRenderer(highlighter: self.loadedHighlighter()).render(markdown)
            nonisolated(unsafe) let result = rendered
            DispatchQueue.main.async { completion(result) }
        }
    }
}
