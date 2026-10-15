import Foundation
import QuickPeekCore
import Testing
@testable import QuickPeekFormats

@Suite("ArchivePeek")
struct ArchivePeekTests {
    private func peek(_ path: String, in file: String) throws -> ArchivePeek {
        let url = try archiveFixture(file)
        let entry = try #require(try ArchiveListing.read(url: url).entries.first { $0.path == path })
        return ArchivePeek.read(entry, in: url)
    }

    private func text(_ peek: ArchivePeek) -> TextDocument? {
        if case .text(let document) = peek { return document }
        return nil
    }

    @Test("Text files are read from ZIP, compressed TAR and a lone .gz, and classified by name",
          arguments: ["tree.zip", "tree.tar.gz", "tree.tar.xz"])
    func textFiles(file: String) throws {
        #expect(text(try peek("hello.txt", in: file))?.text == "hello\n")
        let todo = try #require(text(try peek("docs/notes/todo.md", in: file)))
        #expect(todo.text == "nested file\n")
        #expect(todo.kind == .markdown)
        #expect(text(try peek("docs/привет.txt", in: file))?.text == "привет\n")
    }

    @Test("A lone .gz previews the file it compresses")
    func singleStream() throws {
        #expect(text(try peek("hello.txt", in: "hello.txt.gz"))?.text == "hello\n")
    }

    @Test("Binary and encrypted entries are reported, not shown")
    func unavailable() throws {
        guard case .unavailable(.binary) = try peek("docs/zeros.bin", in: "tree.zip") else {
            Issue.record("zeros.bin should be binary")
            return
        }
        guard case .unavailable(.encrypted) = try peek("hello.txt", in: "encrypted.zip") else {
            Issue.record("an encrypted entry should not be read")
            return
        }
    }

    @Test("What to read is decided from the name and size first")
    func plan() {
        let huge = ArchivePeek.wholeFileLimit + 1
        #expect(ArchivePeek.plan(name: "photo.JPG", size: 10, isEncrypted: false) == .image)
        #expect(ArchivePeek.plan(name: "scan.png", size: huge, isEncrypted: false) == .skip(.tooLarge(huge)))
        #expect(ArchivePeek.plan(name: "manual.pdf", size: nil, isEncrypted: false) == .pdf)
        #expect(ArchivePeek.plan(name: "clip.mp4", size: 10, isEncrypted: false) == .skip(.media))
        #expect(ArchivePeek.plan(name: "nested.zip", size: 10, isEncrypted: false) == .skip(.binary))
        #expect(ArchivePeek.plan(name: "Inter.ttf", size: 10, isEncrypted: false) == .skip(.binary))
        #expect(ArchivePeek.plan(name: "Makefile", size: 10, isEncrypted: false) == .text)
        #expect(ArchivePeek.plan(name: "main.swift", size: huge, isEncrypted: false) == .text)
        #expect(ArchivePeek.plan(name: "notes.txt", size: 10, isEncrypted: true) == .skip(.encrypted))
    }

    @Test("Tree ids match archive paths, whatever prefixes the archive used")
    func treeIDs() {
        #expect(FileTree.id(forPath: "./docs//notes/todo.md") == "docs/notes/todo.md")
        #expect(FileTree.id(forPath: "/abs/file") == "abs/file")
    }
}
