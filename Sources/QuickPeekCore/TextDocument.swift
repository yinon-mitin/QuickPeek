import Foundation

public enum TextDocumentError: Error, Equatable {
    case binaryContent
}

/// A text file read for previewing: decoded, classified and capped in size.
public struct TextDocument: Sendable {
    public var text: String
    public var kind: FileKind
    /// The file is larger than the byte limit; `text` is its beginning.
    public var isTruncated: Bool

    public static let defaultMaxBytes = 2 * 1024 * 1024

    public static func load(_ url: URL, maxBytes: Int = defaultMaxBytes) throws -> TextDocument {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        let isTruncated = data.count > maxBytes

        guard let text = TextDecoder.decode(isTruncated ? data.prefix(maxBytes) : data, truncated: isTruncated) else {
            throw TextDocumentError.binaryContent
        }
        let kind = FileClassifier.classify(fileName: url.lastPathComponent, prefix: String(text.prefix(256)))
        return TextDocument(text: text, kind: kind, isTruncated: isTruncated)
    }
}
