import Foundation
import Testing
@testable import QuickPeekFormats

@Suite("FolderListing")
struct FolderListingTests {
    /// A folder in the temporary directory, which is itself behind a symlink (/var → /private/var).
    private func makeFolder(_ files: [String: Int]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderListing-\(UUID().uuidString)")
        for (path, size) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
        return root
    }

    @Test("Lists files and folders by relative path, skipping hidden files")
    func listing() throws {
        let root = try makeFolder(["a.txt": 3, "src/main.swift": 10, "src/.hidden": 1, ".DS_Store": 6])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let listing = try FolderListing.read(url: root)
        #expect(!listing.isTruncated)
        #expect(listing.fileCount == 2)
        #expect(listing.totalSize == 13)
        let tree = FileTree.build(listing.items)
        #expect(tree.map(\.name) == ["empty", "src", "a.txt"])
        #expect(tree[1].children?.map(\.name) == ["main.swift"])
        #expect(tree[0].children == [])
    }

    @Test("Packages are single items; symlinks keep their target")
    func packagesAndLinks() throws {
        let root = try makeFolder(["Tool.app/Contents/Info.plist": 100, "data.bin": 5])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "data.bin")

        let tree = FileTree.build(try FolderListing.read(url: root).items)
        #expect(tree.map(\.name) == ["data.bin", "link", "Tool.app"])
        #expect(tree.allSatisfy { !$0.isDirectory })
        #expect(tree[1].linkTarget == "data.bin")
    }

    @Test("The walk stops at the limit and says so")
    func limit() throws {
        let root = try makeFolder(Dictionary(uniqueKeysWithValues: (1...20).map { ("f\($0)", 1) }))
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = try FolderListing.read(url: root, limit: 5)
        #expect(listing.isTruncated)
        #expect(listing.items.count == 5)
    }
}
