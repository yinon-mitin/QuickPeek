import Foundation
import Testing
@testable import QuickPeekInfo

let mediaFixtures = repositoryRoot.appendingPathComponent("Tests/QuickPeekMediaTests/Fixtures")

func mediaInfo(_ name: String) -> FileInfo {
    FileInfoReader.read(mediaFixtures.appendingPathComponent(name), locale: Locale(identifier: "en_US"))
}

@Suite("FileInfo: video and audio")
struct MediaInfoTests {
    @Test("MP4 with H.264, AAC and tags (AVFoundation)")
    func mp4() {
        let info = mediaInfo("h264_aac.mp4")
        #expect(info.value("Container", in: "Media") == "MPEG-4")
        #expect(info.value("Duration", in: "Media") == "0:01")
        #expect(info.value("Title", in: "Media") == "QuickPeek Sample")
        #expect(info.value("Artist", in: "Media") == "QuickPeek Tests")
        #expect(info.value("Codec", in: "Video") == "H.264")
        #expect(info.value("Profile", in: "Video") == "High@L1")
        #expect(info.value("Resolution", in: "Video") == "160 × 120")
        #expect(info.value("Frame rate", in: "Video") == "10 fps")
        #expect(info.value("Bit depth", in: "Video") == "8 bits")
        #expect(info.value("Codec", in: "Audio") == "AAC LC")
        #expect(info.value("Sample rate", in: "Audio") == "48 kHz")
        #expect(info.value("Channels", in: "Audio") == "2 (stereo)")
        #expect(info.summary == "160×120 · H.264 · 10 fps · 0:01")
    }

    @Test("HDR10 HEVC is recognised in MP4 and Matroska", arguments: ["hdr10.mp4", "hdr10.mkv"])
    func hdr(file: String) {
        let info = mediaInfo(file)
        #expect(info.value("Codec", in: "Video") == "HEVC")
        #expect(info.value("Profile", in: "Video") == "Main 10@L1, Main tier")
        #expect(info.value("HDR", in: "Video") == "HDR10 (PQ)")
        #expect(info.value("Colour primaries", in: "Video") == "BT.2020")
        #expect(info.value("Bit depth", in: "Video") == "10 bits")
        #expect(info.summary.contains("HDR10"))
    }

    @Test("Matroska and WebM through QuickPeek's demuxer")
    func matroska() {
        let mkv = mediaInfo("h264_aac.mkv")
        #expect(mkv.value("Container", in: "Media") == "Matroska")
        #expect(mkv.value("Codec", in: "Video") == "H.264")
        #expect(mkv.value("Profile", in: "Video") == "High@L1")
        #expect(mkv.value("Frame rate", in: "Video") == "10 fps")
        #expect(mkv.value("Codec", in: "Audio") == "AAC LC")
        #expect(mkv.value("Channels", in: "Audio") == "1 (mono)")
        #expect(mkv.value("Muxing application", in: "Media")?.hasPrefix("Lavf") == true)

        let webm = mediaInfo("vp9_opus.webm")
        #expect(webm.value("Container", in: "Media") == "WebM")
        #expect(webm.value("Codec", in: "Video") == "VP9")
        #expect(webm.value("Profile", in: "Video") == "Profile 0")
        #expect(webm.value("Codec", in: "Audio") == "Opus")
    }

    @Test("Lossless and MP3 audio")
    func audio() {
        let alac = mediaInfo("lossless.m4a")
        #expect(alac.value("Codec", in: "Audio") == "ALAC")
        #expect(alac.value("Bit depth", in: "Audio") == "16 bits")
        #expect(alac.value("Channels", in: "Audio") == "1 (mono)")
        #expect(alac.summary == "ALAC · 48 kHz · mono · 0:01")

        let mp3 = mediaInfo("song.mp3")
        #expect(mp3.value("Codec", in: "Audio") == "MP3")
        #expect(mp3.value("Bitrate", in: "Audio") == "128 kb/s")
        #expect(mp3.value("Channels", in: "Audio") == "2 (stereo)")
    }

    @Test("Codec configuration records decode to profile and level names")
    func profiles() {
        // avcC: version, profile 100 (High), constraints, level 41
        #expect(CodecDetails.h264Profile(avcC: Data([1, 100, 0, 41])) == "High@L4.1")
        #expect(CodecDetails.h264Profile(avcC: Data([1, 66, 0x40, 30])) == "Constrained Baseline@L3")
        // hvcC: profile 2 (Main 10), high tier, level idc 153 (5.1)
        var hvcC = Data(repeating: 0, count: 23)
        hvcC[1] = 0x20 | 2
        hvcC[12] = 153
        #expect(CodecDetails.hevcProfile(hvcC: hvcC) == "Main 10@L5.1, High tier")
        #expect(CodecDetails.aacProfile(audioSpecificConfig: Data([0x29, 0x88])) == "HE-AAC")
        #expect(CodecDetails.channelDescription(6) == "6 (5.1)")
    }
}
