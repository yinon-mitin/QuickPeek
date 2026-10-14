import AVFoundation
import CoreMedia
import Foundation
import QuickPeekMedia
import UniformTypeIdentifiers

// MARK: - Matroska / WebM

enum MatroskaInfo: InfoReader {
    static let extensions: Set<String> = ["mkv", "mka", "mk3d", "webm"]

    static func canRead(_ type: UTType, url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func read(_ url: URL, format: InfoFormat) throws -> (sections: [InfoSection], summary: String?) {
        let demuxer = try MatroskaDemuxer(url: url)
        let duration = demuxer.durationSeconds
        var media = [InfoItem("Container", demuxer.docType == "webm" ? "WebM" : "Matroska")]
        if let duration { media.append(InfoItem("Duration", format.duration(duration))) }
        if let duration, duration > 0, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            media.append(InfoItem("Overall bitrate", format.bitrate(Double(size) * 8 / duration)))
        }
        if let title = demuxer.title ?? demuxer.tags["TITLE"], !title.isEmpty { media.append(InfoItem("Title", title)) }
        if let date = demuxer.dateUTC { media.append(InfoItem("Encoded", format.date(date))) }
        if let app = demuxer.muxingApp { media.append(InfoItem("Muxing application", app)) }
        if let app = demuxer.writingApp { media.append(InfoItem("Writing application", app)) }
        if demuxer.chapterCount > 0 { media.append(InfoItem("Chapters", format.number(demuxer.chapterCount))) }
        for attachment in demuxer.attachments {
            media.append(InfoItem("Attachment", "\(attachment.name) (\(attachment.mediaType), \(format.bytes(Int64(attachment.size))))"))
        }
        var sections = [InfoSection("Media", symbol: "film", items: media)]

        var counts: [MatroskaTrack.Kind: Int] = [:]
        var summary: String?
        for track in demuxer.tracks {
            counts[track.type, default: 0] += 1
            let number = counts[track.type] ?? 1
            switch track.type {
            case .video:
                let (items, line) = videoItems(track, demuxer: demuxer, format: format)
                sections.append(InfoSection(number == 1 ? "Video" : "Video \(number)", symbol: "video", items: items))
                if summary == nil { summary = ([line] + [duration.map(format.duration)].compactMap { $0 }).joined(separator: " · ") }
            case .audio:
                let items = audioItems(track, format: format)
                sections.append(InfoSection(number == 1 ? "Audio" : "Audio \(number)", symbol: "waveform", items: items))
                if summary == nil, let audio = track.audio {
                    summary = [CodecDetails.audioCodecName(matroskaID: track.codecID, codecPrivate: track.codecPrivate),
                               CodecDetails.sampleRate(audio.samplingFrequency, format: format),
                               CodecDetails.shortChannels(audio.channels), duration.map(format.duration)]
                        .compactMap { $0 }.joined(separator: " · ")
                }
            case .subtitle:
                sections.append(InfoSection(number == 1 ? "Subtitles" : "Subtitles \(number)", symbol: "captions.bubble",
                                            items: subtitleItems(track)))
            case .other:
                break
            }
        }
        return (sections, summary)
    }

