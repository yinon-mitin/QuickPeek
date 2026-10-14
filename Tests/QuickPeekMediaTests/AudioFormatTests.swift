import AudioToolbox
import CoreMedia
import Foundation
import Testing
@testable import QuickPeekMedia

@Suite("AudioFormat")
struct AudioFormatTests {
    static let decodable = ["h264_aac.mkv", "hevc_ac3.mkv", "vp9_opus.webm", "av1_flac.mkv"]

    /// Decodes the first packets of the file's audio track to 32-bit float PCM with AudioConverter —
    /// the same decoders AVSampleBufferAudioRenderer uses — and returns the peak amplitude.
    private func peakAmplitude(of file: String, packets: Int = 20) throws -> Float {
        let demuxer = try MatroskaDemuxer(url: fixtureURL(file))
        let track = try #require(demuxer.tracks.first { $0.type == .audio })
        let format = try AudioFormat(track: track)

        var input = format.streamDescription
        var output = AudioStreamBasicDescription(
            mSampleRate: input.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * input.mChannelsPerFrame, mFramesPerPacket: 1,
            mBytesPerFrame: 4 * input.mChannelsPerFrame, mChannelsPerFrame: input.mChannelsPerFrame,
            mBitsPerChannel: 32, mReserved: 0
        )
        var converter: AudioConverterRef?
        #expect(AudioConverterNew(&input, &output, &converter) == noErr)
        let audioConverter = try #require(converter)
        defer { AudioConverterDispose(audioConverter) }
        if let cookie = format.magicCookie {
            let status = cookie.withUnsafeBytes {
                AudioConverterSetProperty(audioConverter, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)
            }
            #expect(status == noErr)
        }

        let frames = try Array(demuxer.frames().filter { $0.trackNumber == track.number }.prefix(packets))
        let feeder = PacketFeeder(packets: frames.map(\.data), format: format)
        var peak: Float = 0
        var pcm = [Float](repeating: 0, count: 8192 * Int(output.mChannelsPerFrame))
        while true {
            var frameCount = UInt32(8192)
            let status = pcm.withUnsafeMutableBytes { buffer -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: output.mChannelsPerFrame, mDataByteSize: UInt32(buffer.count), mData: buffer.baseAddress)
                )
                return AudioConverterFillComplexBuffer(audioConverter, PacketFeeder.callback, Unmanaged.passUnretained(feeder).toOpaque(), &frameCount, &list, nil)
            }
            for sample in pcm.prefix(Int(frameCount * output.mChannelsPerFrame)) { peak = max(peak, abs(sample)) }
            if frameCount == 0 || (status != noErr && status != PacketFeeder.endOfInput) { break }
        }
        return peak
    }

    @Test("Native decoders turn the first packets into audible PCM", arguments: decodable)
    func decodes(file: String) throws {
        #expect(try peakAmplitude(of: file) > 0.05)
    }

    @Test("Packet durations follow the codec's frame size", arguments: [
        ("h264_aac.mkv", 1024), ("hevc_ac3.mkv", 1536),
    ])
    func framesPerPacket(file: String, frames: Int) throws {
        let demuxer = try MatroskaDemuxer(url: fixtureURL(file))
        let track = try #require(demuxer.tracks.first { $0.type == .audio })
        #expect(try AudioFormat(track: track).streamDescription.mFramesPerPacket == UInt32(frames))
    }

    @Test("Opus packets report their own sample count from the TOC byte", arguments: [
        (UInt8(0xF8), 960),       // config 31 (CELT 20 ms), one frame
        (UInt8(0xF9), 1920),      // two equal frames
        (UInt8(0x78), 960),       // config 15 (hybrid 20 ms)
        (UInt8(0x08), 960),       // config 1 (SILK 20 ms)
        (UInt8(0x00), 480),       // config 0 (SILK 10 ms)
        (UInt8(0xFB), 2880),      // code 3: frame count in the next byte (3 × 20 ms)
        (UInt8(0xE0), 120),       // config 28 (CELT 2.5 ms)
    ])
    func opusSamples(toc: UInt8, samples: Int) {
        #expect(AudioFormat.opusSamplesPerPacket(Data([toc, 0x03, 0x00])) == samples)
    }

    @Test("Vorbis has no native decoder and is reported as unsupported")
    func vorbis() {
        let track = MatroskaTrack(number: 2, type: .audio, codecID: "A_VORBIS",
                                  audio: .init(samplingFrequency: 48_000, channels: 2))
        #expect(throws: MediaError.unsupportedCodec("A_VORBIS")) { try AudioFormat(track: track) }
    }
}

/// Hands compressed packets to AudioConverter one at a time.
private final class PacketFeeder {
    static let endOfInput: OSStatus = 0x656E_6421 // 'end!'
    private var packets: [Data]
    private let format: AudioFormat
    private var current = Data()
    private var description = AudioStreamPacketDescription()

    init(packets: [Data], format: AudioFormat) {
        self.packets = packets
        self.format = format
    }

    static let callback: AudioConverterComplexInputDataProc = { _, packetCount, data, descriptions, context in
        let feeder = Unmanaged<PacketFeeder>.fromOpaque(context!).takeUnretainedValue()
        guard !feeder.packets.isEmpty else {
            packetCount.pointee = 0
            return endOfInput
        }
        feeder.current = feeder.packets.removeFirst()
        feeder.description = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: UInt32(feeder.format.framesInPacket(feeder.current)),
            mDataByteSize: UInt32(feeder.current.count)
        )
        feeder.current.withUnsafeMutableBytes { bytes in
            data.pointee.mNumberBuffers = 1
            data.pointee.mBuffers.mData = bytes.baseAddress
            data.pointee.mBuffers.mDataByteSize = UInt32(bytes.count)
        }
        packetCount.pointee = 1
        if let descriptions {
            withUnsafeMutablePointer(to: &feeder.description) { descriptions.pointee = $0 }
        }
        return noErr
    }
}
