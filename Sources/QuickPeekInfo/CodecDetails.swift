import Foundation

/// Names and parameters of codecs, decoded from their configuration records. Shared by the
/// AVFoundation and Matroska readers so both describe a stream the same way.
enum CodecDetails {
    // MARK: - Video

    static func videoCodecName(matroskaID id: String, codecPrivate: Data?) -> String {
        switch id {
        case "V_MPEG4/ISO/AVC": "H.264"
        case "V_MPEGH/ISO/HEVC": "HEVC"
        case "V_AV1": "AV1"
        case "V_VP9": "VP9"
        case "V_VP8": "VP8"
        case "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP", "V_MPEG4/ISO/AP": "MPEG-4 Visual"
        case "V_MPEG2": "MPEG-2"
        case "V_MPEG1": "MPEG-1"
        case "V_THEORA": "Theora"
        case "V_PRORES": "ProRes"
        case "V_MS/VFW/FOURCC":
            // BITMAPINFOHEADER: the compression FourCC is at offset 16.
            codecPrivate.flatMap { $0.count >= 20 ? fourCC(Data($0)[16..<20]) : nil }.map { "VFW (\($0))" } ?? "VFW"
        default: id
        }
    }

    static func videoCodecName(fourCC code: String) -> String {
        switch code {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "dvh1", "dvhe": "HEVC (Dolby Vision)"
        case "dva1", "dvav": "H.264 (Dolby Vision)"
        case "av01": "AV1"
        case "vp09": "VP9"
        case "vp08": "VP8"
        case "apco": "ProRes 422 Proxy"
        case "apcs": "ProRes 422 LT"
        case "apcn": "ProRes 422"
        case "apch": "ProRes 422 HQ"
        case "ap4h": "ProRes 4444"
        case "ap4x": "ProRes 4444 XQ"
        case "aprn", "aprh": "ProRes RAW"
        case "mp4v": "MPEG-4 Visual"
        case "jpeg", "mjpa", "mjpb": "Motion JPEG"
        case "rle ": "Apple Animation"
        case "png ": "PNG"
        default: code.trimmingCharacters(in: .whitespaces)
        }
    }

    /// "High@L4.1" from an AVCDecoderConfigurationRecord.
    static func h264Profile(avcC: Data) -> String? {
        let bytes = [UInt8](avcC)
        guard bytes.count >= 4 else { return nil }
        let profile = bytes[1], constraints = bytes[2], level = Int(bytes[3])
        let name: String
        switch profile {
        case 66: name = constraints & 0x40 != 0 ? "Constrained Baseline" : "Baseline"
        case 77: name = "Main"
        case 88: name = "Extended"
        case 100: name = "High"
        case 110: name = "High 10"
        case 122: name = "High 4:2:2"
        case 244: name = "High 4:4:4 Predictive"
        default: name = "Profile \(profile)"
        }
        let levelName = level == 9 || (level == 11 && profile == 66 && constraints & 0x10 != 0) ? "1b" : tenths(level)
        return "\(name)@L\(levelName)"
    }

    /// "Main 10@L5.1, High tier" from an HEVCDecoderConfigurationRecord.
    static func hevcProfile(hvcC: Data) -> String? {
        let bytes = [UInt8](hvcC)
        guard bytes.count >= 13 else { return nil }
        let tier = bytes[1] & 0x20 != 0 ? "High" : "Main"
        let profile = bytes[1] & 0x1F
        let names: [UInt8: String] = [1: "Main", 2: "Main 10", 3: "Main Still Picture", 4: "Range Extensions", 5: "High Throughput", 9: "Screen Content"]
        let level = tenths(Int(bytes[12]) / 3)
        return "\(names[profile] ?? "Profile \(profile)")@L\(level), \(tier) tier"
    }

    static func hevcBitDepth(hvcC: Data) -> Int? {
        let bytes = [UInt8](hvcC)
        return bytes.count >= 18 ? Int(bytes[17] & 0x07) + 8 : nil
    }

    static func h264BitDepth(avcC: Data) -> Int? {
        let bytes = [UInt8](avcC)
        guard bytes.count >= 2 else { return nil }
        return [66, 77, 88, 100].contains(bytes[1]) ? 8 : nil
    }

    /// VP9 profile from the first byte of an uncompressed frame header.
    static func vp9Profile(frame: Data) -> String? {
        guard let first = frame.first, first >> 6 == 0b10 else { return nil }
        let profile = Int((first >> 5) & 1) | Int((first >> 4) & 1) << 1
        return "Profile \(profile)"
    }

    /// "1" for 10, "4.1" for 41.
    private static func tenths(_ value: Int) -> String {
        value % 10 == 0 ? "\(value / 10)" : "\(value / 10).\(value % 10)"
    }

    // MARK: - Colour (ITU-T H.273 code points, as Matroska stores them)

    static func primariesName(_ code: Int) -> String? {
        [1: "BT.709", 4: "BT.470 M", 5: "BT.601 PAL", 6: "BT.601 NTSC", 7: "SMPTE 240M", 9: "BT.2020", 11: "DCI-P3", 12: "Display P3"][code]
    }

