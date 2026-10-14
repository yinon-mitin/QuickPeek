import Foundation
import Testing
@testable import QuickPeekMedia

@Suite("EBML primitives")
struct EBMLTests {
    private func reader(_ bytes: [UInt8]) -> EBMLReader {
        EBMLReader(source: DataByteSource(Data(bytes)))
    }

    static let sizeCases: [([UInt8], UInt64)] = [
        ([0x81], 1),
        ([0x40, 0x02], 2),
        ([0x20, 0x00, 0x03], 3),
        ([0x10, 0x00, 0x00, 0x04], 4),
        ([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00], 256),
    ]

    @Test("Element sizes of every width, with the marker bit stripped", arguments: sizeCases)
    func sizes(bytes: [UInt8], value: UInt64) throws {
        var r = reader(bytes)
        #expect(try r.readSize() == .known(value))
        #expect(r.offset == Int64(bytes.count))
    }

    @Test("All-ones sizes mean unknown size")
    func unknownSize() throws {
        var r = reader([0xFF])
        #expect(try r.readSize() == .unknown)
        var r8 = reader([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(try r8.readSize() == .unknown)
    }

    @Test("Element IDs keep their marker bits")
    func ids() throws {
        var r = reader([0x1A, 0x45, 0xDF, 0xA3, 0xA3])
        #expect(try r.readID() == 0x1A45_DFA3)
        #expect(try r.readID() == 0xA3)
    }

    @Test("Invalid leading byte is rejected")
    func invalid() {
        var r = reader([0x00, 0x01])
        #expect(throws: MatroskaError.self) { try r.readSize() }
    }

    @Test("Unsigned, signed, float and string payloads")
    func payloads() throws {
        #expect(EBMLReader.unsigned(Data([0x01, 0x00])) == 256)
        #expect(EBMLReader.signed(Data([0xFF, 0xFE])) == -2)
        #expect(EBMLReader.float(Data([0x3F, 0x80, 0x00, 0x00])) == 1.0)
        #expect(EBMLReader.float(Data([0x40, 0x8F, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00])) == 1000.0)
        #expect(EBMLReader.string(Data("webm\0\0".utf8)) == "webm")
    }

    @Test("Reading past the end is an error, not a crash")
    func truncated() {
        var r = reader([0x10, 0x00])
        #expect(throws: MatroskaError.self) { try r.readSize() }
    }
}
