import Foundation

/// Finds frame boundaries in audio that arrives as a byte stream (MPEG-TS PES packets, AVI
/// chunks, FLV tags), so each frame can be handed to AudioToolbox as its own packet.
enum AudioFrames {
    enum Kind: Equatable { case adts, ac3, eac3, mpeg }

    struct Header: Equatable {
        /// Frame length in bytes, header included.
        var length: Int
        var samples: Int
        var sampleRate: Double
        var channels: Int
        /// ADTS: the size of the header to strip before decoding.
        var headerLength = 0
        /// ADTS: AudioSpecificConfig equivalent of the header.
        var audioSpecificConfig: Data?
        /// MPEG audio layer (1, 2 or 3).
        var layer = 0
    }

    static func header(_ kind: Kind, in bytes: [UInt8], at index: Int) -> Header? {
        switch kind {
        case .adts: adts(bytes, index)
        case .ac3, .eac3: ac3(bytes, index)
        case .mpeg: mpeg(bytes, index)
        }
    }

    // MARK: ADTS (ISO/IEC 14496-3, 1.A.2)

    static let aacSampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    private static func adts(_ b: [UInt8], _ i: Int) -> Header? {
        guard i + 7 <= b.count, b[i] == 0xFF, b[i + 1] & 0xF6 == 0xF0 else { return nil }
        let protectionAbsent = b[i + 1] & 1 == 1
        let objectType = Int(b[i + 2] >> 6) + 1
        let rateIndex = Int(b[i + 2] >> 2 & 0x0F)
        let channels = Int(b[i + 2] & 1) << 2 | Int(b[i + 3] >> 6)
        let length = Int(b[i + 3] & 0x03) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
        let blocks = Int(b[i + 6] & 0x03) + 1
        let headerLength = protectionAbsent ? 7 : 9
        guard rateIndex < aacSampleRates.count, length > headerLength else { return nil }
        let config = UInt16(objectType) << 11 | UInt16(rateIndex) << 7 | UInt16(channels) << 3
        return Header(
            length: length, samples: 1024 * blocks, sampleRate: aacSampleRates[rateIndex], channels: channels,
            headerLength: headerLength, audioSpecificConfig: Data([UInt8(config >> 8), UInt8(config & 0xFF)])
        )
    }

    // MARK: AC-3 and E-AC-3 (ATSC A/52)

