import CoreGraphics
import Foundation
import Testing
@testable import QuickPeekMedia

@Suite("VideoFrameExtractor")
struct VideoFrameExtractorTests {
    /// testsrc2 is a colourful pattern; a real decode has many distinct colours, a failed one is flat.
    private func distinctColors(in image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var colors = Set<UInt32>()
        for i in stride(from: 0, to: pixels.count, by: 4 * 7) {
            // Quantise so compression noise does not inflate the count.
            colors.insert(UInt32(pixels[i] >> 4) << 8 | UInt32(pixels[i + 1] >> 4) << 4 | UInt32(pixels[i + 2] >> 4))
        }
        return colors.count
    }

    @Test("Hardware codecs decode a keyframe to an image", arguments: ["h264_aac.mkv", "hevc_ac3.mkv", "vp9_opus.webm"])
    func decodes(file: String) throws {
        let extractor = try VideoFrameExtractor(url: fixtureURL(file))
        let image = try extractor.image()
        #expect(image.width == 160)
        #expect(image.height == 120)
        #expect(distinctColors(in: image) > 20)
    }

    @Test("Images are scaled down to the requested size, keeping the aspect ratio")
    func scaled() throws {
        let extractor = try VideoFrameExtractor(url: fixtureURL("h264_aac.mkv"))
        let image = try extractor.image(maxPixelSize: 80)
        #expect(image.width == 80)
        #expect(image.height == 60)
    }

    @Test("AV1 decodes where the Mac supports it and fails cleanly where it does not")
    func av1() throws {
        let extractor = try VideoFrameExtractor(url: fixtureURL("av1_flac.mkv"))
        do {
            let image = try extractor.image()
            #expect(image.width == 160)
        } catch let error as MediaError {
            #expect(error == .unsupportedCodec("AV1"))
        }
    }

    @Test("Codec support is reported per track")
    func support() throws {
        let extractor = try VideoFrameExtractor(url: fixtureURL("vp9_opus.webm"))
        #expect(extractor.videoCodec == "VP9")
        let theora = MatroskaTrack(number: 1, type: .video, codecID: "V_THEORA", video: .init(pixelWidth: 64, pixelHeight: 64))
        #expect(MatroskaDemuxer.mediaStream(theora).codec == .unsupported("Theora"))
        #expect(throws: MediaError.unsupportedCodec("Theora")) {
            try VideoFormat.description(for: MatroskaDemuxer.mediaStream(theora))
        }
    }

    @Test("Audio-only files have no frame to extract")
    func audioOnly() throws {
        let data = try Data(contentsOf: fixtureURL("h264_aac.mkv"))
        let demuxer = try MatroskaDemuxer(source: DataByteSource(data))
        let streams = demuxer.streams.filter { $0.kind != .video }
        #expect(throws: MediaError.noVideoTrack) {
            try VideoFrameExtractor.videoStream(in: streams)
        }
    }
}