    static func transferName(_ code: Int) -> String? {
        [1: "BT.709", 6: "BT.601", 8: "Linear", 13: "sRGB", 14: "BT.2020 (10-bit)", 15: "BT.2020 (12-bit)", 16: "PQ (SMPTE ST 2084)", 18: "HLG"][code]
    }

    static func matrixName(_ code: Int) -> String? {
        [0: "RGB", 1: "BT.709", 5: "BT.601", 6: "BT.601", 9: "BT.2020 non-constant", 10: "BT.2020 constant"][code]
    }

    static func hdrName(transfer: Int?, dolbyVision: Bool) -> String? {
        if dolbyVision { return "Dolby Vision" }
        switch transfer {
        case 16: return "HDR10 (PQ)"
        case 18: return "HLG"
        default: return nil
        }
    }

    /// CoreMedia's colour strings mapped to the same code points.
    static func coreMediaPrimaries(_ value: String) -> Int? {
        ["ITU_R_709_2": 1, "EBU_3213": 5, "SMPTE_C": 6, "ITU_R_2020": 9, "DCI_P3": 11, "P3_D65": 12][value]
    }

    static func coreMediaTransfer(_ value: String) -> Int? {
        ["ITU_R_709_2": 1, "SMPTE_240M_1995": 7, "Linear": 8, "IEC_sRGB": 13, "ITU_R_2020": 14,
         "SMPTE_ST_2084_PQ": 16, "ITU_R_2100_HLG": 18][value]
    }

    static func coreMediaMatrix(_ value: String) -> Int? {
        ["ITU_R_709_2": 1, "ITU_R_601_4": 6, "SMPTE_240M_1995": 7, "ITU_R_2020": 9][value]
    }

    // MARK: - Audio

    static func audioCodecName(matroskaID id: String, codecPrivate: Data?) -> String {
        switch id {
        case let aac where aac.hasPrefix("A_AAC"):
            codecPrivate.flatMap { aacProfile(audioSpecificConfig: $0) } ?? "AAC"
        case "A_OPUS": "Opus"
        case "A_FLAC": "FLAC"
        case "A_AC3": "AC-3"
        case "A_EAC3": "E-AC-3"
        case "A_DTS": "DTS"
        case "A_TRUEHD": "Dolby TrueHD"
        case "A_MPEG/L3": "MP3"
        case "A_MPEG/L2": "MPEG Layer 2"
        case "A_VORBIS": "Vorbis"
        case "A_ALAC": "ALAC"
        case let pcm where pcm.hasPrefix("A_PCM"): "PCM"
        default: id
        }
    }

    static func aacProfile(audioSpecificConfig: Data) -> String? {
        guard let first = audioSpecificConfig.first else { return nil }
        return aacProfile(objectType: Int(first >> 3))
    }

    /// Finds the AudioSpecificConfig (DecoderSpecificInfo, tag 5) inside an MPEG-4 ES descriptor.
    static func aacProfile(elementaryStreamDescriptor data: Data) -> String? {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let tag = bytes[index]
            index += 1
            var length = 0
            for _ in 0..<4 where index < bytes.count {
                let byte = bytes[index]
                index += 1
                length = length << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            switch tag {
            case 0x03: index += 3 // ES_Descriptor: ES_ID and flags, then nested descriptors
            case 0x04: index += 13 // DecoderConfigDescriptor fixed fields, then DecoderSpecificInfo
            case 0x05:
                return index < bytes.count ? aacProfile(objectType: Int(bytes[index] >> 3)) : nil
            default: index += length
            }
        }
        return nil
    }

    static func aacProfile(objectType: Int) -> String {
        switch objectType {
        case 1: "AAC Main"
        case 2: "AAC LC"
        case 3: "AAC SSR"
        case 4: "AAC LTP"
        case 5: "HE-AAC"
        case 23: "AAC LD"
        case 29: "HE-AACv2"
        case 39: "AAC ELD"
        default: "AAC"
        }
    }

    static func channelDescription(_ channels: Int) -> String {
        let layouts = [1: "mono", 2: "stereo", 3: "2.1", 4: "quad", 5: "5.0", 6: "5.1", 7: "6.1", 8: "7.1", 10: "7.1.2", 12: "7.1.4"]
        return layouts[channels].map { "\(channels) (\($0))" } ?? "\(channels)"
    }

    static func shortChannels(_ channels: Int) -> String {
        [1: "mono", 2: "stereo", 6: "5.1", 8: "7.1"][channels] ?? "\(channels) ch"
    }

    static func sampleRate(_ hertz: Double, format: InfoFormat) -> String {
        "\(format.decimal(hertz / 1000, digits: 1)) kHz"
    }

    static func frameRate(_ fps: Double, format: InfoFormat) -> String {
        "\(format.decimal(fps, digits: 3)) fps"
    }

    static func fourCC(_ data: Data) -> String {
        String(decoding: data.map { (32...126).contains($0) ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }

    static func fourCC(_ code: FourCharCode) -> String {
        fourCC(Data([UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]))
    }
}
