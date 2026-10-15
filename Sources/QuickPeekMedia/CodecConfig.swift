import Foundation

/// MPEG-4 ES_Descriptor (ISO/IEC 14496-1) — the body of an MP4 `esds` box: how Apple's decoders
/// take the configuration of AAC and of MPEG-4 Part 2 video.
enum ElementaryStream {
    /// objectType: 0x40 AAC, 0x20 MPEG-4 visual; streamType: 0x05 audio, 0x04 visual.
    static func descriptor(objectType: UInt8, streamType: UInt8, config: Data) -> Data {
        func descriptor(_ tag: UInt8, _ payload: Data) -> Data {
            var data = Data([tag])
            let length = payload.count
            data += [0x80 | UInt8((length >> 21) & 0x7F), 0x80 | UInt8((length >> 14) & 0x7F),
                     0x80 | UInt8((length >> 7) & 0x7F), UInt8(length & 0x7F)]
            return data + payload
        }
        let decoderSpecificInfo = descriptor(0x05, config)
        let decoderConfig = descriptor(0x04, Data([objectType, streamType << 2 | 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + decoderSpecificInfo)
        let slConfig = descriptor(0x06, Data([0x02]))
        return descriptor(0x03, Data([0x00, 0x00, 0x00]) + decoderConfig + slConfig)
    }
}

/// Byte-level start code search shared by the MPEG video parsers.
private func startCodes(_ data: Data) -> [(offset: Int, code: UInt8)] {
    var codes: [(Int, UInt8)] = []
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let bytes = raw.bindMemory(to: UInt8.self)
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index + 2] > 1 {
                index += 3
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                codes.append((index, bytes[index + 3]))
                index += 4
            } else {
                index += 1
            }
        }
    }
    return codes
}

/// MPEG-4 Part 2 video (DivX, Xvid, camera MPEG-4).
enum MPEG4Visual {
    static let vopStartCode: UInt8 = 0xB6

    /// The headers before the first picture (visual object sequence and object layer): the
    /// decoder configuration that AVI stores in the first frame rather than in its header.
    static func decoderConfig(fromFrame frame: Data) -> Data? {
        let codes = startCodes(frame)
        guard let vop = codes.first(where: { $0.code == vopStartCode }), vop.offset > 0,
              codes.contains(where: { (0x20...0x2F).contains($0.code) }) else { return nil }
        return frame.prefix(vop.offset)
    }

    /// Simple profile only: the profile_and_level_indication of the sequence header, or the
    /// video_object_type_indication of the object layer when there is no sequence header.
    static func isSimpleProfile(_ config: Data) -> Bool {
        let data = Data(config)
        for (offset, code) in startCodes(data) {
            let next = offset + 4
            guard next < data.count else { continue }
            if code == 0xB0 {
                return (0x01...0x08).contains(data[next])
            }
            if (0x20...0x2F).contains(code) {
                var reader = BitReader(data.suffix(from: next))
                reader.skip(1) // random_accessible_vol
                return reader.read(8) == 1
            }
        }
        return true
    }

    /// vop_coding_type of the first picture: 0 is an intra (I) picture.
    static func isKeyframe(_ frame: Data) -> Bool {
        let data = Data(frame)
        guard let vop = startCodes(data).first(where: { $0.code == vopStartCode }), vop.offset + 4 < data.count else {
            return false
        }
        return data[vop.offset + 4] >> 6 == 0
    }
}

/// MPEG-1 and MPEG-2 video.
enum MPEG2Video {
    struct SequenceHeader: Equatable {
        var width: Int
        var height: Int
        /// Display aspect ratio, when the header gives one.
        var displayAspect: Double?
        var frameRate: Double?
    }

    static func sequenceHeader(in data: Data) -> SequenceHeader? {
        let data = Data(data)
        guard let start = startCodes(data).first(where: { $0.code == 0xB3 }), start.offset + 8 <= data.count else {
            return nil
        }
        var reader = BitReader(data.suffix(from: start.offset + 4))
        guard let width = reader.read(12), let height = reader.read(12),
              let aspect = reader.read(4), let rate = reader.read(4), width > 0, height > 0 else { return nil }
        let aspects: [Int: Double] = [2: 4.0 / 3, 3: 16.0 / 9, 4: 2.21]
        let rates = [0, 24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 50, 60000.0 / 1001, 60]
        return SequenceHeader(
            width: width, height: height, displayAspect: aspects[aspect],
            frameRate: rate > 0 && rate < rates.count ? rates[rate] : nil
        )
    }

    /// A picture that starts a group of pictures or is coded intra.
    static func isKeyframe(_ data: Data) -> Bool {
        let data = Data(data)
        for (offset, code) in startCodes(data) {
            if code == 0xB3 || code == 0xB8 { return true }
            if code == 0x00, offset + 5 < data.count {
                return data[offset + 5] >> 3 & 0x07 == 1 // picture_coding_type after the 10-bit temporal reference
            }
        }
        return false
    }
}

/// Motion JPEG as cameras record it: often without Huffman tables, which every frame then
/// shares with the standard ones (JPEG spec, annex K.3).
enum MotionJPEG {
    static func withHuffmanTables(_ frame: Data) -> Data {
        let bytes = [UInt8](frame)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return frame }
        var index = 2
        var insertAt: Int?
        while index + 4 <= bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            if marker == 0xC4 { return frame } // has its own tables
            if marker == 0xDA {
                insertAt = index
                break
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            index += 2 + length
        }
        guard let insertAt else { return frame }
        return Data(bytes[..<insertAt]) + standardTables + Data(bytes[insertAt...])
    }

    static let standardTables: Data = {
        let tables: [(UInt8, [UInt8], [UInt8])] = [
            (0x00, [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], Array(0...11)),
            (0x01, [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0], Array(0...11)),
            (0x10, [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D], [
                0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
                0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
                0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
                0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
                0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
                0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
                0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
                0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
                0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
                0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
                0xF9, 0xFA,
            ]),
            (0x11, [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77], [
                0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
                0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
                0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
                0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
                0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
                0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
                0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
                0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
                0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
                0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
                0xF9, 0xFA,
            ]),
        ]
        var body: [UInt8] = []
        for (classAndID, counts, values) in tables {
            body += [classAndID] + counts + values
        }
        let length = body.count + 2
        return Data([0xFF, 0xC4, UInt8(length >> 8), UInt8(length & 0xFF)] + body)
    }()
}
