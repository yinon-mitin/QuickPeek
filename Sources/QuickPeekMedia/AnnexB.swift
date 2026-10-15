import Foundation

/// H.264 and HEVC as MPEG-TS and AVI store them: NAL units separated by start codes (Annex B).
/// VideoToolbox wants each NAL unit prefixed with its length instead, and the parameter sets
/// (SPS, PPS, VPS) out of band in the format description.
enum AnnexB {
    enum Codec { case h264, hevc }

    /// NAL units without their start codes.
    static func units(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start {
                    var end = index
                    while end > start, bytes[end - 1] == 0 { end -= 1 } // trailing zeros of a 4-byte start code
                    if end > start { units.append(Data(bytes[start..<end])) }
                }
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < bytes.count {
            units.append(Data(bytes[start...]))
        }
        return units
    }

    static func looksLikeAnnexB(_ data: Data) -> Bool {
        let bytes = data.prefix(4)
        return bytes.starts(with: [0, 0, 1]) || bytes.starts(with: [0, 0, 0, 1])
    }

    static func type(of unit: Data, codec: Codec) -> Int {
        guard let first = unit.first else { return -1 }
        return codec == .h264 ? Int(first & 0x1F) : Int(first >> 1 & 0x3F)
    }

    static func isParameterSet(_ type: Int, codec: Codec) -> Bool {
        codec == .h264 ? (type == 7 || type == 8) : (32...34).contains(type)
    }

    /// Access unit delimiters and filler data carry nothing a decoder needs.
    static func isDiscardable(_ type: Int, codec: Codec) -> Bool {
        codec == .h264 ? (type == 9 || type == 12) : (type == 35 || type == 38)
    }

    /// IDR pictures, and for H.264 also I slices (camcorders and broadcasts often use open GOPs).
    static func isKeyframe(_ units: [Data], codec: Codec) -> Bool {
        for unit in units {
            let type = type(of: unit, codec: codec)
            switch codec {
            case .h264:
                if type == 5 { return true }
                if type == 1 { return h264SliceIsIntra(unit) }
            case .hevc:
                if (16...21).contains(type) { return true }
                if type < 16 { return false }
            }
        }
        return false
    }

    /// slice_type of the first slice: 2 or 7 (I), 4 or 9 (SI).
    private static func h264SliceIsIntra(_ unit: Data) -> Bool {
        var reader = BitReader(unescaping: unit.dropFirst())
        guard reader.readExpGolomb() != nil, let sliceType = reader.readExpGolomb() else { return false }
        return sliceType % 5 == 2 || sliceType % 5 == 4
    }

    /// Converts an Annex B access unit to 4-byte length-prefixed NAL units, leaving out the
    /// parameter sets (collected into `parameterSets`) and delimiters.
    static func lengthPrefixed(_ units: [Data], codec: Codec, parameterSets: inout [Int: Data]) -> Data {
        var output = Data()
        for unit in units where !unit.isEmpty {
            let type = type(of: unit, codec: codec)
            if isParameterSet(type, codec: codec) {
                if parameterSets[type] == nil { parameterSets[type] = unit }
                continue
            }
            if isDiscardable(type, codec: codec) { continue }
            var length = UInt32(unit.count).bigEndian
            output.append(Data(bytes: &length, count: 4))
            output.append(unit)
        }
        return output
    }

    /// Parameter sets in the order the format description wants them: SPS, PPS (H.264) or VPS, SPS, PPS.
    static func orderedParameterSets(_ sets: [Int: Data], codec: Codec) -> [Data]? {
        let order = codec == .h264 ? [7, 8] : [32, 33, 34]
        let ordered = order.compactMap { sets[$0] }
        return ordered.count == order.count ? ordered : nil
    }
}

/// Reads bits from a NAL unit with emulation prevention bytes (00 00 03) removed.
struct BitReader {
    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    init(unescaping data: Data) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count)
        var zeros = 0
        for byte in data {
            if zeros >= 2 && byte == 3 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            bytes.append(byte)
        }
        self.bytes = bytes
    }

    var bitsLeft: Int { bytes.count * 8 - position }

    mutating func readBit() -> Int? {
        guard position < bytes.count * 8 else { return nil }
        let bit = Int(bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1)
        position += 1
        return bit
    }

    mutating func read(_ count: Int) -> Int? {
        var value = 0
        for _ in 0..<count {
            guard let bit = readBit() else { return nil }
            value = value << 1 | bit
        }
        return value
    }

    mutating func skip(_ count: Int) {
        position += count
    }

    /// Unsigned Exp-Golomb code, ue(v).
    mutating func readExpGolomb() -> Int? {
        var zeros = 0
        while let bit = readBit(), bit == 0 {
            zeros += 1
            if zeros > 31 { return nil }
        }
        guard position <= bytes.count * 8 else { return nil }
        guard let rest = read(zeros) else { return nil }
        return (1 << zeros) - 1 + rest
    }

    /// Signed Exp-Golomb code, se(v).
    mutating func readSignedExpGolomb() -> Int? {
        guard let code = readExpGolomb() else { return nil }
        return code % 2 == 1 ? (code + 1) / 2 : -(code / 2)
    }
}
