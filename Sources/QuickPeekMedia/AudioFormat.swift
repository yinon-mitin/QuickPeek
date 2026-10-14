import AudioToolbox
import CoreMedia
import Foundation

/// Describes a Matroska audio track the way AudioToolbox expects it: stream format plus the
/// decoder configuration ("magic cookie") translated from Matroska's CodecPrivate.
public struct AudioFormat {
    enum Codec { case aac, opus, flac, ac3, eac3, mp3 }

    public let codecID: String
    public private(set) var streamDescription: AudioStreamBasicDescription
    public private(set) var magicCookie: Data?
    let codec: Codec

    public init(track: MatroskaTrack) throws {
        guard let audio = track.audio else { throw MediaError.unsupportedCodec(track.codecID) }
        codecID = track.codecID
        let channels = UInt32(max(1, audio.channels))
        var description = AudioStreamBasicDescription(
            mSampleRate: audio.samplingFrequency, mFormatID: 0, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0
        )

        switch track.codecID {
        case "A_AAC", "A_AAC/MPEG4/LC", "A_AAC/MPEG2/LC":
            codec = .aac
            let config = track.codecPrivate ?? Self.audioSpecificConfig(sampleRate: audio.samplingFrequency, channels: channels)
            description.mFormatID = kAudioFormatMPEG4AAC
            description.mFormatFlags = UInt32(config.first.map { $0 >> 3 } ?? 2) // audio object type
            description.mFramesPerPacket = 1024
            magicCookie = Self.elementaryStreamDescriptor(audioSpecificConfig: config)
        case "A_OPUS":
            codec = .opus
            description.mFormatID = kAudioFormatOpus
            description.mSampleRate = 48_000 // Opus always decodes at 48 kHz
            description.mFramesPerPacket = 0 // varies per packet; see framesInPacket(_:)
            // AudioToolbox takes Matroska's CodecPrivate (the Ogg "OpusHead" packet) as is.
            magicCookie = track.codecPrivate
        case "A_FLAC":
            codec = .flac
            guard let config = track.codecPrivate, let cookie = Self.flacSpecificBox(codecPrivate: config) else {
                throw MediaError.unsupportedCodec(track.codecID)
            }
            description.mFormatID = kAudioFormatFLAC
            description.mFramesPerPacket = Self.flacFixedBlockSize(cookie) ?? 0
            description.mFormatFlags = Self.flacBitDepthFlag(audio.bitDepth ?? 16)
            magicCookie = cookie
        case "A_AC3":
            codec = .ac3
            description.mFormatID = kAudioFormatAC3
            description.mFramesPerPacket = 1536
        case "A_EAC3":
            codec = .eac3
            description.mFormatID = kAudioFormatEnhancedAC3
            description.mFramesPerPacket = 1536
        case "A_MPEG/L3":
            codec = .mp3
            description.mFormatID = kAudioFormatMPEGLayer3
            description.mFramesPerPacket = audio.samplingFrequency >= 32_000 ? 1152 : 576
        default:
            throw MediaError.unsupportedCodec(track.codecID)
        }
        streamDescription = description
    }

    /// Frames (samples per channel) in one packet; 0 when the stream format already says it.
    public func framesInPacket(_ packet: Data) -> Int {
        switch codec {
        case .opus: return Self.opusSamplesPerPacket(packet)
        default: return 0
        }
    }

