import AVFoundation
import CoreMedia
import Foundation

/// Plays Matroska/WebM without AVPlayer (which cannot open these containers): our demuxer feeds
/// compressed samples to AVSampleBufferDisplayLayer and AVSampleBufferAudioRenderer, which decode
/// them with VideoToolbox/AudioToolbox, and a render synchronizer keeps them in step.
@MainActor
public final class MatroskaPlayer {
    public let videoLayer = AVSampleBufferDisplayLayer()
    public let duration: Double
    public let hasVideo: Bool
    public let hasAudio: Bool
    /// Codec IDs of tracks macOS cannot decode (for example Vorbis, or AV1 on older Macs).
    public let unsupportedCodecs: [String]
    /// Display size of the video, aspect ratio applied.
    public let videoSize: CGSize?
    public private(set) var isPlaying = false
    public var onEnd: (() -> Void)?

    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let demuxer: MatroskaDemuxer
    private let feeder: SampleFeeder
    private var endObserver: Any?

    public init(url: URL) throws {
        demuxer = try MatroskaDemuxer(url: url)
        _ = VideoCodec.registerSupplementalDecoders

        var unsupported: [String] = []
        var video: SampleFeeder.VideoInput?
        if let track = demuxer.tracks.first(where: { $0.type == .video }) {
            if let codec = VideoCodec(matroskaID: track.codecID),
               codec != .av1 || VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
               let format = try? VideoFormat.description(for: track) {
                video = .init(track: track, format: format)
            } else {
                unsupported.append(track.codecID)
            }
        }
        var audio: SampleFeeder.AudioInput?
        let audioTracks = demuxer.tracks.filter { $0.type == .audio }
        for track in audioTracks {
            if let format = try? AudioFormat(track: track), let description = try? format.formatDescription() {
                audio = .init(track: track, format: format, description: description)
                break
            }
        }
        if audio == nil, let first = audioTracks.first {
            unsupported.append(first.codecID)
        }
        guard video != nil || audio != nil else {
            throw MediaError.unsupportedCodec(unsupported.first ?? "none")
        }

        hasVideo = video != nil
        hasAudio = audio != nil
        unsupportedCodecs = unsupported
        videoSize = video.flatMap { Self.displaySize($0.track) }
        duration = demuxer.durationSeconds ?? 0

        feeder = SampleFeeder(
            demuxer: demuxer,
            video: video,
            audio: audio,
            videoRenderer: video == nil ? nil : videoLayer.sampleBufferRenderer,
            audioRenderer: audio == nil ? nil : audioRenderer
        )
        videoLayer.videoGravity = .resizeAspect
        if hasVideo { synchronizer.addRenderer(videoLayer.sampleBufferRenderer) }
        if hasAudio { synchronizer.addRenderer(audioRenderer) }
        synchronizer.setRate(0, time: .zero)
        feeder.restart(from: nil)

        if duration > 0 {
            let end = CMTime(seconds: max(0, duration - 0.03), preferredTimescale: 1000)
            endObserver = synchronizer.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.reachedEnd() }
            }
        }
    }

    isolated deinit {
        if let endObserver { synchronizer.removeTimeObserver(endObserver) }
        feeder.stop()
    }

    public var currentTime: Double {
        let seconds = synchronizer.currentTime().seconds
        return seconds.isFinite ? min(max(0, seconds), max(duration, 0)) : 0
    }

    public var isMuted: Bool {
        get { audioRenderer.isMuted }
        set { audioRenderer.isMuted = newValue }
    }

    public var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = newValue }
    }

    public var error: Error? {
        videoLayer.sampleBufferRenderer.error ?? audioRenderer.error
    }

    public func play() {
        if duration > 0 && currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        synchronizer.setRate(1, time: synchronizer.currentTime())
        isPlaying = true
    }

    public func pause() {
        synchronizer.setRate(0, time: synchronizer.currentTime())
        isPlaying = false
    }

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    /// Jumps to the keyframe at or before `seconds`; Quick Look needs fast, not frame-exact, seeking.
    public func seek(to seconds: Double) {
        let point = demuxer.seekPoint(forSeconds: seconds)
        let time = CMTime(seconds: point.seconds, preferredTimescale: 90_000)
        synchronizer.setRate(0, time: time)
        feeder.restart(from: point.position)
        if isPlaying {
            synchronizer.setRate(1, time: time)
        }
    }

    /// The frame currently on screen, if any has been decoded and displayed.
    public func displayedFrame() -> CVPixelBuffer? {
        videoLayer.sampleBufferRenderer.displayedPixelBuffer()
    }

    private func reachedEnd() {
        guard isPlaying else { return }
        pause()
        onEnd?()
    }

    private static func displaySize(_ track: MatroskaTrack) -> CGSize? {
        guard let video = track.video, video.pixelWidth > 0, video.pixelHeight > 0 else { return nil }
        if let width = video.displayWidth, let height = video.displayHeight, width > 0, height > 0 {
            return CGSize(width: Double(video.pixelHeight) * Double(width) / Double(height), height: Double(video.pixelHeight))
        }
        return CGSize(width: video.pixelWidth, height: video.pixelHeight)
    }
}

