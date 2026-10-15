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

@Suite("FileTree initial expansion")
struct FileTreeExpansionTests {
    private func files(_ paths: [String]) -> [FileTreeNode] {
        FileTree.build(paths.map { FileTreeItem(path: $0, isDirectory: false, size: 1) })
    }

    @Test("A small tree opens every folder, empty folders stay closed")
    func everything() {
        var items = ["src/app/main.swift", "src/lib/util.swift", "docs/readme.md", "top.txt"]
            .map { FileTreeItem(path: $0, isDirectory: false, size: 1) }
        items.append(FileTreeItem(path: "empty", isDirectory: true, size: nil))
        let roots = FileTree.build(items)
        #expect(FileTree.initiallyExpanded(roots) == ["src", "src/app", "src/lib", "docs"])
    }

    @Test("Upper levels open first; a folder that would pass the row limit stays closed")
    func limit() {
        // 3 roots + 2 in "a" + 2 in "a/deep" = 7 rows; "big" alone would add 10.
        let roots = files(["a/deep/1", "a/deep/2", "a/x"] + (1...10).map { "big/\($0)" } + ["z.txt"])
        #expect(FileTree.initiallyExpanded(roots, rowLimit: 7) == ["a", "a/deep"])
        #expect(FileTree.initiallyExpanded(roots, rowLimit: 5) == ["a"])
        #expect(FileTree.initiallyExpanded(roots, rowLimit: 3).isEmpty)
        #expect(FileTree.initiallyExpanded(roots, rowLimit: 100).count == 3)
    }
}

@Suite("FileTree single root")
struct FileTreeSingleRootTests {
    @Test("A lone top-level folder is opened; its name is returned separately")
    func unwrap() {
        let roots = FileTree.build([
            FileTreeItem(path: "Project/README.md", isDirectory: false, size: 1),
            FileTreeItem(path: "Project/Sources/main.swift", isDirectory: false, size: 2),
        ])
        let (folder, nodes) = FileTree.openingSingleFolder(roots)
        #expect(folder == "Project")
        #expect(nodes.map(\.name) == ["Sources", "README.md"])
    }

    @Test("Several roots, or a single file, stay as they are")
    func keep() {
        let two = FileTree.build([FileTreeItem(path: "a.txt", isDirectory: false, size: 1),
                                  FileTreeItem(path: "b/c.txt", isDirectory: false, size: 1)])
        #expect(FileTree.openingSingleFolder(two).folder == nil)
        let file = FileTree.build([FileTreeItem(path: "a.txt", isDirectory: false, size: 1)])
        #expect(FileTree.openingSingleFolder(file).nodes.map(\.name) == ["a.txt"])
    }
}
