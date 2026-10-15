import CoreMedia
import Foundation

/// Matroska as a `MediaContainer`: its tracks become streams, its frames packets.
extension MatroskaDemuxer: MediaContainer {
    public var formatName: String { docType == "webm" ? "WebM" : "Matroska" }

    public func packets(from position: Int64?) throws -> AnyIterator<MediaPacket> {
        let frames = try frames(fromClusterAt: position).makeIterator()
        return AnyIterator { [self] in
            guard let frame = frames.next() else { return nil }
            return MediaPacket(
                streamID: frame.trackNumber,
                presentationTime: time(fromTicks: frame.timestamp),
                isKeyframe: frame.isKeyframe,
                data: frame.data
            )
        }
    }

    static func mediaStream(_ track: MatroskaTrack) -> MediaStream {
        let kind: MediaKind = switch track.type {
        case .video: .video
        case .audio: .audio
        case .subtitle: .subtitle
        case .other: .other
        }
        let (codec, name) = codec(of: track)
        var stream = MediaStream(id: track.number, kind: kind, codec: codec, codecName: name)
        if let video = track.video {
            stream.width = video.pixelWidth
            stream.height = video.pixelHeight
            if let width = video.displayWidth, let height = video.displayHeight, width > 0, height > 0 {
                stream.displayAspect = Double(width) / Double(height)
            }
        }
        if let duration = track.defaultDuration, duration > 0, kind == .video {
            stream.frameRate = 1_000_000_000 / Double(duration)
        }
        if let audio = track.audio {
            stream.sampleRate = audio.samplingFrequency
            stream.channels = audio.channels
            stream.bitDepth = audio.bitDepth
        }
        stream.language = track.language
        stream.title = track.name
        return stream
    }

    private static func codec(of track: MatroskaTrack) -> (MediaCodec, String) {
        let config = track.codecPrivate
        switch track.codecID {
        case "V_MPEG4/ISO/AVC": return (config.map { .h264(avcC: $0) } ?? .unsupported("H.264"), "H.264")
        case "V_MPEGH/ISO/HEVC": return (config.map { .hevc(hvcC: $0) } ?? .unsupported("HEVC"), "HEVC")
        case "V_VP9": return (.vp9(vpcC: VideoFormat.vp9Configuration(codecPrivate: config)), "VP9")
        case "V_AV1": return (config.map { .av1(av1C: $0) } ?? .unsupported("AV1"), "AV1")
        case "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP", "V_MPEG4/ISO/AP": return (.mpeg4Visual(decoderConfig: config), "MPEG-4 Visual")
        case "V_MPEG2": return (.mpeg2Video, "MPEG-2 Video")
        case "V_MPEG1": return (.mpeg1Video, "MPEG-1 Video")
        case "V_MJPEG": return (.mjpeg, "Motion JPEG")
        case "V_MS/VFW/FOURCC":
            return config.flatMap(RIFFCodecs.bitmapInfo).map(RIFFCodecs.video) ?? (.unsupported("VfW"), "VfW")
        case "V_VP8": return (.unsupported("VP8"), "VP8")
        case "V_THEORA": return (.unsupported("Theora"), "Theora")

        case "A_AAC", "A_AAC/MPEG4/LC", "A_AAC/MPEG2/LC":
            let asc = config ?? AudioFormat.audioSpecificConfig(
                sampleRate: track.audio?.samplingFrequency ?? 48_000, channels: UInt32(track.audio?.channels ?? 2))
            return (.aac(audioSpecificConfig: asc), "AAC")
        case "A_OPUS": return (.opus(head: config), "Opus")
        case "A_FLAC":
            return (config.flatMap(AudioFormat.flacSpecificBox).map { .flac(dfLa: $0) } ?? .unsupported("FLAC"), "FLAC")
        case "A_AC3": return (.ac3, "AC-3")
        case "A_EAC3": return (.eac3, "E-AC-3")
        case "A_MPEG/L3": return (.mp3, "MP3")
        case "A_MPEG/L2": return (.mp2, "MP2")
        case "A_PCM/INT/LIT": return (.pcm(bits: track.audio?.bitDepth ?? 16, isFloat: false, isBigEndian: false), "PCM")
        case "A_PCM/INT/BIG": return (.pcm(bits: track.audio?.bitDepth ?? 16, isFloat: false, isBigEndian: true), "PCM")
        case "A_PCM/FLOAT/IEEE": return (.pcm(bits: track.audio?.bitDepth ?? 32, isFloat: true, isBigEndian: false), "PCM (float)")
        case "A_MS/ACM":
            return config.flatMap(RIFFCodecs.waveFormat).map(RIFFCodecs.audio) ?? (.unsupported("ACM"), "ACM")
        case "A_VORBIS": return (.unsupported("Vorbis"), "Vorbis")
        case "A_DTS": return (.unsupported("DTS"), "DTS")
        case "A_TRUEHD": return (.unsupported("TrueHD"), "TrueHD")
        default:
            return (.unsupported(track.codecID), track.codecID)
        }
    }
}
