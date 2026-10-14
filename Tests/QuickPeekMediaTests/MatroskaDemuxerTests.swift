import Foundation
import Testing
@testable import QuickPeekMedia

/// Expected values come from ffprobe on the files produced by script/make_fixtures.sh.
struct FixtureExpectation: Sendable, CustomTestStringConvertible {
    let file: String
    let docType: String
    let videoCodec: String
    let audioCodec: String
    let videoPrivateSize: Int?
    let audioPrivatePrefix: [UInt8]?
    let audioFrames: Int
    let videoKeyframes: Int

    var testDescription: String { file }
}

let fixtures: [FixtureExpectation] = [
    .init(file: "h264_aac.mkv", docType: "matroska", videoCodec: "V_MPEG4/ISO/AVC", audioCodec: "A_AAC",
          videoPrivateSize: 44, audioPrivatePrefix: nil, audioFrames: 48, videoKeyframes: 2),
    .init(file: "hevc_ac3.mkv", docType: "matroska", videoCodec: "V_MPEGH/ISO/HEVC", audioCodec: "A_AC3",
          videoPrivateSize: 2431, audioPrivatePrefix: nil, audioFrames: 32, videoKeyframes: 1),
    .init(file: "vp9_opus.webm", docType: "webm", videoCodec: "V_VP9", audioCodec: "A_OPUS",
          videoPrivateSize: nil, audioPrivatePrefix: Array("OpusHead".utf8), audioFrames: 51, videoKeyframes: 1),
    .init(file: "av1_flac.mkv", docType: "matroska", videoCodec: "V_AV1", audioCodec: "A_FLAC",
          videoPrivateSize: 17, audioPrivatePrefix: Array("fLaC".utf8), audioFrames: 47, videoKeyframes: 1),
]

func fixtureURL(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

@Suite("MatroskaDemuxer")
struct MatroskaDemuxerTests {
    @Test("Header, info and tracks", arguments: fixtures)
    func tracks(expected: FixtureExpectation) throws {
        let demuxer = try MatroskaDemuxer(url: fixtureURL(expected.file))
        #expect(demuxer.docType == expected.docType)

        let duration = try #require(demuxer.durationSeconds)
        #expect(duration > 0.95 && duration < 1.1)

        let video = try #require(demuxer.tracks.first { $0.type == .video })
        #expect(video.codecID == expected.videoCodec)
        #expect(video.video?.pixelWidth == 160)
        #expect(video.video?.pixelHeight == 120)
        #expect(video.codecPrivate?.count == expected.videoPrivateSize)

        let audio = try #require(demuxer.tracks.first { $0.type == .audio })
        #expect(audio.codecID == expected.audioCodec)
        #expect(audio.audio?.samplingFrequency == 48_000)
        #expect(audio.audio?.channels == 1)
        if let prefix = expected.audioPrivatePrefix {
            let codecPrivate = try #require(audio.codecPrivate)
            #expect(Array(codecPrivate.prefix(prefix.count)) == prefix)
        }
    }

    @Test("Every frame is read with the right track, keyframe flag and order", arguments: fixtures)
    func frames(expected: FixtureExpectation) throws {
        let demuxer = try MatroskaDemuxer(url: fixtureURL(expected.file))
        let video = try #require(demuxer.tracks.first { $0.type == .video })
        let audio = try #require(demuxer.tracks.first { $0.type == .audio })

        let frames = try Array(demuxer.frames())
        let videoFrames = frames.filter { $0.trackNumber == video.number }
        let audioFrames = frames.filter { $0.trackNumber == audio.number }

        #expect(videoFrames.count == 10)
        #expect(audioFrames.count == expected.audioFrames)
        #expect(videoFrames.first?.isKeyframe == true)
        #expect(videoFrames.filter(\.isKeyframe).count == expected.videoKeyframes)
        #expect(videoFrames.allSatisfy { !$0.data.isEmpty })

        // Presentation timestamps of a 10 fps clip: 0, 100, ..., 900 ms in any decode order.
        let milliseconds = videoFrames.map { Int(demuxer.seconds(fromTicks: $0.timestamp) * 1000 + 0.5) }.sorted()
        #expect(milliseconds == Array(stride(from: 0, through: 900, by: 100)))
    }

    @Test("Cues give a seek position for any time", arguments: fixtures)
    func cues(expected: FixtureExpectation) throws {
        let demuxer = try MatroskaDemuxer(url: fixtureURL(expected.file))
        #expect(!demuxer.cues.isEmpty)
        #expect(demuxer.cues.first?.time == 0)

        let start = try #require(demuxer.clusterPosition(forSeconds: 0))
        let later = try #require(demuxer.clusterPosition(forSeconds: 0.9))
        #expect(later >= start)

        let fromStart = try Array(demuxer.frames(fromClusterAt: start))
        #expect(fromStart.count == 10 + expected.audioFrames)
    }

    @Test("A file that is not Matroska is rejected")
    func notMatroska() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qp-not-mkv-\(UUID().uuidString).mkv")
        try Data("definitely not a matroska file".utf8).write(to: url)
        #expect(throws: MatroskaError.self) { try MatroskaDemuxer(url: url) }
    }

    @Test("A truncated file still yields the frames before the cut")
    func truncatedFile() throws {
        let data = try Data(contentsOf: fixtureURL("h264_aac.mkv"))
        let demuxer = try MatroskaDemuxer(source: DataByteSource(data.prefix(data.count * 2 / 3)))
        let frames = try Array(demuxer.frames())
        #expect(!frames.isEmpty)
        #expect(frames.count < 58)
    }
}
