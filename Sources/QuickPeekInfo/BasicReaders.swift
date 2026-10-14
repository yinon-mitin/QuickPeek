import CoreText
import Foundation
import PDFKit
import QuickPeekCore
import QuickPeekFormats
import UniformTypeIdentifiers

// MARK: - Text

enum TextInfo: InfoReader {
    /// Reading more than this for line statistics is not worth the wait in a menu.
    static let maxBytes = 8 * 1024 * 1024

    static func canRead(_ type: UTType, url: URL) -> Bool {
        type.conforms(to: .text) || type.conforms(to: .sourceCode)
            || FileClassifier.classify(fileName: url.lastPathComponent, prefix: nil) != .plainText
    }

    static func read(_ url: URL, format: InfoFormat) throws -> (sections: [InfoSection], summary: String?) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        let truncated = data.count > maxBytes
        guard let (text, encoding) = TextDecoder.detect(truncated ? data.prefix(maxBytes) : data) else {
            throw TextDocumentError.binaryContent
        }

        var lf = 0, crlf = 0, cr = 0
        var previousWasCR = false
        for unit in text.utf16 {
            if unit == 0x0A {
                if previousWasCR { crlf += 1; cr -= 1 } else { lf += 1 }
            } else if unit == 0x0D {
                cr += 1
            }
            previousWasCR = unit == 0x0D
        }
        let breaks = lf + crlf + cr
        // Check the last UTF-16 unit: "\r\n" is a single Character, so hasSuffix("\n") misses it.
        let endsWithBreak = text.utf16.last == 0x0A || text.utf16.last == 0x0D
        let lines = text.isEmpty ? 0 : breaks + (endsWithBreak ? 0 : 1)
        let endings: String
        switch (lf > 0, crlf > 0, cr > 0) {
        case (true, false, false): endings = "LF (Unix)"
        case (false, true, false): endings = "CRLF (Windows)"
        case (false, false, true): endings = "CR (classic Mac)"
        case (false, false, false): endings = "None"
        default: endings = "Mixed"
        }

        var items = [
            InfoItem("Encoding", encoding),
            InfoItem("Line endings", endings),
            InfoItem("Lines", format.number(lines) + (truncated ? "+" : "")),
            InfoItem("Characters", format.number(text.count) + (truncated ? "+" : "")),
        ]
        var summary = "\(format.number(lines)) lines"
        if case .code(let language) = FileClassifier.classify(fileName: url.lastPathComponent, prefix: String(text.prefix(256))) {
            let name = languageNames[language] ?? language.capitalized
            items.insert(InfoItem("Language", name), at: 0)
            summary = "\(name) · \(summary)"
        }
        return ([InfoSection("Text", symbol: "text.alignleft", items: items)], summary)
    }

    static let languageNames: [String: String] = [
        "yaml": "YAML", "json": "JSON", "ini": "INI/TOML", "xml": "XML/HTML", "swift": "Swift", "python": "Python",
        "ruby": "Ruby", "javascript": "JavaScript", "typescript": "TypeScript", "go": "Go", "rust": "Rust", "c": "C",
        "cpp": "C++", "objectivec": "Objective-C", "java": "Java", "kotlin": "Kotlin", "csharp": "C#", "php": "PHP",
        "perl": "Perl", "lua": "Lua", "r": "R", "sql": "SQL", "bash": "Shell", "powershell": "PowerShell", "css": "CSS",
        "scss": "SCSS", "less": "Less", "graphql": "GraphQL", "diff": "Diff", "dockerfile": "Dockerfile",
        "makefile": "Makefile", "cmake": "CMake", "protobuf": "Protocol Buffers", "scala": "Scala", "dart": "Dart",
        "elixir": "Elixir", "haskell": "Haskell", "groovy": "Groovy", "nginx": "nginx", "properties": "Properties",
    ]
}

// MARK: - Archives and torrents

enum ArchiveInfo: InfoReader {
    static func canRead(_ type: UTType, url: URL) -> Bool {
        type.conforms(to: .archive) || type.conforms(to: .diskImage)
    }

