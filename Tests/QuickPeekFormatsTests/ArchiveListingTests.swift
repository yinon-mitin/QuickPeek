import Foundation
import Testing
@testable import QuickPeekFormats

func archiveFixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/archives"))
}

@Suite("ArchiveListing")
struct ArchiveListingTests {
    static let tree = ["hello.txt", "docs/", "docs/zeros.bin", "docs/привет.txt", "docs/notes/", "docs/notes/todo.md"]

    @Test("ZIP and TAR with every system compression list the same tree",
          arguments: ["tree.zip", "tree.tar", "tree.tar.gz", "tree.tar.bz2", "tree.tar.xz"])
    func tree(file: String) throws {
        let listing = try ArchiveListing.read(url: archiveFixture(file))
        let paths = listing.entries.map { $0.kind == .directory ? $0.path + "/" : $0.path }
        // Compare as sets: NFC/NFD normalisation of "привет" may differ between archivers.
        #expect(Set(paths.map { $0.precomposedStringWithCanonicalMapping }) == Set(Self.tree.map { $0.precomposedStringWithCanonicalMapping }))
        #expect(listing.entries.first { $0.path == "docs/zeros.bin" }?.size == 4096)
        #expect(listing.entries.filter { $0.kind == .directory }.count == 2)
        #expect(listing.totalSize == 6 + 4096 + 13 + 12)
        #expect(!listing.isTruncated)
        #expect(listing.problem == nil)

        let date = try #require(listing.entries.first { $0.path == "hello.txt" }?.modified)
        let components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        #expect(components.year == 2026 && components.month == 1 && components.day == 2)
    }

    @Test("Container and compression are named", arguments: [
        ("tree.zip", "ZIP", nil as String?),
        ("tree.tar.gz", "TAR", "gzip"),
        ("tree.tar.bz2", "TAR", "bzip2"),
        ("tree.tar.xz", "TAR", "xz"),
        ("rar.rar", "RAR", nil),
        ("rar5_multiple_files.rar", "RAR5", nil),
        ("7zip_lzma1.7z", "7-Zip", nil),
    ])
    func formatNames(file: String, format: String, compression: String?) throws {
        let listing = try ArchiveListing.read(url: archiveFixture(file))
        #expect(listing.format.contains(format))
        #expect(listing.compression == compression)
    }

    @Test("RAR4 with symlinks and directories")
    func rar4() throws {
        let listing = try ArchiveListing.read(url: archiveFixture("rar.rar"))
        #expect(listing.entries.map(\.path) == ["test.txt", "testlink", "testdir/test.txt", "testdir", "testemptydir"])
        #expect(listing.entries[1].kind == .symlink)
        #expect(listing.entries[1].linkTarget == "test.txt")
        #expect(listing.entries[3].kind == .directory)
    }

    @Test("RAR5 with Unicode names")
    func rar5() throws {
        let listing = try ArchiveListing.read(url: archiveFixture("rar5_unicode.rar"))
        #expect(listing.entries.first?.path == "👋🌎.txt")
        #expect(listing.entries.first?.size == 13)
        let multiple = try ArchiveListing.read(url: archiveFixture("rar5_multiple_files.rar"))
        #expect(multiple.entries.map(\.path) == ["test1.bin", "test2.bin", "test3.bin", "test4.bin"])
    }

    @Test("7-Zip")
    func sevenZip() throws {
        let listing = try ArchiveListing.read(url: archiveFixture("7zip_lzma1.7z"))
        #expect(listing.entries.map(\.path) == ["file1"])
        #expect(listing.entries[0].size == 2844)
    }

    @Test("Encrypted entries are flagged; encrypted file names are reported, not an error page",
          arguments: ["encrypted.zip", "rar4_encrypted_filenames.rar", "rar5_encrypted_filenames.rar"])
    func encrypted(file: String) throws {
        let listing = try ArchiveListing.read(url: archiveFixture(file))
        #expect(listing.isEncrypted)
        if file == "encrypted.zip" {
            #expect(listing.entries.map(\.path) == ["hello.txt"])
            #expect(listing.entries[0].isEncrypted)
        }
    }

    @Test("A lone .gz shows the file inside")
    func singleGzip() throws {
        let listing = try ArchiveListing.read(url: archiveFixture("hello.txt.gz"))
        #expect(listing.entries.map(\.path) == ["hello.txt"])
        #expect(listing.entries[0].size == 6)
        #expect(listing.compression == "gzip")
    }

    @Test("Listing stops at the entry limit and says so")
    func limit() throws {
        let listing = try ArchiveListing.read(url: archiveFixture("tree.zip"), maxEntries: 2)
        #expect(listing.entries.count == 2)
        #expect(listing.isTruncated)
    }

    @Test("A file that is not an archive is an error")
    func notArchive() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qp-\(UUID().uuidString).zip")
        try Data(repeating: 0x41, count: 300).write(to: url)
        #expect(throws: ArchiveError.self) { try ArchiveListing.read(url: url) }
    }

    // bomb.tar.bz2 is 14 KB: 16 GiB of zeros in zeros.bin, then README.txt. Decompressing all of it
    // takes several seconds, so finishing well under two shows the limit held.

    @Test("A decompression bomb is listed up to the time limit, not inflated")
    func bombListing() throws {
        let start = Date()
        let listing = try ArchiveListing.read(url: archiveFixture("bomb.tar.bz2"), timeLimit: 0.3)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(listing.entries.map(\.path) == ["zeros.bin"])
        #expect(listing.entries.first?.size == 16 << 30)
        #expect(listing.isTruncated)
    }

    @Test("Reading a file behind a bomb gives up at the time limit")
    func bombEntry() throws {
        let start = Date()
        #expect(try ArchiveListing.data(ofEntry: "README.txt", in: archiveFixture("bomb.tar.bz2"), timeLimit: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test("Cancelling the calling task stops decompression")
    func bombCancelled() async throws {
        let url = try archiveFixture("bomb.tar.bz2")
        let task = Task.detached { try ArchiveListing.data(ofEntry: "README.txt", in: url, timeLimit: 60) }
        try await Task.sleep(for: .milliseconds(200))
        // Timed from the cancel: on a busy runner the sleep can resume seconds late.
        let cancelled = Date()
        task.cancel()
        #expect(try await task.value == nil)
        #expect(Date().timeIntervalSince(cancelled) < 1)
    }

    @Test("Entry sizes whose sum overflows Int64 add up to the maximum instead of crashing")
    func hugeSizes() throws {
        let listing = try ArchiveListing.read(url: archiveFixture("huge-sizes.zip"))
        #expect(listing.entries.map(\.size) == [(1 << 62) + 1, (1 << 62) + 1])
        #expect(listing.totalSize == .max)
        #expect(FileTree.build(listing).first?.size == .max)
    }
}
