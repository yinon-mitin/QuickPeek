import CoreMedia
import Foundation
import VideoToolbox

public enum MediaError: Error, Equatable {
    case noVideoTrack
    case unsupportedCodec(String)
    case noKeyframe
    case decodeFailed(OSStatus)
}

extension MediaCodec {
    /// Whether this Mac can decode the codec: AV1 needs a hardware decoder (M3 or later), and
    /// MPEG-4 Part 2 decodes only in its Simple profile, not Xvid/DivX's Advanced Simple.
    public var isDecodable: Bool {
        switch self {
        case .unsupported: false
        case .av1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        case .mpeg4Visual(let config): config.map(MPEG4Visual.isSimpleProfile) ?? true
        default: true
        }
    }

    var videoCodecType: CMVideoCodecType? {
        switch self {
        case .h264, .h264ParameterSets: kCMVideoCodecType_H264
        case .hevc, .hevcParameterSets: kCMVideoCodecType_HEVC
        case .vp9: kCMVideoCodecType_VP9
        case .av1: kCMVideoCodecType_AV1
        case .mpeg4Visual: kCMVideoCodecType_MPEG4Video
        case .mpeg2Video: kCMVideoCodecType_MPEG2Video
        case .mpeg1Video: kCMVideoCodecType_MPEG1Video
        case .mjpeg: kCMVideoCodecType_JPEG
        default: nil
        }
    }
}

enum VideoFormat {
    /// VP9 and AV1 decoders ship with macOS but must be opted into once per process.
    static let registerSupplementalDecoders: Void = {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
    }()

    static func description(for stream: MediaStream) throws -> CMVideoFormatDescription {
        _ = registerSupplementalDecoders
        guard stream.codec.isDecodable, let codecType = stream.codec.videoCodecType else {
            throw MediaError.unsupportedCodec(stream.codecName)
        }
        var extensions: [CFString: Any] = [:]
        var atoms: [String: Data] = [:]
        switch stream.codec {
        case .h264ParameterSets(let sets):
            return try parameterSetDescription(sets, codec: .h264, stream: stream)
        case .hevcParameterSets(let sets):
            return try parameterSetDescription(sets, codec: .hevc, stream: stream)
        case .h264(let config): atoms["avcC"] = config
        case .hevc(let config): atoms["hvcC"] = config
        case .av1(let config): atoms["av1C"] = config
        case .vp9(let config): atoms["vpcC"] = config
        case .mpeg4Visual(let config?):
            atoms["esds"] = Data([0, 0, 0, 0]) + ElementaryStream.descriptor(objectType: 0x20, streamType: 0x04, config: config)
        default: break
        }
        if !atoms.isEmpty {
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms as CFDictionary
        }
        if let ratio = pixelAspectRatio(stream) {
            extensions[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: ratio.horizontal,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: ratio.vertical,
            ] as CFDictionary
        }
        guard stream.width > 0, stream.height > 0 else { throw MediaError.unsupportedCodec(stream.codecName) }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(clamping: stream.width),
            height: Int32(clamping: stream.height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw MediaError.decodeFailed(status) }
        return description
    }

    private static func parameterSetDescription(_ sets: [Data], codec: AnnexB.Codec, stream: MediaStream) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let pointers = sets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return UnsafePointer(pointer)
        }
        defer { pointers.forEach { $0.deallocate() } }
        let sizes = sets.map(\.count)
        let status = codec == .h264
            ? CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            : CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw MediaError.decodeFailed(status) }
        return description
    }

    /// Display size with the pixel aspect ratio applied, as the decoder will show it.
    public static func displaySize(of format: CMVideoFormatDescription) -> CGSize? {
        let size = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: false)
        return size.width > 0 && size.height > 0 ? CGSize(width: size.width.rounded(), height: size.height.rounded()) : nil
    }

    /// Pixel aspect ratio as a fraction, when the display aspect differs from width ÷ height.
    private static func pixelAspectRatio(_ stream: MediaStream) -> (horizontal: Int, vertical: Int)? {
        guard let aspect = stream.displayAspect, stream.width > 0, stream.height > 0 else { return nil }
        let ratio = aspect * Double(stream.height) / Double(stream.width)
        guard abs(ratio - 1) > 0.01 else { return nil }
        return (Int((ratio * 10_000).rounded()), 10_000)
    }

    /// Builds the `vpcC` box body (VP Codec Configuration, version 1). Matroska usually carries
    /// no VP9 configuration at all, or only a small feature list; anything missing gets 8-bit 4:2:0 BT.709.
    static func vp9Configuration(codecPrivate: Data?) -> Data {
        var profile: UInt8 = 0
        var level: UInt8 = 10
        var bitDepth: UInt8 = 8
        var chroma: UInt8 = 1

        if let features = codecPrivate.map({ Data($0) }) {
            var index = 0
            while index + 2 <= features.count {
                let id = features[index]
                let length = Int(features[index + 1])
                guard length >= 1, index + 2 + length <= features.count else { break }
                let value = features[index + 2]
                switch id {
                case 1: profile = value
                case 2: level = value
                case 3: bitDepth = value
                case 4: chroma = value
                default: break
                }
                index += 2 + length
            }
        }

        let bt709: UInt8 = 1
        return Data([
            1, 0, 0, 0, // version 1, flags
            profile, level,
            bitDepth << 4 | chroma << 1, // video_full_range_flag = 0
            bt709, bt709, bt709, // colour primaries, transfer characteristics, matrix coefficients
            0, 0, // no codec initialization data
        ])
    }

    static func sampleBuffer(
        _ data: Data,
        format: CMFormatDescription,
        presentationTime: CMTime,
        decodeTime: CMTime = .invalid,
        isKeyframe: Bool
    ) throws -> CMSampleBuffer {
        let blockBuffer = try blockBuffer(data)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: decodeTime)
        var size = data.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw MediaError.decodeFailed(status) }

        if !isKeyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    /// Copies bytes into a CMBlockBuffer that owns its memory.
    static func blockBuffer(_ data: Data) throws -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { throw MediaError.decodeFailed(status) }
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count
            )
        }
        guard status == noErr else { throw MediaError.decodeFailed(status) }
        return blockBuffer
    }
}
