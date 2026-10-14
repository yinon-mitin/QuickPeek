import Foundation
import Testing
@testable import QuickPeekMedia

@Suite("Matroska blocks and lacing")
struct BlockTests {
    /// Track 1, relative timestamp 5, then flags, then payload.
    private func block(flags: UInt8, _ payload: [UInt8]) -> Data {
        Data([0x81, 0x00, 0x05, flags] + payload)
    }

    @Test("Unlaced keyframe")
    func unlaced() throws {
        let parsed = try MatroskaBlock.parse(block(flags: 0x80, [1, 2, 3]))
        #expect(parsed.trackNumber == 1)
        #expect(parsed.relativeTimestamp == 5)
        #expect(parsed.isKeyframe)
        #expect(parsed.frames == [Data([1, 2, 3])])
    }

    @Test("Negative relative timestamps")
    func negativeTimestamp() throws {
        let parsed = try MatroskaBlock.parse(Data([0x82, 0xFF, 0xF6, 0x00, 9]))
        #expect(parsed.trackNumber == 2)
        #expect(parsed.relativeTimestamp == -10)
        #expect(!parsed.isKeyframe)
    }

    @Test("Xiph lacing")
    func xiph() throws {
        // 3 frames: sizes 2 and 256 (255+1) are coded, the last takes the rest (1 byte).
        let payload: [UInt8] = [0x02, 0x02, 0xFF, 0x01] + [7, 7] + Array(repeating: 8, count: 256) + [9]
        let parsed = try MatroskaBlock.parse(block(flags: 0x80 | 0x02, payload))
        #expect(parsed.frames.map(\.count) == [2, 256, 1])
        #expect(parsed.frames[2] == Data([9]))
    }

    @Test("Fixed-size lacing")
    func fixed() throws {
        let parsed = try MatroskaBlock.parse(block(flags: 0x04, [0x02, 1, 1, 2, 2, 3, 3]))
        #expect(parsed.frames == [Data([1, 1]), Data([2, 2]), Data([3, 3])])
    }

    @Test("EBML lacing with signed size differences")
    func ebml() throws {
        // 3 frames: first size 4 (vint 0x84), second 4-1 = 3 (signed vint: 0x5F 0xFE = -1), last = rest.
        let payload: [UInt8] = [0x02, 0x84, 0x5F, 0xFE] + [1, 1, 1, 1] + [2, 2, 2] + [3, 3]
        let parsed = try MatroskaBlock.parse(block(flags: 0x06, payload))
        #expect(parsed.frames.map(\.count) == [4, 3, 2])
    }

    @Test("Lace sizes larger than the block are rejected")
    func corruptLacing() {
        #expect(throws: MatroskaError.self) {
            try MatroskaBlock.parse(block(flags: 0x02, [0x01, 0xFF, 0x10, 1, 2]))
        }
    }
}