/// Reads frames on its own queue and hands each renderer the samples it asks for. Frames come
/// interleaved, so samples for the renderer that is not asking are parked until it does.
final class SampleFeeder: @unchecked Sendable {
    struct VideoInput {
        let track: MatroskaTrack
        let format: CMVideoFormatDescription
    }

    struct AudioInput {
        let track: MatroskaTrack
        let format: AudioFormat
        let description: CMAudioFormatDescription
    }

    private let queue = DispatchQueue(label: "io.github.yinon-mitin.QuickPeek.feeder", qos: .userInitiated)
    private let demuxer: MatroskaDemuxer
    private let video: VideoInput?
    private let audio: AudioInput?
    private let videoRenderer: AVSampleBufferVideoRenderer?
    private let audioRenderer: AVSampleBufferAudioRenderer?

    // Touched only on `queue`.
    private var iterator: MatroskaFrameSequence.Iterator?
    private var parkedVideo: [CMSampleBuffer] = []
    private var parkedAudio: [CMSampleBuffer] = []
    private var waitingForKeyframe = true
    /// A runaway interleave (one track far ahead of the other) must not buffer the whole file.
    private static let maxParked = 1_500

    init(
        demuxer: MatroskaDemuxer,
        video: VideoInput?,
        audio: AudioInput?,
        videoRenderer: AVSampleBufferVideoRenderer?,
        audioRenderer: AVSampleBufferAudioRenderer?
    ) {
        self.demuxer = demuxer
        self.video = video
        self.audio = audio
        self.videoRenderer = videoRenderer
        self.audioRenderer = audioRenderer
    }

    /// Discards everything queued and starts reading at a cluster (or the first one).
    func restart(from position: Int64?) {
        queue.sync {
            stopRequesting()
            videoRenderer?.flush()
            audioRenderer?.flush()
            iterator = try? demuxer.frames(fromClusterAt: position).makeIterator()
            parkedVideo.removeAll()
            parkedAudio.removeAll()
            waitingForKeyframe = true
        }
        videoRenderer?.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedVideo() }
        audioRenderer?.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedAudio() }
    }

    func stop() {
        queue.sync { stopRequesting() }
    }

    private func stopRequesting() {
        videoRenderer?.stopRequestingMediaData()
        audioRenderer?.stopRequestingMediaData()
    }

    private func feedVideo() {
        guard let renderer = videoRenderer else { return }
        while renderer.isReadyForMoreMediaData {
            if parkedVideo.isEmpty && !readUntil({ !self.parkedVideo.isEmpty }) {
                if iterator == nil { renderer.stopRequestingMediaData() }
                return
            }
            renderer.enqueue(parkedVideo.removeFirst())
        }
    }

    private func feedAudio() {
        guard let renderer = audioRenderer else { return }
        while renderer.isReadyForMoreMediaData {
            if parkedAudio.isEmpty && !readUntil({ !self.parkedAudio.isEmpty }) {
                if iterator == nil { renderer.stopRequestingMediaData() }
                return
            }
            renderer.enqueue(parkedAudio.removeFirst())
        }
    }

    /// Reads frames into the parked queues until `satisfied`. Returns false at the end of the file
    /// (iterator becomes nil) or when the other track's queue is full.
    private func readUntil(_ satisfied: () -> Bool) -> Bool {
        while !satisfied() {
            guard parkedVideo.count < Self.maxParked, parkedAudio.count < Self.maxParked else { return false }
            guard let frame = iterator?.next() else {
                iterator = nil
                return false
            }
            let time = demuxer.time(fromTicks: frame.timestamp)
            if let video, frame.trackNumber == video.track.number {
                if waitingForKeyframe && !frame.isKeyframe { continue }
                waitingForKeyframe = false
                if let sample = try? VideoFormat.sampleBuffer(frame.data, format: video.format, presentationTime: time, isKeyframe: frame.isKeyframe) {
                    parkedVideo.append(sample)
                }
            } else if let audio, frame.trackNumber == audio.track.number {
                if let sample = try? audio.format.sampleBuffer(frame.data, format: audio.description, presentationTime: time) {
                    parkedAudio.append(sample)
                }
            }
        }
        return true
    }
}