    static func read(_ url: URL, format: InfoFormat) throws -> (sections: [InfoSection], summary: String?) {
        let listing = try ArchiveListing.read(url: url, maxEntries: 200_000, timeLimit: format.timeLimit)
        let files = listing.entries.filter { $0.kind != .directory }.count
        let folders = Set(listing.entries.flatMap { entry -> [String] in
            let parts = entry.path.split(separator: "/").map(String.init)
            let parents = (1..<max(parts.count, 1)).map { parts.prefix($0).joined(separator: "/") }
            return entry.kind == .directory ? parents + [entry.path] : parents
        }).count
        let unpacked = listing.totalSize
        let suffix = listing.isTruncated ? "+" : ""

        var items = [InfoItem("Format", listing.format)]
        if let compression = listing.compression { items.append(InfoItem("Compression", compression)) }
        items.append(InfoItem("Files", format.number(files) + suffix))
        items.append(InfoItem("Folders", format.number(folders) + suffix))
        items.append(InfoItem("Unpacked size", format.bytesWithCount(unpacked) + suffix))
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, unpacked > 0 {
            items.append(InfoItem("Compression ratio", format.percent(Double(size) / Double(unpacked))))
        }
        items.append(InfoItem("Encrypted", format.yesNo(listing.isEncrypted)))

        let summary = "\(listing.format) · \(format.number(files)) files · \(format.bytes(unpacked)) unpacked"
        return ([InfoSection("Archive", symbol: "archivebox", items: items)], summary)
    }
}

enum TorrentInfo: InfoReader {
    static func canRead(_ type: UTType, url: URL) -> Bool {
        url.pathExtension.lowercased() == "torrent"
    }

    static func read(_ url: URL, format: InfoFormat) throws -> (sections: [InfoSection], summary: String?) {
        let torrent = try Torrent(data: Data(contentsOf: url))
        var items = [
            InfoItem("Name", torrent.name),
            InfoItem("Files", format.number(torrent.files.count)),
            InfoItem("Total size", format.bytesWithCount(torrent.totalLength)),
            InfoItem("Info hash", torrent.infoHash),
        ]
        if let v2 = torrent.infoHashV2 { items.append(InfoItem("Info hash v2", v2)) }
        if torrent.pieceCount > 0 {
            let pieceSize = torrent.pieceLength.formatted(.byteCount(style: .memory).locale(format.locale))
            items.append(InfoItem("Pieces", "\(format.number(torrent.pieceCount)) × \(pieceSize)"))
        }
        items.append(InfoItem("Private", format.yesNo(torrent.isPrivate)))
        if let date = torrent.creationDate { items.append(InfoItem("Created", format.date(date))) }
        if let createdBy = torrent.createdBy { items.append(InfoItem("Created by", createdBy)) }
        if let comment = torrent.comment, !comment.isEmpty { items.append(InfoItem("Comment", comment)) }
        for (index, tracker) in torrent.trackers.enumerated() {
            items.append(InfoItem(index == 0 ? "Trackers" : "", tracker))
        }
        items.append(InfoItem("Magnet link", torrent.magnetLink))
        return ([InfoSection("Torrent", symbol: "arrow.down.circle", items: items)],
                "\(format.number(torrent.files.count)) files · \(format.bytes(torrent.totalLength))")
    }
}

// MARK: - PDF

enum PDFInfo: InfoReader {
    static func canRead(_ type: UTType, url: URL) -> Bool {
        type.conforms(to: .pdf)
    }

    static func read(_ url: URL, format: InfoFormat) throws -> (sections: [InfoSection], summary: String?) {
        guard let document = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
        var items = [InfoItem("Pages", format.number(document.pageCount))]
        var paper: String?
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            let size = paperName(width: box.width, height: box.height, format: format)
            paper = size.name
            items.append(InfoItem("Page size", size.description))
        }
        items.append(InfoItem("PDF version", "\(document.majorVersion).\(document.minorVersion)"))