    private static func videoItems(_ track: MatroskaTrack, demuxer: MatroskaDemuxer, format: InfoFormat) -> ([InfoItem], String) {
        let codec = CodecDetails.videoCodecName(matroskaID: track.codecID, codecPrivate: track.codecPrivate)
        var items = [InfoItem("Codec", codec), InfoItem("Codec ID", track.codecID)]
        var profile: String?
        var bitDepth = track.video?.colour?.bitsPerChannel
        switch track.codecID {
        case "V_MPEG4/ISO/AVC":
            profile = track.codecPrivate.flatMap(CodecDetails.h264Profile(avcC:))
            bitDepth = bitDepth ?? track.codecPrivate.flatMap(CodecDetails.h264BitDepth(avcC:))
        case "V_MPEGH/ISO/HEVC":
            profile = track.codecPrivate.flatMap(CodecDetails.hevcProfile(hvcC:))
            bitDepth = bitDepth ?? track.codecPrivate.flatMap(CodecDetails.hevcBitDepth(hvcC:))
        case "V_VP9":
            // VP9 carries its profile in each frame header; read the first frame of the track.
            if let frame = (try? demuxer.frames())?.lazy.first(where: { $0.trackNumber == track.number }) {
                profile = CodecDetails.vp9Profile(frame: frame.data)
                if profile == "Profile 0" || profile == "Profile 1" { bitDepth = bitDepth ?? 8 }
            }
        default:
            break
        }
        if let profile { items.append(InfoItem("Profile", profile)) }

        var line = codec
        if let video = track.video {
            items.append(InfoItem("Resolution", "\(video.pixelWidth) × \(video.pixelHeight)"))
            if let width = video.displayWidth, let height = video.displayHeight, width > 0, height > 0,
               width * video.pixelHeight != height * video.pixelWidth {
                items.append(InfoItem("Display aspect ratio", format.decimal(Double(width) / Double(height), digits: 3) + ":1"))
            }
            line = "\(video.pixelWidth)×\(video.pixelHeight) · \(codec)"
        }
        if let fps = frameRate(track) {
            let text = CodecDetails.frameRate(fps, format: format)
            items.append(InfoItem("Frame rate", text))
            line += " · \(text)"
        }
        if let bitDepth { items.append(InfoItem("Bit depth", "\(bitDepth) bits")) }
        if let bps = track.tags["BPS"].flatMap(Double.init) { items.append(InfoItem("Bitrate", format.bitrate(bps))) }
        if let interlaced = track.video?.isInterlaced { items.append(InfoItem("Scan type", interlaced ? "Interlaced" : "Progressive")) }

        let colour = track.video?.colour
        if let hdr = CodecDetails.hdrName(transfer: colour?.transferCharacteristics, dolbyVision: false) {
            items.append(InfoItem("HDR", hdr))
            line += " · \(hdr.components(separatedBy: " ").first ?? hdr)"
        }
        if let name = colour?.primaries.flatMap(CodecDetails.primariesName) { items.append(InfoItem("Colour primaries", name)) }
        if let name = colour?.transferCharacteristics.flatMap(CodecDetails.transferName) { items.append(InfoItem("Transfer", name)) }
        if let name = colour?.matrixCoefficients.flatMap(CodecDetails.matrixName) { items.append(InfoItem("Matrix", name)) }
        if let range = colour?.range, range == 1 || range == 2 { items.append(InfoItem("Range", range == 2 ? "Full" : "Limited")) }
        if let cll = colour?.maxContentLightLevel { items.append(InfoItem("MaxCLL", "\(cll) nits")) }
        if let fall = colour?.maxFrameAverageLightLevel { items.append(InfoItem("MaxFALL", "\(fall) nits")) }
        items += commonTrackItems(track)
        return (items, line)
    }

    private static func audioItems(_ track: MatroskaTrack, format: InfoFormat) -> [InfoItem] {
        var items = [InfoItem("Codec", CodecDetails.audioCodecName(matroskaID: track.codecID, codecPrivate: track.codecPrivate)),
                     InfoItem("Codec ID", track.codecID)]
        if let audio = track.audio {
            items.append(InfoItem("Sample rate", CodecDetails.sampleRate(audio.samplingFrequency, format: format)))
            items.append(InfoItem("Channels", CodecDetails.channelDescription(audio.channels)))
            if let bits = audio.bitDepth { items.append(InfoItem("Bit depth", "\(bits) bits")) }
        }
        if let bps = track.tags["BPS"].flatMap(Double.init) { items.append(InfoItem("Bitrate", format.bitrate(bps))) }
        return items + commonTrackItems(track)
    }

    private static func subtitleItems(_ track: MatroskaTrack) -> [InfoItem] {
        let names = ["S_TEXT/UTF8": "SubRip (SRT)", "S_TEXT/ASS": "ASS", "S_TEXT/SSA": "SSA", "S_TEXT/WEBVTT": "WebVTT",
                     "S_HDMV/PGS": "PGS (Blu-ray)", "S_VOBSUB": "VobSub (DVD)", "S_DVBSUB": "DVB"]
        return [InfoItem("Format", names[track.codecID] ?? track.codecID)] + commonTrackItems(track)
    }

