import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

/// Decodes a single keyframe of a video into an image — the basis of thumbnails and poster
/// frames. Only the bytes of one keyframe are read and decoded.
public final class VideoFrameExtractor {
    public let container: MediaContainer
    public let stream: MediaStream

    public var videoCodec: String { stream.codecName }

    /// Keyframes are usually a few seconds apart; give up rather than scan a whole broken file.
    private static let maxPacketsScanned = 5_000

    public convenience init(url: URL) throws {
        try self.init(container: MediaContainers.open(url))
    }

    public init(container: MediaContainer) throws {
        self.container = container
        stream = try Self.videoStream(in: container.streams)
    }

    static func videoStream(in streams: [MediaStream]) throws -> MediaStream {
        guard let stream = streams.first(where: { $0.kind == .video }) else {
            throw MediaError.noVideoTrack
        }
        return stream
    }

    /// The first keyframe at or after `fraction` of the duration (10% skips most black intros).
    public func image(atFraction fraction: Double = 0.1, maxPixelSize: Int? = nil) throws -> CGImage {
        // Also rejects codecs this Mac cannot decode, such as AV1 without a hardware decoder,
        // before a slow failing session is attempted.
        let format = try VideoFormat.description(for: stream)
        let packet = try keyframe(atSeconds: (container.durationSeconds ?? 0) * fraction)
        let sample = try VideoFormat.sampleBuffer(packet.data, format: format, presentationTime: packet.presentationTime, isKeyframe: true)
        return try decode(sample, format: format, size: outputSize(format: format, maxPixelSize: maxPixelSize))
    }

    private func keyframe(atSeconds seconds: Double) throws -> MediaPacket {
        let starts = [container.seekPoint(forSeconds: seconds).position, nil]
        for start in starts {
            var scanned = 0
            for packet in try container.packets(from: start) where packet.streamID == stream.id {
                if packet.isKeyframe { return packet }
                scanned += 1
                if scanned > Self.maxPacketsScanned { break }
            }
        }
        throw MediaError.noKeyframe
    }

    /// Pixel size of the decoded image: display aspect ratio, scaled down to `maxPixelSize` if given.
    private func outputSize(format: CMVideoFormatDescription, maxPixelSize: Int?) -> (width: Int, height: Int) {
        guard let size = VideoFormat.displaySize(of: format) ?? stream.displaySize else { return (0, 0) }
        var width = size.width
        var height = size.height
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
                throw MediaError.unsupportedCodec(stream.codecName)
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
