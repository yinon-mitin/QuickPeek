import AppKit
import QuickPeekCore

/// Native views for text documents: code, Markdown, delimited tables and plain text.
@MainActor
public enum DocumentViews {
    public static func view(for document: TextDocument, services: TextServices) -> NSView {
        let notice = document.isTruncated
            ? "File is larger than \(TextDocument.defaultMaxBytes / 1024 / 1024) MB; the rest is not shown."
            : nil
        switch document.kind {
        case .markdown:
            return MarkdownView(markdown: document.text, notice: notice, services: services)
        case .table(let delimiter):
            return DelimitedTableView(text: document.text, delimiter: delimiter, notice: notice)
        case .code(let language):
            return CodeView(text: document.text, language: language, wraps: false, notice: notice, services: services)
        case .notebook:
            return CodeView(text: document.text, language: "json", wraps: false, notice: notice, services: services)
        case .plainText, .archive, .image, .video:
            return CodeView(text: document.text, language: nil, wraps: true, notice: notice, services: services)
        }
    }

    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func noticeText(_ notice: String) -> NSAttributedString {
        NSAttributedString(string: "\n\n" + notice, attributes: [
            .font: NSFont.systemFont(ofSize: 11).withTraits(.italic),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// A read-only, selectable text view inside a scroll view.
    static func makeScrollingTextView(textKit2: Bool, wraps: Bool, inset: NSSize) -> (NSScrollView, NSTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wraps
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView(usingTextLayoutManager: textKit2)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = inset
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if !wraps {
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textView.textContainer?.widthTracksTextView = true
        }
        scrollView.documentView = textView
        return (scrollView, textView)
    }
}

/// Source code and plain text. Shown at once in a monospaced font; colours follow when the
/// background highlighter is done.
@MainActor
public final class CodeView: NSView {
    public let textView: NSTextView

    public init(text: String, language: String?, wraps: Bool, notice: String?, services: TextServices) {
        let (scrollView, textView) = DocumentViews.makeScrollingTextView(textKit2: true, wraps: wraps, inset: NSSize(width: 14, height: 12))
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 700))

        let content = NSMutableAttributedString(string: text, attributes: [.font: DocumentViews.codeFont, .foregroundColor: NSColor.labelColor])
        if let notice { content.append(DocumentViews.noticeText(notice)) }
        textView.textStorage?.setAttributedString(content)

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        if let language {
            services.highlight(text, language: language) { [weak textView] tokens in
                guard let storage = textView?.textStorage, !tokens.isEmpty else { return }
                SyntaxHighlighter.apply(tokens, to: storage, theme: .github, font: DocumentViews.codeFont)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Rendered Markdown. TextKit 1, because TextKit 2 does not lay out NSTextTable yet.
@MainActor
public final class MarkdownView: NSView {
    public let textView: NSTextView

    public init(markdown: String, notice: String?, services: TextServices) {
        let (scrollView, textView) = DocumentViews.makeScrollingTextView(textKit2: false, wraps: true, inset: NSSize(width: 32, height: 24))
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]

        // The source is visible immediately; the rendered document replaces it a moment later.
        textView.textStorage?.setAttributedString(NSAttributedString(string: markdown, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        services.renderMarkdown(markdown) { [weak textView] rendered in
            guard let textView, let rendered else { return }
            let content = NSMutableAttributedString(attributedString: rendered)
            if let notice { content.append(DocumentViews.noticeText(notice)) }
            textView.textStorage?.setAttributedString(content)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// CSV/TSV in a real table: header row as column titles, row numbers, sticky header.
@MainActor
public final class DelimitedTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public static let maxRows = 5_000

    private let header: [String]
    private let rows: [[String]]
    private let tableView = NSTableView()

    public init(text: String, delimiter: Character?, notice: String?) {
        let delimiter = delimiter ?? CSVParser.sniffDelimiter(text)
        let parsed = CSVParser.parse(text, delimiter: delimiter, maxRows: Self.maxRows + 1)
        header = parsed.first ?? []
        rows = Array(parsed.dropFirst().prefix(Self.maxRows))
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 700))

        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        let numbers = NSTableColumn(identifier: .init("#"))
        numbers.title = ""
        numbers.width = CGFloat(max(3, String(rows.count).count)) * 8 + 12
        tableView.addTableColumn(numbers)
        for index in 0..<columnCount {
            let column = NSTableColumn(identifier: .init(String(index)))
            column.title = index < header.count ? header[index] : ""
            let sample = rows.prefix(100).map { index < $0.count ? $0[index].count : 0 } + [column.title.count]
            column.width = min(400, max(60, CGFloat(sample.max() ?? 8) * 7.5 + 16))
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .plain
        tableView.rowHeight = 20
        tableView.dataSource = self
        tableView.delegate = self

        // A one-line notice below the table when rows were cut; the table fills the rest.
        let noticeText = notice ?? (parsed.count > Self.maxRows + 1 ? "Showing the first \(Self.maxRows.formatted()) rows." : nil)
        let noticeHeight: CGFloat = noticeText == nil ? 0 : 22
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: noticeHeight, width: bounds.width, height: bounds.height - noticeHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        if let noticeText {
            let label = NSTextField(labelWithString: noticeText)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 12, y: 3, width: bounds.width - 24, height: 16)
            label.autoresizingMask = [.width, .maxYMargin]
            addSubview(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            field.font = .systemFont(ofSize: 12)
            return field
        }()
        if identifier.rawValue == "#" {
            cell.stringValue = String(row + 1)
            cell.textColor = .tertiaryLabelColor
            cell.alignment = .right
            cell.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        } else if let index = Int(identifier.rawValue) {
            cell.stringValue = index < rows[row].count ? rows[row][index] : ""
        }
        return cell
    }
}

extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)), size: pointSize) ?? self
    }
}