    public func formatDescription() throws -> CMAudioFormatDescription {
        var description = streamDescription
        var format: CMAudioFormatDescription?
        let status: OSStatus
        if let cookie = magicCookie {
            status = cookie.withUnsafeBytes { bytes in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                    magicCookieSize: cookie.count, magicCookie: bytes.baseAddress, extensions: nil,
                    formatDescriptionOut: &format
                )
            }
        } else {
            status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
            )
        }
        guard status == noErr, let format else { throw MediaError.decodeFailed(status) }
        return format
    }

    /// One compressed packet as a sample buffer for AVSampleBufferAudioRenderer.
    func sampleBuffer(_ packet: Data, format: CMAudioFormatDescription, presentationTime: CMTime) throws -> CMSampleBuffer {
        let blockBuffer = try VideoFormat.blockBuffer(packet)
        var description = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: UInt32(framesInPacket(packet)),
            mDataByteSize: UInt32(packet.count)
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            presentationTimeStamp: presentationTime,
            packetDescriptions: &description,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw MediaError.decodeFailed(status) }
        return sampleBuffer
    }

    // MARK: - Codec configuration

    /// Samples at 48 kHz in an Opus packet, from its TOC byte (RFC 6716, section 3.1).
    static func opusSamplesPerPacket(_ packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let frameSamples: Int
        switch config {
        case 0..<12: frameSamples = [480, 960, 1920, 2880][config % 4]   // SILK 10/20/40/60 ms
        case 12..<16: frameSamples = [480, 960][config % 2]              // Hybrid 10/20 ms
        default: frameSamples = [120, 240, 480, 960][config % 4]         // CELT 2.5/5/10/20 ms
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = packet.count > 1 ? Int(packet[packet.startIndex + 1] & 0x3F) : 0
        }
        return frameSamples * frames
    }

    /// MPEG-4 ES_Descriptor wrapping the AudioSpecificConfig — the body of an MP4 `esds` box,
    /// which is what Apple's AAC decoder takes as its magic cookie.
    static func elementaryStreamDescriptor(audioSpecificConfig config: Data) -> Data {
        func descriptor(_ tag: UInt8, _ payload: Data) -> Data {
            var data = Data([tag])
            let length = payload.count
            data += [0x80 | UInt8((length >> 21) & 0x7F), 0x80 | UInt8((length >> 14) & 0x7F),
                     0x80 | UInt8((length >> 7) & 0x7F), UInt8(length & 0x7F)]
            return data + payload
        }
        let decoderSpecificInfo = descriptor(0x05, config)
        let decoderConfig = descriptor(0x04, Data([0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + decoderSpecificInfo)
        let slConfig = descriptor(0x06, Data([0x02]))
        return descriptor(0x03, Data([0x00, 0x00, 0x00]) + decoderConfig + slConfig)
    }

    /// AAC-LC AudioSpecificConfig for old files that name the profile in the codec ID instead.
    static func audioSpecificConfig(sampleRate: Double, channels: UInt32) -> Data {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let index = UInt16(rates.firstIndex(of: sampleRate) ?? 3)
        let value: UInt16 = 2 << 11 | index << 7 | UInt16(channels & 0x0F) << 3
        return Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Matroska stores "fLaC" + metadata blocks; Apple's FLAC decoder takes a complete MP4 `dfLa`
    /// box: size, type, version/flags, then the metadata blocks with the last one flagged.
    static func flacSpecificBox(codecPrivate: Data) -> Data? {
        let data = Data(codecPrivate)
        var blocks = Data(data.prefix(4) == Data("fLaC".utf8) ? data.dropFirst(4) : data[...])
        guard blocks.count >= 38 else { return nil }
        var index = 0
        while index + 4 <= blocks.count {
            let length = Int(blocks[index + 1]) << 16 | Int(blocks[index + 2]) << 8 | Int(blocks[index + 3])
            if index + 4 + length >= blocks.count {
                blocks[index] |= 0x80
                break
            }
            index += 4 + length
        }
        let size = UInt32(8 + 4 + blocks.count)
        return Data([UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
            + Data("dfLa".utf8) + Data([0, 0, 0, 0]) + blocks
    }

    /// STREAMINFO min/max block size; a fixed block size becomes the packet size.
    static func flacFixedBlockSize(_ box: Data) -> UInt32? {
        // box header (8) + version/flags (4) + metadata block header (4)
        let info = box.startIndex + 16
        guard box.count >= 16 + 4 else { return nil }
        let minimum = UInt32(box[info]) << 8 | UInt32(box[info + 1])
        let maximum = UInt32(box[info + 2]) << 8 | UInt32(box[info + 3])
        return minimum == maximum ? maximum : nil
    }

    static func flacBitDepthFlag(_ bits: Int) -> UInt32 {
        switch bits {
        case ...16: kAppleLosslessFormatFlag_16BitSourceData
        case 17...20: kAppleLosslessFormatFlag_20BitSourceData
        case 21...24: kAppleLosslessFormatFlag_24BitSourceData
        default: kAppleLosslessFormatFlag_32BitSourceData
        }
    }
}
