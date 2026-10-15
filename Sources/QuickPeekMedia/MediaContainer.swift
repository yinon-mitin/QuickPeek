import CoreMedia
import Foundation

public enum MediaKind: Sendable, Equatable {
    case video, audio, subtitle, other
}

/// How a stream is coded, with the configuration its decoder needs. Containers translate their
/// own descriptions (Matroska codec IDs, AVI FourCCs, MPEG-TS stream types…) into this.
public enum MediaCodec: Sendable, Equatable {
    case h264(avcC: Data)
    /// SPS and PPS NAL units found in an Annex B stream (MPEG-TS, AVI).
    case h264ParameterSets([Data])
    case hevc(hvcC: Data)
    /// VPS, SPS and PPS NAL units found in an Annex B stream.
    case hevcParameterSets([Data])
    case vp9(vpcC: Data)
    case av1(av1C: Data)
    /// MPEG-4 Part 2 (Xvid, DivX): the visual object sequence / VOL header, when known.
    case mpeg4Visual(decoderConfig: Data?)
    case mpeg2Video
    case mpeg1Video
    case mjpeg

    case aac(audioSpecificConfig: Data)
    case opus(head: Data?)
    /// The complete `dfLa` box.
    case flac(dfLa: Data)
    case ac3
    case eac3
    case mp3
    case mp2
    case pcm(bits: Int, isFloat: Bool, isBigEndian: Bool)
    case alaw
    case ulaw

    /// A codec macOS cannot decode; the payload names it for the user.
    case unsupported(String)
}

public struct MediaStream: Sendable {
    public var id: UInt64
    public var kind: MediaKind
    public var codec: MediaCodec
    /// Short display name: "H.264", "AAC", "Vorbis".
    public var codecName: String
    public var width = 0
    public var height = 0
    /// Display width ÷ height when it differs from the pixel aspect.
    public var displayAspect: Double?
    public var frameRate: Double?
    public var sampleRate: Double = 0
    public var channels = 0
    public var bitDepth: Int?
    public var language: String?
    public var title: String?

    public init(id: UInt64, kind: MediaKind, codec: MediaCodec, codecName: String) {
        self.id = id
        self.kind = kind
        self.codec = codec
        self.codecName = codecName
    }

    /// Display size, aspect ratio applied.
    public var displaySize: CGSize? {
        guard width > 0, height > 0 else { return nil }
        if let aspect = displayAspect { return CGSize(width: (Double(height) * aspect).rounded(), height: Double(height)) }
        return CGSize(width: width, height: height)
    }
}

public struct MediaPacket: Sendable {
    public var streamID: UInt64
    public var presentationTime: CMTime
    /// Set when it differs from the presentation time (streams with B-frames).
    public var decodeTime: CMTime
    public var isKeyframe: Bool
    /// Ready for the decoder: H.264/HEVC as length-prefixed NAL units, audio as raw frames.
    public var data: Data

    public init(streamID: UInt64, presentationTime: CMTime, decodeTime: CMTime = .invalid, isKeyframe: Bool, data: Data) {
        self.streamID = streamID
        self.presentationTime = presentationTime
        self.decodeTime = decodeTime
        self.isKeyframe = isKeyframe
        self.data = data
    }
}

/// A container format QuickPeek can demux: Matroska/WebM, MPEG-TS, AVI, FLV.
public protocol MediaContainer: AnyObject {
    var formatName: String { get }
    var durationSeconds: Double? { get }
    var streams: [MediaStream] { get }
    /// Packets in file order, from the start or from a position returned by `seekPoint`.
    func packets(from position: Int64?) throws -> AnyIterator<MediaPacket>
    /// Where to resume reading to reach `seconds`, and the time playback actually resumes at.
    func seekPoint(forSeconds seconds: Double) -> (position: Int64?, seconds: Double)
}

public enum MediaContainers {
    /// File extensions QuickPeek plays and thumbnails.
    /// Other containers (MP4, MOV, MPEG-TS, Ogg audio) are left to AVFoundation, which reads them itself.
    public static let extensions: Set<String> = ["mkv", "mka", "mk3d", "webm"]

    public static func handles(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Opens a file by its contents (with the extension as a tie-breaker).
    public static func open(_ url: URL) throws -> MediaContainer {
        let source = try FileByteSource(url: url)
        let head = try source.read(at: 0, count: Int(min(source.size, 1024)))
        if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return try MatroskaDemuxer(source: source)
        }
        throw MediaError.unsupportedCodec(url.pathExtension.uppercased())
    }
}