    private static func commonTrackItems(_ track: MatroskaTrack) -> [InfoItem] {
        var items: [InfoItem] = []
        // Matroska's default language, when a track has no Language element, is English.
        let language = track.language ?? "eng"
        if language != "und" {
            items.append(InfoItem("Language", Locale.current.localizedString(forLanguageCode: language) ?? language))
        }
        if let name = track.name, !name.isEmpty { items.append(InfoItem("Title", name)) }
        items.append(InfoItem("Default", track.isDefault ? "Yes" : "No"))
        if track.isForced { items.append(InfoItem("Forced", "Yes")) }
        return items
    }

    /// From the per-frame duration, or mkvmerge's frame-count statistics.
    private static func frameRate(_ track: MatroskaTrack) -> Double? {
        if let duration = track.defaultDuration, duration > 0 {
            return (1_000_000_000 / Double(duration) * 1000).rounded() / 1000
        }
        if let frames = track.tags["NUMBER_OF_FRAMES"].flatMap(Double.init), let length = track.tags["DURATION"].flatMap(parseDuration), length > 0 {
            return (frames / length * 1000).rounded() / 1000
        }
        return nil
    }

    /// "00:01:23.456000000" → seconds.
    private static func parseDuration(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

// MARK: - AVFoundation (MP4, MOV, M4A, MP3, WAV, AIFF, …)

enum AVMediaInfo: InfoReader {
    static func canRead(_ type: UTType, url: URL) -> Bool {
        type.conforms(to: .audiovisualContent) && !MatroskaInfo.canRead(type, url: url)
    }

    /// Not used: FileInfoReader calls `describe` itself, so it can await it in async contexts.
    static func read(_ url: URL, format: InfoFormat) throws -> (sections: [InfoSection], summary: String?) {
        throw CocoaError(.featureUnsupported)
    }

    /// Loads the asset with AVFoundation's async API. FileInfoReader awaits this from async
    /// contexts, or wraps it in `runBlocking` for synchronous callers.
    static func describe(url: URL, format: InfoFormat) async throws -> (sections: [InfoSection], summary: String?) {
        let type = UTType(filenameExtension: url.pathExtension)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init)
        let asset = AVURLAsset(url: url)
        let (duration, tracks, metadata) = try await asset.load(.duration, .tracks, .commonMetadata)
        let seconds = duration.seconds.isFinite ? duration.seconds : nil

        var media = [InfoItem("Container", containerName(type))]
        if let seconds { media.append(InfoItem("Duration", format.duration(seconds))) }
        if let seconds, seconds > 0, let fileSize { media.append(InfoItem("Overall bitrate", format.bitrate(fileSize * 8 / seconds))) }
        let tags: [(AVMetadataKey, String)] = [
            (.commonKeyTitle, "Title"), (.commonKeyArtist, "Artist"), (.commonKeyAlbumName, "Album"),
            (.commonKeyCreator, "Creator"), (.commonKeyCreationDate, "Recorded"), (.commonKeySoftware, "Encoder"),
            (.commonKeyMake, "Camera make"), (.commonKeyModel, "Camera model"), (.commonKeyLocation, "Location"),
            (.commonKeyCopyrights, "Copyright"),
        ]
        for (key, label) in tags {
            if let item = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common).first,
               let value = try await item.load(.stringValue), !value.isEmpty {
                media.append(InfoItem(label, value))
            }
        }
        var sections = [InfoSection("Media", symbol: "film", items: media)]

        var videoLine: String?
        var audioLine: String?
        var videoCount = 0, audioCount = 0, textCount = 0
        for track in tracks {
            let mediaType = track.mediaType
            let (descriptions, rate, language) = try await track.load(.formatDescriptions, .estimatedDataRate, .languageCode)
            guard let description = descriptions.first else { continue }
            var items: [InfoItem] = []
            switch mediaType {
            case .video:
                videoCount += 1
                let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                let (videoItems, line) = videoDetails(description, size: size, transform: transform, fps: Double(fps), format: format)
                items = videoItems
                if rate > 0 { items.append(InfoItem("Bitrate", format.bitrate(Double(rate)))) }
                if videoLine == nil { videoLine = line }
            case .audio:
                audioCount += 1
                let (audioItems, line) = audioDetails(description, format: format)
                items = audioItems
                if rate > 0 { items.append(InfoItem("Bitrate", format.bitrate(Double(rate)))) }
                if audioLine == nil { audioLine = line }
            case .text, .subtitle, .closedCaption:
                textCount += 1
                items = [InfoItem("Format", CodecDetails.fourCC(CMFormatDescriptionGetMediaSubType(description)))]
            default:
                continue
            }
            if let language, language != "und" {
                items.append(InfoItem("Language", Locale.current.localizedString(forLanguageCode: language) ?? language))
            }
            let (title, symbol, count) = switch mediaType {
            case .video: ("Video", "video", videoCount)
            case .audio: ("Audio", "waveform", audioCount)
            default: ("Subtitles", "captions.bubble", textCount)
            }
            sections.append(InfoSection(count == 1 ? title : "\(title) \(count)", symbol: symbol, items: items))
        }

        let line = (videoLine ?? audioLine).map { [$0, seconds.map(format.duration)].compactMap { $0 }.joined(separator: " · ") }
        return (sections, line)
    }

