import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Plays the containers AVPlayer cannot open (Matroska/WebM, MPEG-TS, AVI, FLV): our demuxers
/// feed compressed samples to AVSampleBufferDisplayLayer and AVSampleBufferAudioRenderer, which
/// decode them with VideoToolbox/AudioToolbox, and a render synchronizer keeps them in step.
@MainActor
public final class MediaPlayer {
    public let videoLayer = AVSampleBufferDisplayLayer()
    public let duration: Double
    public let hasVideo: Bool
    public let hasAudio: Bool
    /// Names of codecs macOS cannot decode (for example Vorbis, or AV1 on older Macs).
    public let unsupportedCodecs: [String]
    /// Display size of the video, aspect ratio applied.
    public let videoSize: CGSize?
    public private(set) var isPlaying = false
    public var onEnd: (() -> Void)?

    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let container: MediaContainer
    private let feeder: SampleFeeder
    private var endObserver: Any?

    public init(url: URL) throws {
        container = try MediaContainers.open(url)

        var unsupported: [String] = []
        var video: SampleFeeder.VideoInput?
        if let stream = container.streams.first(where: { $0.kind == .video }) {
            if let format = try? VideoFormat.description(for: stream) {
                video = .init(stream: stream, format: format)
            } else {
                unsupported.append(stream.codecName)
            }
        }
        var audio: SampleFeeder.AudioInput?
        let audioStreams = container.streams.filter { $0.kind == .audio }
        for stream in audioStreams {
            if let format = try? AudioFormat(stream: stream), let description = try? format.formatDescription() {
                audio = .init(stream: stream, format: format, description: description)
                break
            }
        }
        if audio == nil, let first = audioStreams.first {
            unsupported.append(first.codecName)
        }
        guard video != nil || audio != nil else {
            throw MediaError.unsupportedCodec(unsupported.first ?? "none")
        }

        hasVideo = video != nil
        hasAudio = audio != nil
        unsupportedCodecs = unsupported
        videoSize = video.flatMap { VideoFormat.displaySize(of: $0.format) ?? $0.stream.displaySize }
        duration = container.durationSeconds ?? 0

        feeder = SampleFeeder(
            container: container,
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
        let point = container.seekPoint(forSeconds: seconds)
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
}

/// Reads frames on its own queue and hands each renderer the samples it asks for. Frames come
/// interleaved, so samples for the renderer that is not asking are parked until it does.
final class SampleFeeder: @unchecked Sendable {
    struct VideoInput {
        let stream: MediaStream
        let format: CMVideoFormatDescription
    }

    struct AudioInput {
        let stream: MediaStream
        let format: AudioFormat
        let description: CMAudioFormatDescription
    }

    private let queue = DispatchQueue(label: "io.github.yinon-mitin.QuickPeek.feeder", qos: .userInitiated)
    private let container: MediaContainer
    private let video: VideoInput?
    private let audio: AudioInput?
    private let videoRenderer: AVSampleBufferVideoRenderer?
    private let audioRenderer: AVSampleBufferAudioRenderer?

    // Touched only on `queue`.
    private var iterator: AnyIterator<MediaPacket>?
    private var parkedVideo: [CMSampleBuffer] = []
    private var parkedAudio: [CMSampleBuffer] = []
    private var waitingForKeyframe = true
    /// A runaway interleave (one track far ahead of the other) must not buffer the whole file.
    private static let maxParked = 1_500

    init(
        container: MediaContainer,
        video: VideoInput?,
        audio: AudioInput?,
        videoRenderer: AVSampleBufferVideoRenderer?,
        audioRenderer: AVSampleBufferAudioRenderer?
    ) {
        self.container = container
        self.video = video
        self.audio = audio
        self.videoRenderer = videoRenderer
        self.audioRenderer = audioRenderer
    }

    /// Discards everything queued and starts reading at a seek position (or the start).
    func restart(from position: Int64?) {
        queue.sync {
            stopRequesting()
            videoRenderer?.flush()
            audioRenderer?.flush()
            iterator = try? container.packets(from: position)
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

    /// Reads packets into the parked queues until `satisfied`. Returns false at the end of the file
    /// (iterator becomes nil) or when the other track's queue is full.
    private func readUntil(_ satisfied: () -> Bool) -> Bool {
        while !satisfied() {
            guard parkedVideo.count < Self.maxParked, parkedAudio.count < Self.maxParked else { return false }
            guard let packet = iterator?.next() else {
                iterator = nil
                return false
            }
            if let video, packet.streamID == video.stream.id {
                if waitingForKeyframe && !packet.isKeyframe { continue }
                waitingForKeyframe = false
                if let sample = try? VideoFormat.sampleBuffer(
                    packet.data, format: video.format, presentationTime: packet.presentationTime,
                    decodeTime: packet.decodeTime, isKeyframe: packet.isKeyframe
                ) {
                    parkedVideo.append(sample)
                }
            } else if let audio, packet.streamID == audio.stream.id {
                if let sample = try? audio.format.sampleBuffer(packet.data, format: audio.description, presentationTime: packet.presentationTime) {
                    parkedAudio.append(sample)
                }
            }
        }
        return true
    }
}
