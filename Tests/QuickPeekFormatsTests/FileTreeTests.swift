import Foundation
import Testing
@testable import QuickPeekFormats

@Suite("FileTree")
struct FileTreeTests {
    private func file(_ path: String, _ size: Int64) -> FileTreeItem {
        FileTreeItem(path: path, isDirectory: false, size: size)
    }

    @Test("Builds folders from paths, sums their sizes and lists folders first")
    func build() {
        let roots = FileTree.build([
            file("hello.txt", 6),
            file("docs/notes/todo.md", 12),
            FileTreeItem(path: "docs", isDirectory: true, size: nil),
            file("docs/zeros.bin", 4096),
        ])
        #expect(roots.map(\.name) == ["docs", "hello.txt"])
        let docs = roots[0]
        #expect(docs.isDirectory)
        #expect(docs.size == 4108)
        #expect(docs.fileCount == 2)
        #expect(docs.children?.map(\.name) == ["notes", "zeros.bin"])
        #expect(docs.children?[0].children?.map(\.name) == ["todo.md"])
        #expect(roots[1].children == nil)
    }

    @Test("Names sort like Finder: numbers by value, case-insensitive")
    func naturalOrder() {
        let roots = FileTree.build(["file10.txt", "File2.txt", "file1.txt"].map { file($0, 1) })
        #expect(roots.map(\.name) == ["file1.txt", "File2.txt", "file10.txt"])
    }

    @Test("Explicit and implicit folders merge; ./ and / prefixes are ignored")
    func merge() {
        let roots = FileTree.build([
            file("./a/b.txt", 1),
            FileTreeItem(path: "a/", isDirectory: true, size: nil),
            file("/a/c.txt", 2),
        ])
        #expect(roots.count == 1)
        #expect(roots[0].children?.map(\.name) == ["b.txt", "c.txt"])
        #expect(roots[0].size == 3)
    }

    @Test("Archive listings and torrents convert to trees")
    func sources() throws {
        let torrent = try Torrent(data: formatFixture("multi.torrent"))
        let tree = FileTree.build(torrent)
        #expect(tree.map(\.name) == ["video", "README.txt"])
        #expect(tree[0].size == 5_000_000_000)

        let listing = try ArchiveListing.read(url: archiveFixture("rar.rar"))
        let archiveTree = FileTree.build(listing)
        #expect(archiveTree.map(\.name) == ["testdir", "testemptydir", "test.txt", "testlink"])
    }
}