    private static func videoDetails(_ description: CMFormatDescription, size: CGSize, transform: CGAffineTransform,
                                     fps: Double, format: InfoFormat) -> ([InfoItem], String) {
        let code = CodecDetails.fourCC(CMFormatDescriptionGetMediaSubType(description))
        let codec = CodecDetails.videoCodecName(fourCC: code)
        var items = [InfoItem("Codec", codec), InfoItem("Codec ID", code)]
        let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] ?? [:]

        var bitDepth = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
        if let avcC = atoms["avcC"] as? Data {
            if let profile = CodecDetails.h264Profile(avcC: avcC) { items.append(InfoItem("Profile", profile)) }
            bitDepth = bitDepth ?? CodecDetails.h264BitDepth(avcC: avcC)
        } else if let hvcC = atoms["hvcC"] as? Data {
            if let profile = CodecDetails.hevcProfile(hvcC: hvcC) { items.append(InfoItem("Profile", profile)) }
            bitDepth = bitDepth ?? CodecDetails.hevcBitDepth(hvcC: hvcC)
        }

        // Display size: the track transform rotates portrait recordings.
        let rotated = abs(transform.b) == 1 && abs(transform.c) == 1
        let width = Int(rotated ? size.height : size.width), height = Int(rotated ? size.width : size.height)
        items.append(InfoItem("Resolution", "\(width) × \(height)"))
        if rotated { items.append(InfoItem("Rotation", "90°")) }
        var line = "\(width)×\(height) · \(codec)"
        if fps > 0 {
            let text = CodecDetails.frameRate(fps, format: format)
            items.append(InfoItem("Frame rate", text))
            line += " · \(text)"
        }
        if let bitDepth { items.append(InfoItem("Bit depth", "\(bitDepth) bits")) }

