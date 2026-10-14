import Foundation
import Testing
@testable import QuickPeekCore

@Suite("TextDecoder")
struct TextDecoderTests {
    @Test("UTF-8 with and without BOM")
    func utf8() {
        #expect(TextDecoder.decode(Data("héllo".utf8)) == "héllo")
        #expect(TextDecoder.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8)) == "hi")
    }

    @Test("UTF-16 with BOM")
    func utf16() throws {
        let data = try #require("привет".data(using: .utf16))
        #expect(TextDecoder.decode(data) == "привет")
    }

    @Test("Legacy single-byte text falls back to Windows-1252")
    func legacy() {
        #expect(TextDecoder.decode(Data([0x63, 0x61, 0x66, 0xE9])) == "café")
    }

    @Test("Binary data is rejected")
    func binary() {
        #expect(TextDecoder.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x01])) == nil)
    }
}

@Suite("TextDecoder truncation")
struct TextDecoderTruncationTests {
    @Test("A UTF-8 character cut by the byte limit is dropped, not decoded as Windows-1252")
    func cutCharacter() {
        let data = Data("привет".utf8).dropLast()
        #expect(TextDecoder.decode(data, truncated: true) == "приве")
    }
}
