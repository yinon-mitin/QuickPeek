import Foundation
import Testing
@testable import QuickPeekFormats

func formatFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("Bencode")
struct BencodeTests {
    @Test("Scalars, lists and dictionaries")
    func values() throws {
        #expect(try Bencode.decode(Data("i42e".utf8)) == .integer(42))
        #expect(try Bencode.decode(Data("i-7e".utf8)) == .integer(-7))
        #expect(try Bencode.decode(Data("4:spam".utf8)) == .string(Data("spam".utf8)))
        #expect(try Bencode.decode(Data("l1:ai1ee".utf8)) == .list([.string(Data("a".utf8)), .integer(1)]))
        let dict = try Bencode.decode(Data("d3:bar4:spam3:fooi42ee".utf8))
        #expect(dict["foo"]?.integer == 42)
        #expect(dict["bar"]?.text == "spam")
    }

    @Test("Malformed input is rejected", arguments: [
        "i01e", "i-0e", "ie", "3:ab", "d1:ai1e", "l", "x", "-1:a", "i9999999999999999999999e",
    ])
    func malformed(input: String) {
        #expect(throws: BencodeError.self) { try Bencode.decode(Data(input.utf8)) }
    }

    @Test("Deep nesting is refused instead of overflowing the stack")
    func depth() {
        let data = Data((String(repeating: "l", count: 10_000) + String(repeating: "e", count: 10_000)).utf8)
        #expect(throws: BencodeError.self) { try Bencode.decode(data) }
    }

    @Test("Raw bytes of a top-level value, for hashing")
    func rawValue() throws {
        let data = Data("d4:infod4:name1:xe5:otheri1ee".utf8)
        #expect(try Bencode.rawValue(forKey: "info", in: data) == Data("d4:name1:xe".utf8))
    }
}

@Suite("Torrent")
struct TorrentTests {
    @Test("Multi-file torrent")
    func multiFile() throws {
        let torrent = try Torrent(data: formatFixture("multi.torrent"))
        #expect(torrent.name == "Example Dataset")
        #expect(torrent.files.map(\.path) == [["video", "lecture-01.mkv"], ["README.txt"], ["video", "subs", "empty.srt"]])
        #expect(torrent.totalLength == 5_000_001_234)
        #expect(torrent.pieceLength == 262_144)
        #expect(torrent.pieceCount == 3)
        #expect(torrent.trackers == ["https://tracker.example.org/announce", "udp://backup.example.net:6969/announce"])
        #expect(torrent.webSeeds == ["https://mirror.example.com/files/"])
        #expect(torrent.comment == "QuickPeek test torrent")
        #expect(torrent.createdBy == "QuickPeek fixtures")
        #expect(torrent.creationDate == Date(timeIntervalSince1970: 1_776_000_000))
        #expect(!torrent.isPrivate)
        #expect(torrent.infoHash == "a90a28759758a2ffa97e907224139dc58fd214d3")
        #expect(torrent.magnetLink.hasPrefix("magnet:?xt=urn:btih:a90a28759758a2ffa97e907224139dc58fd214d3&dn=Example%20Dataset"))
        #expect(torrent.magnetLink.contains("&tr=udp%3A%2F%2Fbackup.example.net%3A6969%2Fannounce"))
    }

    @Test("Single-file torrent")
    func singleFile() throws {
        let torrent = try Torrent(data: formatFixture("single.torrent"))
        #expect(torrent.files.count == 1)
        #expect(torrent.files[0].path == ["ubuntu-26.04-desktop-amd64.iso"])
        #expect(torrent.totalLength == 6_123_456_789)
        #expect(torrent.pieceCount == 2)
        #expect(torrent.infoHash == "6e1c591e58eabb99e0450d25f7a7753320b9e174")
    }

    @Test("Private torrent: UTF-8 names, and the magnet link leaves out the passkey tracker")
    func privateTorrent() throws {
        let torrent = try Torrent(data: formatFixture("private-utf8.torrent"))
        #expect(torrent.name == "Документы — 2026")
        #expect(torrent.files[0].path == ["отчёт.pdf"])
        #expect(torrent.isPrivate)
        #expect(torrent.infoHash == "05a543193fb6591f70b2ee429a7f45897b056ace")
        #expect(!torrent.magnetLink.contains("tr="))
        #expect(!torrent.magnetLink.contains("passkey"))
    }

    @Test("BitTorrent v2 file trees")
    func version2() throws {
        let data = Data("d4:infod9:file treed3:docd5:a.txtd0:d6:lengthi5eeee5:b.bind0:d6:lengthi7eeee12:meta versioni2e4:name2:v212:piece lengthi16384eee".utf8)
        let torrent = try Torrent(data: data)
        #expect(torrent.files.map(\.path) == [["b.bin"], ["doc", "a.txt"]])
        #expect(torrent.totalLength == 12)
        #expect(torrent.infoHashV2?.count == 64)
    }

    @Test("File lengths whose sum overflows Int64 add up to the maximum instead of crashing")
    func hugeLengths() throws {
        let file = "d6:lengthi4611686018427387905e4:pathl1:aee"
        let torrent = try Torrent(data: Data("d4:infod5:filesl\(file)\(file)e4:name1:t12:piece lengthi16384eee".utf8))
        #expect(torrent.totalLength == .max)
        #expect(torrent.pieceCount == Int(Int64.max / 16384) + 1)
    }

    @Test("Files that are not torrents are rejected")
    func notTorrent() {
        #expect(throws: (any Error).self) { try Torrent(data: Data("d3:fooi1ee".utf8)) }
        #expect(throws: (any Error).self) { try Torrent(data: Data("hello".utf8)) }
    }
}