        let attributes = document.documentAttributes ?? [:]
        let fields: [(PDFDocumentAttribute, String)] = [
            (.titleAttribute, "Title"), (.authorAttribute, "Author"), (.subjectAttribute, "Subject"),
            (.creatorAttribute, "Creator"), (.producerAttribute, "Producer"),
        ]
        for (key, label) in fields {
            if let value = attributes[key] as? String, !value.isEmpty { items.append(InfoItem(label, value)) }
        }
        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String], !keywords.isEmpty {
            items.append(InfoItem("Keywords", keywords.joined(separator: ", ")))
        }
        if let created = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date { items.append(InfoItem("Created", format.date(created))) }
        if let modified = attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date { items.append(InfoItem("Modified", format.date(modified))) }
        items.append(InfoItem("Encrypted", format.yesNo(document.isEncrypted)))
        if document.isEncrypted {
            items.append(InfoItem("Locked", format.yesNo(document.isLocked)))
        }
        items.append(InfoItem("Allows copying", format.yesNo(document.allowsCopying)))
        items.append(InfoItem("Allows printing", format.yesNo(document.allowsPrinting)))

        let pages = document.pageCount == 1 ? "1 page" : "\(format.number(document.pageCount)) pages"
        return ([InfoSection("PDF", symbol: "doc.richtext", items: items)], [pages, paper].compactMap { $0 }.joined(separator: " · "))
    }

    /// Names standard paper sizes (either orientation) within 2 mm.
    static func paperName(width: CGFloat, height: CGFloat, format: InfoFormat) -> (name: String?, description: String) {
        let mm = { (points: CGFloat) in Int((points / 72 * 25.4).rounded()) }
        let (w, h) = (mm(width), mm(height))
        let papers: [(String, Int, Int)] = [
            ("A3", 297, 420), ("A4", 210, 297), ("A5", 148, 210), ("Letter", 216, 279),
            ("Legal", 216, 356), ("Tabloid", 279, 432),
        ]
        let match = papers.first { (abs($0.1 - min(w, h)) <= 2) && (abs($0.2 - max(w, h)) <= 2) }
        let dimensions = "\(w) × \(h) mm"
        guard let match else { return (nil, dimensions) }
        let name = w > h ? "\(match.0) landscape" : match.0
        return (name, "\(name) (\(dimensions))")
    }
}

// MARK: - Fonts

enum FontInfo: InfoReader {
    static func canRead(_ type: UTType, url: URL) -> Bool {
        type.conforms(to: .font)
    }

    static func read(_ url: URL, format: InfoFormat) throws -> (sections: [InfoSection], summary: String?) {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let font = CTFontCreateWithFontDescriptor(first, 12, nil)
        func name(_ key: CFString) -> String? {
            CTFontCopyName(font, key) as String?
        }
        var items: [InfoItem] = []
        if let family = name(kCTFontFamilyNameKey) { items.append(InfoItem("Family", family)) }
        if let style = name(kCTFontStyleNameKey) { items.append(InfoItem("Style", style)) }
        if let full = name(kCTFontFullNameKey) { items.append(InfoItem("Full name", full)) }
        if let postScript = name(kCTFontPostScriptNameKey) { items.append(InfoItem("PostScript name", postScript)) }
        if let version = name(kCTFontVersionNameKey) { items.append(InfoItem("Version", version)) }
        items.append(InfoItem("Glyphs", String(CTFontGetGlyphCount(font))))
        if let raw = CTFontDescriptorCopyAttribute(first, kCTFontFormatAttribute) as? UInt32,
           let fontFormat = CTFontFormat(rawValue: raw) {
            let names: [CTFontFormat: String] = [
                .openTypePostScript: "OpenType (PostScript outlines)", .openTypeTrueType: "OpenType (TrueType outlines)",
                .trueType: "TrueType", .postScript: "PostScript", .bitmap: "Bitmap",
            ]
            items.append(InfoItem("Format", names[fontFormat] ?? "Unknown"))
        }
        if let axes = CTFontCopyVariationAxes(font) as? [Any], !axes.isEmpty {
            items.append(InfoItem("Variable axes", String(axes.count)))
        }
        if descriptors.count > 1 { items.append(InfoItem("Faces in collection", String(descriptors.count))) }
        if let designer = name(kCTFontDesignerNameKey) { items.append(InfoItem("Designer", designer)) }
        if let manufacturer = name(kCTFontManufacturerNameKey) { items.append(InfoItem("Manufacturer", manufacturer)) }

        let summary = [name(kCTFontFullNameKey), "\(CTFontGetGlyphCount(font)) glyphs"].compactMap { $0 }.joined(separator: " · ")
        return ([InfoSection("Font", symbol: "textformat", items: items)], summary)
    }
}
