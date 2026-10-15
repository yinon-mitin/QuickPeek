import Foundation
import QuickPeekCore
import UniformTypeIdentifiers

/// A file inside an archive, read into memory for previewing; nothing is extracted to disk.
public enum ArchivePeek: Sendable {
    case text(TextDocument)
    case image(Data)
    case pdf(Data)
    case unavailable(Reason)

    public enum Reason: Sendable, Equatable {
        case encrypted
        case tooLarge(Int64)
        /// Audio and video: a player for one stream inside an archive is out of scope.
        case media
        case binary
        /// The entry was not found, or the archive took too long to reach it.
        case unreadable
    }

    /// Images and PDFs are read whole; text only needs its beginning.
    public static let wholeFileLimit: Int64 = 50 * 1024 * 1024

    enum Plan: Equatable {
        case text, image, pdf
        case skip(Reason)
    }

    public static func read(_ entry: ArchiveEntry, in archive: URL, timeLimit: TimeInterval = 5) -> ArchivePeek {
        let name = (entry.path as NSString).lastPathComponent
        let data = { (limit: Int) in
            (try? ArchiveListing.data(ofEntry: entry.path, in: archive, maxBytes: limit, timeLimit: timeLimit)) ?? nil
        }
        switch plan(name: name, size: entry.size, isEncrypted: entry.isEncrypted) {
        case .skip(let reason):
            return .unavailable(reason)
        case .image:
            return data(Int(wholeFileLimit)).map(ArchivePeek.image) ?? .unavailable(.unreadable)
        case .pdf:
            return data(Int(wholeFileLimit)).map(ArchivePeek.pdf) ?? .unavailable(.unreadable)
        case .text:
            guard let bytes = data(TextDocument.defaultMaxBytes + 1) else { return .unavailable(.unreadable) }
            guard let document = try? TextDocument.decode(bytes, fileName: name) else { return .unavailable(.binary) }
            return .text(document)
        }
    }

    /// Decided from the name and size alone, before anything is decompressed.
    static func plan(name: String, size: Int64?, isEncrypted: Bool) -> Plan {
        if isEncrypted { return .skip(.encrypted) }
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if let type, type.conforms(to: .image) || type.conforms(to: .pdf) {
            if let size, size > wholeFileLimit { return .skip(.tooLarge(size)) }
            return type.conforms(to: .pdf) ? .pdf : .image
        }
        if let type, type.conforms(to: .audiovisualContent) { return .skip(.media) }
        // Formats that are never text; anything else is read and judged by its bytes.
        if let type, [.archive, .executable, .diskImage, .font, .database].contains(where: type.conforms(to:)) {
            return .skip(.binary)
        }
        return .text
    }
}
