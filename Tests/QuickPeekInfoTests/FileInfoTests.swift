import AppKit
import Foundation
import PDFKit
import Testing
@testable import QuickPeekInfo

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func temporaryFile(_ name: String, _ data: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickPeekInfo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

extension FileInfo {
    func value(_ label: String, in section: String? = nil) -> String? {
        sections.filter { section == nil || $0.title == section }
            .flatMap(\.items).first { $0.label == label }?.value
    }
}

@Suite("FileInfo: general and text")
struct GeneralInfoTests {
    @Test("Every file gets a General section with kind, size and dates")
    func general() throws {
        let url = try temporaryFile("notes.txt", Data(repeating: 0x61, count: 1_500))
        let info = FileInfoReader.read(url, locale: Locale(identifier: "en_US"))
        #expect(info.sections.first?.title == "General")
        // The wording comes from LaunchServices and differs between an app and a test process.
        #expect(info.value("Kind")?.isEmpty == false)
        #expect(info.value("Size") == "2 kB (1,500 bytes)") // whole kilobytes, as Finder shows them
        #expect(info.value("Modified") != nil)
    }

    @Test("Text files report encoding, line endings and line count", arguments: [
        ("utf8.txt", Data("one\ntwo\nthree\n".utf8), "UTF-8", "LF (Unix)", "3"),
        ("bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\r\n".utf8), "UTF-8 with BOM", "CRLF (Windows)", "2"),
        ("legacy.txt", Data([0x63, 0x61, 0x66, 0xE9, 0x0D]), "Windows-1252", "CR (classic Mac)", "1"),
    ])
    func text(name: String, data: Data, encoding: String, endings: String, lines: String) throws {
        let info = FileInfoReader.read(try temporaryFile(name, data), locale: Locale(identifier: "en_US"))
        #expect(info.value("Encoding", in: "Text") == encoding)
        #expect(info.value("Line endings", in: "Text") == endings)
        #expect(info.value("Lines", in: "Text") == lines)
    }

    @Test("Source files name their language")
    func language() throws {
        let info = FileInfoReader.read(try temporaryFile("main.swift", Data("print(1)\n".utf8)), locale: Locale(identifier: "en_US"))
        #expect(info.value("Language", in: "Text") == "Swift")
    }
}

@Suite("FileInfo: archives and torrents")
struct ArchiveInfoTests {
    let fixtures = repositoryRoot.appendingPathComponent("Tests/QuickPeekFormatsTests/Fixtures")

    @Test("Archives report format, counts, unpacked size and ratio")
    func archive() {
        let info = FileInfoReader.read(fixtures.appendingPathComponent("archives/tree.tar.gz"), locale: Locale(identifier: "en_US"))
        #expect(info.value("Format", in: "Archive") == "TAR")
        #expect(info.value("Compression", in: "Archive") == "gzip")
        #expect(info.value("Files", in: "Archive") == "4")
        #expect(info.value("Folders", in: "Archive") == "2")
        #expect(info.value("Unpacked size", in: "Archive") == "4 kB (4,127 bytes)")
        #expect(info.value("Compression ratio", in: "Archive")?.hasSuffix("%") == true)
    }

    @Test("Torrents report hash, size and trackers")
    func torrent() {
        let info = FileInfoReader.read(fixtures.appendingPathComponent("multi.torrent"), locale: Locale(identifier: "en_US"))
        #expect(info.value("Info hash", in: "Torrent") == "a90a28759758a2ffa97e907224139dc58fd214d3")
        #expect(info.value("Files", in: "Torrent") == "3")
        #expect(info.value("Pieces", in: "Torrent") == "3 × 256 kB")
    }
}

@Suite("FileInfo: PDF and fonts")
struct DocumentInfoTests {
    private func makePDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qp-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 in points
        let metadata: [CFString: Any] = [
            kCGPDFContextTitle: "Quarterly Report", kCGPDFContextAuthor: "QuickPeek Tests", kCGPDFContextCreator: "Unit test",
        ]
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, metadata as CFDictionary))
        for _ in 0..<2 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return url
    }

    @Test("PDF pages, page size and document properties")
    func pdf() throws {
        let info = FileInfoReader.read(try makePDF(), locale: Locale(identifier: "en_US"))
        #expect(info.value("Pages", in: "PDF") == "2")
        #expect(info.value("Page size", in: "PDF") == "A4 (210 × 297 mm)")
        #expect(info.value("Title", in: "PDF") == "Quarterly Report")
        #expect(info.value("Author", in: "PDF") == "QuickPeek Tests")
        #expect(info.value("Encrypted", in: "PDF") == "No")
    }

    @Test("Fonts report family, style and glyph count")
    func font() throws {
        let url = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        try #require(FileManager.default.fileExists(atPath: url.path), "Arial.ttf not installed")
        let info = FileInfoReader.read(url, locale: Locale(identifier: "en_US"))
        #expect(info.value("Family", in: "Font") == "Arial")
        #expect(info.value("Style", in: "Font") == "Regular")
        #expect(Int(info.value("Glyphs", in: "Font") ?? "") ?? 0 > 1000)
    }

    @Test("The one-line summary leads with what matters for the type")
    func summary() throws {
        let info = FileInfoReader.read(try makePDF(), locale: Locale(identifier: "en_US"))
        #expect(info.summary == "2 pages · A4")
    }
}