    private static func ac3(_ b: [UInt8], _ i: Int) -> Header? {
        guard i + 8 <= b.count, b[i] == 0x0B, b[i + 1] == 0x77 else { return nil }
        let bsid = Int(b[i + 5] >> 3)
        let acmodChannels = [2, 1, 2, 3, 3, 4, 4, 5]
        if bsid <= 10 {
            let fscod = Int(b[i + 4] >> 6)
            let frmsizecod = Int(b[i + 4] & 0x3F)
            guard fscod < 3, frmsizecod < 38 else { return nil }
            let bitrate = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640][frmsizecod / 2]
            // Frame size in 16-bit words: 1536 samples at the nominal bitrate (A/52 table 5.18).
            let words: Int
            switch fscod {
            case 0: words = bitrate * 2
            case 1: words = bitrate * 1000 * 1536 / 44100 / 16 + (frmsizecod & 1)
            default: words = bitrate * 3
            }
            // bsi: bsid(5) bsmod(3) acmod(3), mix levels that depend on acmod, then lfeon.
            var reader = BitReader(Data(b[(i + 6)..<(i + 8)]))
            let acmod = reader.read(3) ?? 0
            if acmod & 1 != 0 && acmod != 1 { reader.skip(2) }
            if acmod & 4 != 0 { reader.skip(2) }
            if acmod == 2 { reader.skip(2) }
            let lfe = reader.read(1) ?? 0
            return Header(length: words * 2, samples: 1536, sampleRate: [48000.0, 44100, 32000][fscod], channels: acmodChannels[acmod] + lfe)
        }
        guard bsid <= 16 else { return nil }
        // E-AC-3: frmsiz in 16-bit words, and up to six audio blocks per frame.
        let frmsiz = Int(b[i + 2] & 0x07) << 8 | Int(b[i + 3])
        let fscod = Int(b[i + 4] >> 6)
        let numblkscod = Int(b[i + 4] >> 4 & 0x03)
        let blocks = fscod == 3 ? 6 : [1, 2, 3, 6][numblkscod]
        let rate: Double
        switch fscod {
        case 0: rate = 48000
        case 1: rate = 44100
        case 2: rate = 32000
        default: rate = [24000.0, 22050, 16000, 0][numblkscod]
        }
        guard rate > 0 else { return nil }
        let acmod = Int(b[i + 4] >> 1 & 0x07)
        let lfe = Int(b[i + 4] & 1)
        return Header(length: (frmsiz + 1) * 2, samples: 256 * blocks, sampleRate: rate, channels: acmodChannels[acmod] + lfe)
    }

    // MARK: MPEG audio (ISO/IEC 11172-3, 13818-3)

    private static func mpeg(_ b: [UInt8], _ i: Int) -> Header? {
        guard i + 4 <= b.count, b[i] == 0xFF, b[i + 1] & 0xE0 == 0xE0 else { return nil }
        let version = Int(b[i + 1] >> 3 & 0x03) // 0: 2.5, 2: 2, 3: 1
        let layerBits = Int(b[i + 1] >> 1 & 0x03)
        let bitrateIndex = Int(b[i + 2] >> 4)
        let rateIndex = Int(b[i + 2] >> 2 & 0x03)
        let padding = Int(b[i + 2] >> 1 & 1)
        guard version != 1, layerBits != 0, bitrateIndex != 0, bitrateIndex != 15, rateIndex != 3 else { return nil }
        let layer = 4 - layerBits
        let isVersion1 = version == 3
        let rates = [[11025.0, 12000, 8000], [], [22050, 24000, 16000], [44100, 48000, 32000]]
        let rate = rates[version][rateIndex]
        let bitrates: [Int]
        switch (isVersion1, layer) {
        case (true, 1): bitrates = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
        case (true, 2): bitrates = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
        case (true, _): bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        case (false, 1): bitrates = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]
        default: bitrates = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        }
        let bitrate = bitrates[bitrateIndex] * 1000
        let samples: Int
        let length: Int
        switch layer {
        case 1:
            samples = 384
            length = (12 * bitrate / Int(rate) + padding) * 4
        case 2:
            samples = 1152
            length = 144 * bitrate / Int(rate) + padding
        default:
            samples = isVersion1 ? 1152 : 576
            length = (isVersion1 ? 144 : 72) * bitrate / Int(rate) + padding
        }
        let channels = b[i + 3] >> 6 == 3 ? 1 : 2
        guard length > 4 else { return nil }
        return Header(length: length, samples: samples, sampleRate: rate, channels: channels, layer: layer)
    }

    /// Splits a byte stream into frames, carrying partial frames over to the next chunk and
    /// timing each frame from the chunk timestamps and the frames' own durations.
    struct Framer {
        let kind: Kind
        private var buffer: [UInt8] = []
        private var nextTime: Double?

        init(kind: Kind) {
            self.kind = kind
        }

        mutating func reset() {
            buffer.removeAll(keepingCapacity: true)
            nextTime = nil
        }

        /// Frames completed by `data`, each with its time in seconds and its header.
        mutating func append(_ data: Data, time: Double?) -> [(time: Double, header: Header, data: Data)] {
            if buffer.isEmpty, let time { nextTime = time }
            buffer.append(contentsOf: data)
            var frames: [(time: Double, header: Header, data: Data)] = []
            var index = 0
            while index + 8 <= buffer.count {
                guard let header = AudioFrames.header(kind, in: buffer, at: index), sane(header) else {
                    index += 1 // lost sync: look for the next frame
                    continue
                }
                let next = index + header.length
                guard next <= buffer.count else { break }
                // A sync word inside other data: a real frame is followed by another frame.
                if next + 8 <= buffer.count, AudioFrames.header(kind, in: buffer, at: next) == nil {
                    index += 1
                    continue
                }
                let time = nextTime ?? 0
                frames.append((time, header, Data(buffer[(index + header.headerLength)..<next])))
                nextTime = time + Double(header.samples) / header.sampleRate
                index = next
            }
            buffer.removeFirst(index)
            return frames
        }

        private func sane(_ header: Header) -> Bool {
            header.length >= 7 && header.length < 16_384 && header.sampleRate > 0
        }
    }
}
