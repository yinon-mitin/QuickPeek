import AppKit
import Foundation

/// Markdown → attributed text with Foundation's GitHub-flavoured parser (cmark-gfm) and AppKit
/// text tables. Raw HTML is shown as text, never interpreted, and nothing is fetched.
public final class MarkdownRenderer {
    private let highlighter: SyntaxHighlighter?
    private let bodySize: CGFloat = 14
    private let indentStep: CGFloat = 22

    public init(highlighter: SyntaxHighlighter?) {
        self.highlighter = highlighter
    }

    public func render(_ markdown: String) throws -> NSAttributedString {
        let parsed = try AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        )

        let output = NSMutableAttributedString()
        var block: (id: Int, intent: PresentationIntent?, content: NSMutableAttributedString)?
        var context = Context()

        func flush() {
            guard let current = block else { return }
            if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
            output.append(finish(current.content, intent: current.intent, context: &context))
            block = nil
        }

        for run in parsed.runs {
            let intent = run.presentationIntent
            let id = intent?.components.first?.identity ?? -1
            if block?.id != id {
                flush()
                block = (id, intent, NSMutableAttributedString())
            }
            block?.content.append(inline(String(parsed[run.range].characters), run: run, intent: intent))
        }
        flush()
        return output
    }

    // MARK: - Blocks

    /// State that spans blocks: which list items already have their bullet, and one text table per table.
    private struct Context {
        var listItemsWithMarker: Set<Int> = []
        var tables: [Int: NSTextTable] = [:]
    }

    private func finish(_ content: NSMutableAttributedString, intent: PresentationIntent?, context: inout Context) -> NSAttributedString {
        let components = intent?.components ?? []
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 10
        style.lineHeightMultiple = 1.15

        var indent: CGFloat = 0
        var listItem: (id: Int, ordinal: Int, ordered: Bool, depth: Int)?
        var quoteDepth = 0
        var listDepth = 0
        for (index, component) in components.enumerated() {
            switch component.kind {
            case .listItem(let ordinal):
                listDepth += 1
                let ordered = index + 1 < components.count && components[index + 1].kind == .orderedList
                if listItem == nil { listItem = (component.identity, ordinal, ordered, 0) }
            case .blockQuote:
                quoteDepth += 1
            default:
                break
            }
        }
        indent = CGFloat(listDepth) * indentStep + CGFloat(quoteDepth) * 16
        style.headIndent = indent
        style.firstLineHeadIndent = indent

        let leaf = components.first?.kind
        switch leaf {
        case .header(let level):
            let sizes: [CGFloat] = [26, 21, 17, 15, 14, 13]
            let size = sizes[min(max(level, 1), 6) - 1]
            content.addAttribute(.font, value: font(size: size, bold: true), range: content.fullRange)
            style.paragraphSpacingBefore = level <= 2 ? 16 : 10
            if level == 6 { content.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: content.fullRange) }

        case .codeBlock(let language):
            let code = content.string.hasSuffix("\n") ? String(content.string.dropLast()) : content.string
            let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let highlighted: NSAttributedString
            if let language, let highlighter, highlighter.supports(language) {
                highlighted = highlighter.highlight(code, language: language, font: font)
            } else {
                highlighted = NSAttributedString(string: code, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            }
            content.setAttributedString(highlighted)
            let box = NSTextBlock()
            box.backgroundColor = Self.codeBackground
            box.setContentWidth(100, type: .percentageValueType)
            box.setWidth(10, type: .absoluteValueType, for: .padding)
            box.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
            box.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
            style.textBlocks = [box]
            style.lineHeightMultiple = 1.05
            style.paragraphSpacing = 0

        case .tableCell(let column):
            guard let tableComponent = components.first(where: { if case .table = $0.kind { true } else { false } }),
                  case .table(let columns) = tableComponent.kind else { break }
            let table = context.tables[tableComponent.identity] ?? {
                let table = NSTextTable()
                table.numberOfColumns = max(columns.count, 1)
                table.collapsesBorders = true
                table.setContentWidth(100, type: .percentageValueType)
                return table
            }()
            context.tables[tableComponent.identity] = table

            var row = 0
            var isHeader = false
            for component in components {
                if case .tableRow(let index) = component.kind { row = index }
                if case .tableHeaderRow = component.kind { isHeader = true }
            }
            let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            cell.setWidth(0.5, type: .absoluteValueType, for: .border)
            cell.setBorderColor(.separatorColor)
            cell.setWidth(6, type: .absoluteValueType, for: .padding)
            if isHeader {
                cell.backgroundColor = Self.codeBackground
                content.applyFontTraits(.boldFontMask, range: content.fullRange)
            }
            style.textBlocks = [cell]
            style.paragraphSpacing = 0
            style.headIndent = 0
            style.firstLineHeadIndent = 0
            if column < columns.count {
                switch columns[column].alignment {
                case .center: style.alignment = .center
                case .right: style.alignment = .right
                default: style.alignment = .left
                }
            }

        case .thematicBreak:
            content.setAttributedString(NSAttributedString(string: "⸻", attributes: [
                .font: font(size: bodySize, bold: false), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            style.alignment = .center

        default:
            break
        }

        let isCodeBlock: Bool = { if case .codeBlock = leaf { true } else { false } }()
        if quoteDepth > 0, !isCodeBlock {
            content.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: content.fullRange)
        }

        // The first paragraph of a list item carries its marker, hanging in the indent.
        if let listItem, !context.listItemsWithMarker.contains(listItem.id) {
            context.listItemsWithMarker.insert(listItem.id)
            var marker = listItem.ordered ? "\(listItem.ordinal)." : ["•", "◦", "▪"][(listDepth - 1) % 3]
            for (box, checkbox) in [("[ ] ", "☐"), ("[x] ", "☑"), ("[X] ", "☑")] where content.string.hasPrefix(box) {
                content.deleteCharacters(in: NSRange(location: 0, length: box.count))
                marker = checkbox
            }
            let attributes = content.length > 0 ? content.attributes(at: 0, effectiveRange: nil) : [.font: font(size: bodySize, bold: false)]
            content.insert(NSAttributedString(string: marker + "\t", attributes: attributes), at: 0)
            style.firstLineHeadIndent = indent - indentStep
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            style.paragraphSpacing = 4
        }

        content.addAttribute(.paragraphStyle, value: style, range: content.fullRange)
        return content
    }

    // MARK: - Inline

    private func inline(_ text: String, run: AttributedString.Runs.Run, intent: PresentationIntent?) -> NSAttributedString {
        let inline = run.inlinePresentationIntent ?? []
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
        var string = text

        if inline.contains(.code) || inline.contains(.inlineHTML) || inline.contains(.blockHTML) {
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: bodySize * 0.88, weight: inline.contains(.stronglyEmphasized) ? .bold : .regular)
            if inline.contains(.code) { attributes[.backgroundColor] = Self.codeBackground }
            if !inline.contains(.code) { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
        } else {
            var font = font(size: bodySize, bold: inline.contains(.stronglyEmphasized))
            if inline.contains(.emphasized) {
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)), size: font.pointSize) ?? font
            }
            attributes[.font] = font
        }
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = run.link {
            attributes[.link] = link
            attributes[.foregroundColor] = NSColor.linkColor
        }
        if run.imageURL != nil {
            // Images are not loaded: Quick Look's sandbox only grants access to the previewed file.
            string = "🖼 " + text
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        // Hard breaks stay inside their paragraph (and inside table cells).
        let isCode: Bool = { if case .codeBlock = intent?.components.first?.kind { true } else { false } }()
        if !isCode {
            string = string.replacingOccurrences(of: "\n", with: "\u{2028}")
        }
        return NSAttributedString(string: string, attributes: attributes)
    }

    private func font(size: CGFloat, bold: Bool) -> NSFont {
        bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    }

    static let codeBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0x161B22) : NSColor(hex: 0xF6F8FA)
    }
}

extension NSAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}
