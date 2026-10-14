/// What a previewed file is, and therefore which renderer handles it.
public enum FileKind: Equatable, Sendable {
    /// Source or config text, highlighted with the given highlight.js language name.
    case code(language: String)
    /// Text without a known syntax.
    case plainText
    case markdown
    /// Delimited table; `nil` means the delimiter is sniffed from the content.
    case table(delimiter: Character?)
    case notebook
    case archive
    case image
    case video
}
