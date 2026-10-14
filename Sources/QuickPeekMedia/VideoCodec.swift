import CoreMedia
import Foundation
import VideoToolbox

public enum MediaError: Error, Equatable {
    case noVideoTrack
    case unsupportedCodec(String)
    case noKeyframe
    case decodeFailed(OSStatus)
}

/// Video codecs that macOS can decode natively, keyed by their Matroska codec IDs.
public enum VideoCodec: Sendable, Equatable {
    case h264, hevc, vp9, av1, mpeg4, mpeg2

    public init?(matroskaID: String) {
        switch matroskaID {
        case "V_MPEG4/ISO/AVC": self = .h264
        case "V_MPEGH/ISO/HEVC": self = .hevc
        case "V_VP9": self = .vp9
        case "V_AV1": self = .av1
        case "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP", "V_MPEG4/ISO/AP": self = .mpeg4
        case "V_MPEG2", "V_MPEG1": self = .mpeg2
        default: return nil
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        case .vp9: kCMVideoCodecType_VP9
        case .av1: kCMVideoCodecType_AV1
        case .mpeg4: kCMVideoCodecType_MPEG4Video
        case .mpeg2: kCMVideoCodecType_MPEG2Video
        }
    }

    /// VP9 and AV1 decoders ship with macOS but must be opted into once per process.
    static let registerSupplementalDecoders: Void = {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
    }()
}

enum VideoFormat {
    static func description(for track: MatroskaTrack) throws -> CMVideoFormatDescription {
        guard let codec = VideoCodec(matroskaID: track.codecID), let video = track.video else {
            throw MediaError.unsupportedCodec(track.codecID)
        }
        var atoms: [String: Data] = [:]
        switch codec {
        case .h264:
            guard let config = track.codecPrivate else { throw MediaError.unsupportedCodec(track.codecID) }
            atoms["avcC"] = config
        case .hevc:
            guard let config = track.codecPrivate else { throw MediaError.unsupportedCodec(track.codecID) }
            atoms["hvcC"] = config
        case .av1:
            guard let config = track.codecPrivate else { throw MediaError.unsupportedCodec(track.codecID) }
            atoms["av1C"] = config
        case .vp9:
            atoms["vpcC"] = vp9Configuration(codecPrivate: track.codecPrivate)
        case .mpeg4, .mpeg2:
            break
        }

        var extensions: [CFString: Any] = [:]
        if !atoms.isEmpty {
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms as CFDictionary
        }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec.codecType,
            width: Int32(clamping: video.pixelWidth),
            height: Int32(clamping: video.pixelHeight),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw MediaError.decodeFailed(status) }
        return description
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
        isKeyframe: Bool
    ) throws -> CMSampleBuffer {
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

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var size = data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
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
}