        let extensionString = { (key: CFString) in CMFormatDescriptionGetExtension(description, extensionKey: key) as? String }
        let transfer = extensionString(kCMFormatDescriptionExtension_TransferFunction).flatMap(CodecDetails.coreMediaTransfer)
        let dolbyVision = atoms["dvcC"] != nil || atoms["dvvC"] != nil || code.hasPrefix("dv")
        if let hdr = CodecDetails.hdrName(transfer: transfer, dolbyVision: dolbyVision) {
            items.append(InfoItem("HDR", hdr))
            line += " · \(hdr.components(separatedBy: " ").first ?? hdr)"
        }
        if let name = extensionString(kCMFormatDescriptionExtension_ColorPrimaries).flatMap(CodecDetails.coreMediaPrimaries).flatMap(CodecDetails.primariesName) {
            items.append(InfoItem("Colour primaries", name))
        }
        if let name = transfer.flatMap(CodecDetails.transferName) { items.append(InfoItem("Transfer", name)) }
        if let name = extensionString(kCMFormatDescriptionExtension_YCbCrMatrix).flatMap(CodecDetails.coreMediaMatrix).flatMap(CodecDetails.matrixName) {
            items.append(InfoItem("Matrix", name))
        }
        return (items, line)
    }

    private static func audioDetails(_ description: CMFormatDescription, format: InfoFormat) -> ([InfoItem], String) {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return ([InfoItem("Codec", CodecDetails.fourCC(CMFormatDescriptionGetMediaSubType(description)))], "")
        }
        var bitDepth: Int?
        let codec: String
        switch asbd.mFormatID {
        case kAudioFormatMPEG4AAC:
            // The object type is in the decoder configuration; mFormatFlags is usually 0.
            var size = 0
            let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size).map { Data(bytes: $0, count: size) }
            codec = cookie.flatMap(CodecDetails.aacProfile(elementaryStreamDescriptor:))
                ?? (asbd.mFormatFlags > 0 ? CodecDetails.aacProfile(objectType: Int(asbd.mFormatFlags)) : "AAC")
        case kAudioFormatMPEG4AAC_HE: codec = "HE-AAC"
        case kAudioFormatMPEG4AAC_HE_V2: codec = "HE-AACv2"
        case kAudioFormatMPEG4AAC_ELD: codec = "AAC ELD"
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            codec = asbd.mFormatID == kAudioFormatFLAC ? "FLAC" : "ALAC"
            bitDepth = [1: 16, 2: 20, 3: 24, 4: 32][Int(asbd.mFormatFlags)]
        case kAudioFormatMPEGLayer3: codec = "MP3"
        case kAudioFormatMPEGLayer2: codec = "MPEG Layer 2"
        case kAudioFormatAC3: codec = "AC-3"
        case kAudioFormatEnhancedAC3: codec = "E-AC-3"
        case kAudioFormatOpus: codec = "Opus"
        case kAudioFormatLinearPCM:
            let float = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            codec = float ? "PCM (float)" : "PCM"
            bitDepth = Int(asbd.mBitsPerChannel)
        default: codec = CodecDetails.fourCC(asbd.mFormatID)
        }
        var items = [InfoItem("Codec", codec),
                     InfoItem("Sample rate", CodecDetails.sampleRate(asbd.mSampleRate, format: format)),
                     InfoItem("Channels", CodecDetails.channelDescription(Int(asbd.mChannelsPerFrame)))]
        if let bitDepth, bitDepth > 0 { items.append(InfoItem("Bit depth", "\(bitDepth) bits")) }
        let line = [codec, CodecDetails.sampleRate(asbd.mSampleRate, format: format), CodecDetails.shortChannels(Int(asbd.mChannelsPerFrame))]
            .joined(separator: " · ")
        return (items, line)
    }

    private static func containerName(_ type: UTType?) -> String {
        let names = [
            "public.mpeg-4": "MPEG-4", "com.apple.quicktime-movie": "QuickTime", "public.mpeg-4-audio": "MPEG-4 Audio",
            "com.apple.m4a-audio": "MPEG-4 Audio", "com.apple.m4v-video": "MPEG-4 (iTunes)", "public.mp3": "MP3",
            "com.microsoft.waveform-audio": "WAVE", "public.aiff-audio": "AIFF", "public.aifc-audio": "AIFF-C",
            "public.avi": "AVI", "public.mpeg-2-transport-stream": "MPEG-TS", "public.3gpp": "3GPP",
            "org.xiph.flac": "FLAC", "com.apple.coreaudio-format": "Core Audio Format",
        ]
        guard let type else { return "Unknown" }
        return names[type.identifier] ?? type.localizedDescription ?? type.identifier
    }
}

/// Runs async AVFoundation loading for callers that must answer synchronously (Finder's
/// context menu is built synchronously). Gives up after `timeout` seconds.
func runBlocking<T: Sendable>(timeout: TimeInterval = 5, _ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success, let result = box.result else {
        throw CocoaError(.fileReadUnknown)
    }
    return try result.get()
}

/// Hands a result from the detached task back to the waiting thread; the semaphore orders access.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
