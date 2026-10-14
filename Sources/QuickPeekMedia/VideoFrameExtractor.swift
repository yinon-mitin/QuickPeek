import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

/// Decodes a single keyframe of a Matroska/WebM video into an image — the basis of thumbnails
/// and poster frames. Only the bytes of one keyframe are read and decoded.
public final class VideoFrameExtractor {
    public let demuxer: MatroskaDemuxer
    public let track: MatroskaTrack

    public var videoCodec: String { track.codecID }

    /// Keyframes are usually a few seconds apart; give up rather than scan a whole broken file.
    private static let maxFramesScanned = 5_000

    public init(url: URL) throws {
        demuxer = try MatroskaDemuxer(url: url)
        track = try Self.videoTrack(in: demuxer.tracks)
    }

    static func videoTrack(in tracks: [MatroskaTrack]) throws -> MatroskaTrack {
        guard let track = tracks.first(where: { $0.type == .video && $0.video != nil }) else {
            throw MediaError.noVideoTrack
        }
        return track
    }

    /// The first keyframe at or after `fraction` of the duration (10% skips most black intros).
    public func image(atFraction fraction: Double = 0.1, maxPixelSize: Int? = nil) throws -> CGImage {
        _ = VideoCodec.registerSupplementalDecoders
        guard let codec = VideoCodec(matroskaID: track.codecID) else {
            throw MediaError.unsupportedCodec(track.codecID)
        }
        if codec == .av1 && !VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) {
            // macOS has no software AV1 decoder; avoid a slow failing session.
            throw MediaError.unsupportedCodec(track.codecID)
        }

        let format = try VideoFormat.description(for: track)
        let frame = try keyframe(atSeconds: (demuxer.durationSeconds ?? 0) * fraction)
        let pts = CMTime(seconds: demuxer.seconds(fromTicks: frame.timestamp), preferredTimescale: 90_000)
        let sample = try VideoFormat.sampleBuffer(frame.data, format: format, presentationTime: pts, isKeyframe: true)
        return try decode(sample, format: format, size: outputSize(maxPixelSize: maxPixelSize))
    }

    private func keyframe(atSeconds seconds: Double) throws -> MatroskaFrame {
        let starts = [demuxer.clusterPosition(forSeconds: seconds), nil]
        for start in starts {
            var scanned = 0
            for frame in try demuxer.frames(fromClusterAt: start) where frame.trackNumber == track.number {
                if frame.isKeyframe { return frame }
                scanned += 1
                if scanned > Self.maxFramesScanned { break }
            }
        }
        throw MediaError.noKeyframe
    }

    /// Pixel size of the decoded image: display aspect ratio, scaled down to `maxPixelSize` if given.
    private func outputSize(maxPixelSize: Int?) -> (width: Int, height: Int) {
        guard let video = track.video else { return (0, 0) }
        var width = Double(video.displayWidth ?? video.pixelWidth)
        var height = Double(video.displayHeight ?? video.pixelHeight)
        if video.displayWidth == nil || video.displayHeight == nil {
            width = Double(video.pixelWidth)
            height = Double(video.pixelHeight)
        } else if height > 0 {
            // DisplayWidth/Height give the aspect ratio; keep the stored pixel height.
            width = Double(video.pixelHeight) * width / height
            height = Double(video.pixelHeight)
        }
        if let maxPixelSize, max(width, height) > Double(maxPixelSize) {
            let scale = Double(maxPixelSize) / max(width, height)
            width *= scale
            height *= scale
        }
        return (max(1, Int(width.rounded())), max(1, Int(height.rounded())))
    }

    private final class DecodeResult: @unchecked Sendable {
        var image: CGImage?
        var status: OSStatus = noErr
    }

    private func decode(_ sample: CMSampleBuffer, format: CMVideoFormatDescription, size: (width: Int, height: Int)) throws -> CGImage {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var session: VTDecompressionSession?
        var status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            if status == kVTCouldNotFindVideoDecoderErr || status == kVTVideoDecoderUnsupportedDataFormatErr {
                throw MediaError.unsupportedCodec(track.codecID)
            }
            throw MediaError.decodeFailed(status)
        }
        defer { VTDecompressionSessionInvalidate(session) }

        let result = DecodeResult()
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, imageBuffer, _, _ in
            result.status = status
            if status == noErr, let imageBuffer {
                var image: CGImage?
                VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &image)
                result.image = image
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)

        if status != noErr { throw MediaError.decodeFailed(status) }
        if result.status != noErr { throw MediaError.decodeFailed(result.status) }
        guard let image = result.image else { throw MediaError.decodeFailed(-1) }
        return image
    }
}
