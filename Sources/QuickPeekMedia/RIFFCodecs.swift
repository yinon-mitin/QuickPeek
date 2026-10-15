import Foundation

/// Codecs as Windows describes them — the FourCC of a BITMAPINFOHEADER and the format tag of a
/// WAVEFORMATEX. AVI uses both, and Matroska wraps them in V_MS/VFW/FOURCC and A_MS/ACM.
enum RIFFCodecs {
    struct BitmapInfo {
        var width: Int
        var height: Int
        var fourCC: String
        var bitCount: Int
        var extradata: Data
    }

    struct WaveFormat {
        var formatTag: Int
        var channels: Int
        var sampleRate: Double
        var averageBytesPerSecond: Int
        var blockAlign: Int
        var bitsPerSample: Int
        var extradata: Data
    }

    static func bitmapInfo(_ data: Data) -> BitmapInfo? {
        let data = Data(data)
        guard data.count >= 40 else { return nil }
        let headerSize = min(Int(data.uint32LE(at: 0)), data.count)
        return BitmapInfo(
            width: Int(Int32(bitPattern: data.uint32LE(at: 4))),
            height: abs(Int(Int32(bitPattern: data.uint32LE(at: 8)))),
            fourCC: data.fourCC(at: 16),
            bitCount: Int(data.uint16LE(at: 14)),
            extradata: headerSize >= 40 ? data.subdata(in: headerSize..<data.count) : Data()
        )
    }

    static func waveFormat(_ data: Data) -> WaveFormat? {
        let data = Data(data)
        guard data.count >= 14 else { return nil }
        var format = WaveFormat(
            formatTag: Int(data.uint16LE(at: 0)),
            channels: Int(data.uint16LE(at: 2)),
            sampleRate: Double(data.uint32LE(at: 4)),
            averageBytesPerSecond: Int(data.uint32LE(at: 8)),
            blockAlign: Int(data.uint16LE(at: 12)),
            bitsPerSample: data.count >= 16 ? Int(data.uint16LE(at: 14)) : 8,
            extradata: Data()
        )
        if data.count >= 18 {
            let size = min(Int(data.uint16LE(at: 16)), data.count - 18)
            format.extradata = data.subdata(in: 18..<18 + size)
        }
        // WAVE_FORMAT_EXTENSIBLE: the real format tag starts the SubFormat GUID.
        if format.formatTag == 0xFFFE, format.extradata.count >= 22 {
            format.formatTag = Int(format.extradata.uint16LE(at: 6))
        }
        return format
    }

    static func video(_ info: BitmapInfo) -> (codec: MediaCodec, name: String) {
        let extra = info.extradata.isEmpty ? nil : info.extradata
        switch info.fourCC.uppercased() {
        case "H264", "X264", "AVC1", "DAVC", "VSSH":
            if let extra, extra.first == 1 { return (.h264(avcC: extra), "H.264") }
            return (.h264ParameterSets([]), "H.264")
        case "HEVC", "H265", "HEV1", "HVC1":
            if let extra, extra.first == 1 { return (.hevc(hvcC: extra), "HEVC") }
            return (.hevcParameterSets([]), "HEVC")
        case "XVID": return (.mpeg4Visual(decoderConfig: extra), "MPEG-4 Visual (Xvid)")
        case "DIVX", "DX50", "DX40": return (.mpeg4Visual(decoderConfig: extra), "MPEG-4 Visual (DivX)")
        case "FMP4", "MP4V", "M4S2", "3IV2", "XVIX", "RMP4", "SMP4", "BLZ0", "UMP4":
            return (.mpeg4Visual(decoderConfig: extra), "MPEG-4 Visual")
        case "MJPG", "AVRN", "LJPG", "JPGL", "DMB1", "AVDJ", "MJPA", "QIVG":
            return (.mjpeg, "Motion JPEG")
        case "MPG2", "MPEG", "MX5P", "MMES", "HDV2", "HDV3":
            return (.mpeg2Video, "MPEG-2 Video")
        case "MPG1", "PIM1", "\u{1}\0\0\u{10}":
            return (.mpeg1Video, "MPEG-1 Video")
        case "VP80": return (.unsupported("VP8"), "VP8")
        case "VP90": return (.vp9(vpcC: VideoFormat.vp9Configuration(codecPrivate: nil)), "VP9")
        case "AV01": return extra.map { (.av1(av1C: $0), "AV1") } ?? (.unsupported("AV1"), "AV1")
        case "DIV3", "DIV4", "DIV5", "MP43", "MP42", "MPG4", "AP41": return (.unsupported("MS MPEG-4"), "MS MPEG-4 (DivX 3)")
        case "WMV1", "WMV2", "WMV3", "WVC1", "WMVA": return (.unsupported("WMV"), "Windows Media Video")
        case "CVID": return (.unsupported("Cinepak"), "Cinepak")
        case "IV31", "IV32", "IV41", "IV50": return (.unsupported("Indeo"), "Indeo")
        case "DVSD", "DV25", "DV50", "CDVC", "DVHD", "DVSL": return (.unsupported("DV"), "DV")
        default:
            let name = info.fourCC.trimmingCharacters(in: .controlCharacters.union(.whitespaces))
            return (.unsupported(name.isEmpty ? "uncompressed" : name), name.isEmpty ? "Uncompressed" : name)
        }
    }

    static func audio(_ format: WaveFormat) -> (codec: MediaCodec, name: String) {
        switch format.formatTag {
        case 0x0001: return (.pcm(bits: format.bitsPerSample, isFloat: false, isBigEndian: false), "PCM")
        case 0x0003: return (.pcm(bits: format.bitsPerSample, isFloat: true, isBigEndian: false), "PCM (float)")
        case 0x0006: return (.alaw, "A-law")
        case 0x0007: return (.ulaw, "μ-law")
        case 0x0050: return (.mp2, "MP2")
        case 0x0055: return (.mp3, "MP3")
        case 0x2000: return (.ac3, "AC-3")
        case 0x00FF, 0x1610, 0x706D, 0x4143, 0xA106:
            let config = format.extradata.count >= 2 ? format.extradata
                : AudioFormat.audioSpecificConfig(sampleRate: format.sampleRate, channels: UInt32(format.channels))
            return (.aac(audioSpecificConfig: config), "AAC")
        case 0x0002: return (.unsupported("MS ADPCM"), "MS ADPCM")
        case 0x0011: return (.unsupported("IMA ADPCM"), "IMA ADPCM")
        case 0x2001: return (.unsupported("DTS"), "DTS")
        case 0x0160, 0x0161, 0x0162, 0x0163: return (.unsupported("WMA"), "Windows Media Audio")
        case 0x674F, 0x6750, 0x6751, 0x676F, 0x6770, 0x6771: return (.unsupported("Vorbis"), "Vorbis")
        default:
            let name = String(format: "audio format 0x%04X", format.formatTag)
            return (.unsupported(name), name)
        }
    }
}

extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func uint16BE(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func uint24BE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 16 | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2])
    }

    func uint32BE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func fourCC(at offset: Int) -> String {
        let i = startIndex + offset
        guard i + 4 <= endIndex else { return "" }
        return String(decoding: self[i..<i + 4], as: UTF8.self)
    }
}
