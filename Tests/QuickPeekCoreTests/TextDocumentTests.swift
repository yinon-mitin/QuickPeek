import Foundation
import Testing
@testable import QuickPeekCore

@Suite("TextDocument")
struct TextDocumentTests {
    private func temporaryFile(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickPeekTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    @Test("Reads, decodes and classifies a file")
    func loads() throws {
        let url = try temporaryFile(named: "compose.yaml", contents: Data("services:\n  web: {}\n".utf8))
        let document = try TextDocument.load(url)
        #expect(document.kind == .code(language: "yaml"))
        #expect(document.text == "services:\n  web: {}\n")
        #expect(!document.isTruncated)
    }

    @Test("Large files are cut at the byte limit")
    func truncates() throws {
        let url = try temporaryFile(named: "big.log", contents: Data(String(repeating: "qpk\n", count: 1000).utf8))
        let document = try TextDocument.load(url, maxBytes: 100)
        #expect(document.isTruncated)
        #expect(document.text.utf8.count <= 100)
    }

    @Test("Text in memory is decoded and classified by the name it came with")
    func decodesData() throws {
        let document = try TextDocument.decode(Data("# Title\n".utf8), fileName: "README.md")
        #expect(document.kind == .markdown)
        #expect(!document.isTruncated)
        #expect(try TextDocument.decode(Data(repeating: 0x61, count: 101), fileName: "a.txt", maxBytes: 100).isTruncated)
        #expect(throws: TextDocumentError.binaryContent) { try TextDocument.decode(Data([0, 1, 2, 0, 0xFF]), fileName: "x") }
    }

    @Test("Shebang scripts without an extension are recognised")
    func shebang() throws {
        let url = try temporaryFile(named: "deploy", contents: Data("#!/usr/bin/env python3\nprint(1)\n".utf8))
        #expect(try TextDocument.load(url).kind == .code(language: "python"))
    }

    @Test("Binary files are reported, not dumped")
    func binary() throws {
        let url = try temporaryFile(named: "blob.bin", contents: Data([0x00, 0x01, 0x02, 0xFF]))
        #expect(throws: TextDocumentError.binaryContent) { try TextDocument.load(url) }
    }
}
