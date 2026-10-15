import CoreMedia
import Foundation

public struct MatroskaTrack: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case video, audio, subtitle, other
    }

    public struct Video: Sendable, Equatable {
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var displayWidth: Int?
        public var displayHeight: Int?
        public var colour: Colour?
        public var isInterlaced: Bool?
    }

    /// Colour signalling, coded as in ITU-T H.273 (1 = BT.709, 9 = BT.2020, 16 = PQ, 18 = HLG…).
    public struct Colour: Sendable, Equatable {
        public var matrixCoefficients: Int?
        public var bitsPerChannel: Int?
        public var range: Int?
        public var transferCharacteristics: Int?
        public var primaries: Int?
        public var maxContentLightLevel: Int?
        public var maxFrameAverageLightLevel: Int?
    }

    public struct Audio: Sendable, Equatable {
        public var samplingFrequency: Double
        public var channels: Int
        public var bitDepth: Int?
    }

    public var number: UInt64
    public var type: Kind
    public var codecID: String
    public var codecPrivate: Data?
    /// Nanoseconds per frame, when the muxer recorded it.
    public var defaultDuration: UInt64?
    /// Nanoseconds of decoder delay (Opus pre-skip).
    public var codecDelay: UInt64?
    public var name: String?
    public var language: String?
    public var video: Video?
    public var audio: Audio?
    /// Bytes removed from the start of every frame by "header stripping" compression.
    public var strippedHeader: Data?
    public var uid: UInt64?
    public var isDefault = true
    public var isForced = false
    /// Tags that target this track, such as mkvmerge's statistics (BPS, NUMBER_OF_FRAMES).
    public var tags: [String: String] = [:]
}

public struct MatroskaAttachment: Sendable, Equatable {
    public var name: String
    public var mediaType: String
    public var size: Int
}

public struct MatroskaCuePoint: Sendable, Equatable {
    /// In timestamp ticks (see `MatroskaDemuxer.timestampScale`).
    public var time: UInt64
    public var trackNumber: UInt64
    /// Absolute file offset of the cluster that contains the cue.
    public var clusterPosition: Int64
}

public struct MatroskaFrame: Sendable {
    public var trackNumber: UInt64
    /// Presentation time in timestamp ticks.
    public var timestamp: Int64
    public var isKeyframe: Bool
    public var data: Data
}

/// Reads Matroska and WebM files: header, tracks, seek index and frames.
/// Pure parsing — decoding is left to VideoToolbox/AudioToolbox.
public final class MatroskaDemuxer {
    public private(set) var docType = ""
    public private(set) var tracks: [MatroskaTrack] = []
    public private(set) lazy var streams: [MediaStream] = tracks.map(Self.mediaStream)
    public private(set) var cues: [MatroskaCuePoint] = []
    /// Nanoseconds per timestamp tick; 1 ms unless the file says otherwise.
    public private(set) var timestampScale: UInt64 = 1_000_000
    public private(set) var title: String?
    public private(set) var durationSeconds: Double?
    public private(set) var muxingApp: String?
    public private(set) var writingApp: String?
    public private(set) var dateUTC: Date?
    public private(set) var chapterCount = 0
    public private(set) var attachments: [MatroskaAttachment] = []
    /// Tags that target the whole file (TITLE, ENCODER, …).
    public private(set) var tags: [String: String] = [:]
    private var trackTags: [UInt64: [String: String]] = [:]

    let source: any ByteSource
    private var segmentDataOffset: Int64 = 0
    private var segmentEnd: Int64 = 0
    private var firstClusterOffset: Int64?

    public convenience init(url: URL) throws {
        try self.init(source: FileByteSource(url: url))
    }

    public init(source: any ByteSource) throws {
        self.source = source
        try parseHeader()
    }

    public func seconds(fromTicks ticks: Int64) -> Double {
        Double(ticks) * Double(timestampScale) / 1_000_000_000
    }

    public func ticks(fromSeconds seconds: Double) -> Int64 {
        Int64(seconds * 1_000_000_000 / Double(timestampScale))
    }

    /// The cluster to start reading from to reach `seconds`, preferring cues of the video track.
    public func clusterPosition(forSeconds seconds: Double) -> Int64? {
        let target = UInt64(max(0, ticks(fromSeconds: seconds)))
        let videoTrack = tracks.first { $0.type == .video }?.number
        let candidates = cues.filter { videoTrack == nil || $0.trackNumber == videoTrack }
        let usable = candidates.isEmpty ? cues : candidates
        return usable.last { $0.time <= target }?.clusterPosition ?? firstClusterOffset
    }

    /// Where to resume reading to reach `seconds`, and the time playback actually resumes at
    /// (the cue's keyframe, at or before the target).
    public func seekPoint(forSeconds seconds: Double) -> (position: Int64?, seconds: Double) {
        let target = UInt64(max(0, ticks(fromSeconds: seconds)))
        let videoTrack = tracks.first { $0.type == .video }?.number
        let candidates = cues.filter { videoTrack == nil || $0.trackNumber == videoTrack }
        guard let cue = (candidates.isEmpty ? cues : candidates).last(where: { $0.time <= target }) else {
            return (firstClusterOffset, 0)
        }
        return (cue.clusterPosition, self.seconds(fromTicks: Int64(cue.time)))
    }

    public func time(fromTicks ticks: Int64) -> CMTime {
        CMTime(value: ticks * Int64(clamping: timestampScale), timescale: 1_000_000_000)
    }

    /// Frames in file order, starting at the first cluster or at a cluster offset from `clusterPosition`.
    public func frames(fromClusterAt position: Int64? = nil) throws -> MatroskaFrameSequence {
        MatroskaFrameSequence(demuxer: self, start: position ?? firstClusterOffset ?? segmentEnd)
    }

    // MARK: - Header

    private func parseHeader() throws {
        var reader = EBMLReader(source: source)
        let header: EBMLElementHeader
        do {
            header = try reader.readElementHeader()
        } catch {
            throw MatroskaError.notMatroska
        }
        guard header.id == ID.ebml, case .known = header.size else { throw MatroskaError.notMatroska }

        try forEachChild(of: header) { child, reader in
            if child.id == ID.docType { docType = EBMLReader.string(try reader.readData(child)) }
        }
        guard docType == "matroska" || docType == "webm" else { throw MatroskaError.notMatroska }

        reader.offset = header.end(limit: source.size)
        var segment: EBMLElementHeader?
        while reader.offset < source.size {
            let element = try reader.readElementHeader()
            if element.id == ID.segment {
                segment = element
                break
            }
            reader.offset = element.end(limit: source.size)
        }
        guard let segment else { throw MatroskaError.notMatroska }
        segmentDataOffset = segment.dataOffset
        segmentEnd = segment.end(limit: source.size)

        var seekEntries: [UInt32: Int64] = [:]
        var seen: Set<UInt32> = []
        reader.offset = segment.dataOffset
        while reader.offset < segmentEnd {
            let start = reader.offset
            guard let element = try? reader.readElementHeader(), isPlausible(element, within: segmentEnd) else {
                // Damaged or padded with garbage: continue at the next top-level element.
                guard let next = resync(from: start + 1, to: ID.topLevel) else { break }
                reader.offset = next
                continue
            }
            if element.id == ID.cluster {
                firstClusterOffset = element.offset
                break
            }
            guard case .known = element.size else { break }
            seen.insert(element.id)
            try? parseTopLevel(element, seekEntries: &seekEntries)
            reader.offset = element.end(limit: segmentEnd)
        }

        // Muxers that write the index after the clusters point to it from the SeekHead.
        for id in [ID.info, ID.tracks, ID.cues, ID.tags, ID.chapters, ID.attachments] where !seen.contains(id) {
            guard let position = seekEntries[id], position < segmentEnd else { continue }
            var seekReader = EBMLReader(source: source, offset: position)
            if let element = try? seekReader.readElementHeader(), element.id == id {
                try? parseTopLevel(element, seekEntries: &seekEntries)
            }
        }

        for index in tracks.indices {
            if let uid = tracks[index].uid, let tags = trackTags[uid] {
                tracks[index].tags = tags
            }
        }
    }

    private func parseTopLevel(_ element: EBMLElementHeader, seekEntries: inout [UInt32: Int64]) throws {
        switch element.id {
        case ID.seekHead:
            try forEachChild(of: element) { seek, _ in
                guard seek.id == ID.seek else { return }
                var id: UInt32?
                var position: Int64?
                try forEachChild(of: seek) { field, reader in
                    let data = try reader.readData(field)
                    if field.id == ID.seekID { id = UInt32(truncatingIfNeeded: EBMLReader.unsigned(data)) }
                    if field.id == ID.seekPosition { position = Int64(clamping: EBMLReader.unsigned(data)) }
                }
                if let id, let position {
                    seekEntries[id] = segmentDataOffset + position
                }
            }
        case ID.info:
            var duration: Double?
            try forEachChild(of: element) { field, reader in
                switch field.id {
                case ID.timestampScale: timestampScale = max(1, EBMLReader.unsigned(try reader.readData(field)))
                case ID.duration: duration = EBMLReader.float(try reader.readData(field))
                case ID.title: title = EBMLReader.string(try reader.readData(field))
                case ID.muxingApp: muxingApp = EBMLReader.string(try reader.readData(field))
                case ID.writingApp: writingApp = EBMLReader.string(try reader.readData(field))
                case ID.dateUTC:
                    // Nanoseconds since 2001-01-01, the same epoch as Date's reference date.
                    dateUTC = Date(timeIntervalSinceReferenceDate: Double(EBMLReader.signed(try reader.readData(field))) / 1e9)
                default: break
                }
            }
            if let duration, duration > 0 {
                durationSeconds = duration * Double(timestampScale) / 1_000_000_000
            }
        case ID.tracks:
            try forEachChild(of: element) { entry, _ in
                if entry.id == ID.trackEntry, let track = try parseTrack(entry) {
                    tracks.append(track)
                }
            }
        case ID.cues:
            try forEachChild(of: element) { point, _ in
                guard point.id == ID.cuePoint else { return }
                var time: UInt64?
                var positions: [(UInt64, Int64)] = []
                try forEachChild(of: point) { field, reader in
                    if field.id == ID.cueTime {
                        time = EBMLReader.unsigned(try reader.readData(field))
                    } else if field.id == ID.cueTrackPositions {
                        var track: UInt64?
                        var cluster: Int64?
                        try forEachChild(of: field) { position, reader in
                            let data = try reader.readData(position)
                            if position.id == ID.cueTrack { track = EBMLReader.unsigned(data) }
                            if position.id == ID.cueClusterPosition { cluster = Int64(clamping: EBMLReader.unsigned(data)) }
                        }
                        if let track, let cluster { positions.append((track, cluster)) }
                    }
                }
                guard let time else { return }
                for (track, cluster) in positions {
                    cues.append(MatroskaCuePoint(time: time, trackNumber: track, clusterPosition: segmentDataOffset + cluster))
                }
            }
            cues.sort { $0.time < $1.time }
        case ID.tags:
            try forEachChild(of: element) { tag, _ in
                guard tag.id == ID.tag else { return }
                var targets: [UInt64] = []
                var values: [String: String] = [:]
                try forEachChild(of: tag) { field, reader in
                    if field.id == ID.targets {
                        try forEachChild(of: field) { target, reader in
                            if target.id == ID.tagTrackUID { targets.append(EBMLReader.unsigned(try reader.readData(target))) }
                        }
                    } else if field.id == ID.simpleTag {
                        var name: String?
                        var value: String?
                        try forEachChild(of: field) { item, reader in
                            if item.id == ID.tagName { name = EBMLReader.string(try reader.readData(item)) }
                            if item.id == ID.tagString { value = EBMLReader.string(try reader.readData(item)) }
                        }
                        if let name, let value { values[name] = value }
                    }
                }
                let trackTargets = targets.filter { $0 != 0 }
                if trackTargets.isEmpty {
                    tags.merge(values) { $1 }
                } else {
                    for uid in trackTargets { trackTags[uid, default: [:]].merge(values) { $1 } }
                }
            }
        case ID.chapters:
            try forEachChild(of: element) { edition, _ in
                guard edition.id == ID.editionEntry else { return }
                try forEachChild(of: edition) { atom, _ in
                    if atom.id == ID.chapterAtom { chapterCount += 1 }
                }
            }
        case ID.attachments:
            try forEachChild(of: element) { file, _ in
                guard file.id == ID.attachedFile else { return }
                var attachment = MatroskaAttachment(name: "", mediaType: "", size: 0)
                try forEachChild(of: file) { field, reader in
                    switch field.id {
                    case ID.fileName: attachment.name = EBMLReader.string(try reader.readData(field))
                    case ID.fileMediaType: attachment.mediaType = EBMLReader.string(try reader.readData(field))
                    case ID.fileData: if case .known(let size) = field.size { attachment.size = Int(clamping: size) }
                    default: break
                    }
                }
                attachments.append(attachment)
            }
        default:
            break
        }
    }

    private func parseTrack(_ entry: EBMLElementHeader) throws -> MatroskaTrack? {
        var track = MatroskaTrack(number: 0, type: .other, codecID: "")
        try forEachChild(of: entry) { field, reader in
            switch field.id {
            case ID.trackNumber:
                track.number = EBMLReader.unsigned(try reader.readData(field))
            case ID.trackUID:
                track.uid = EBMLReader.unsigned(try reader.readData(field))
            case ID.flagDefault:
                track.isDefault = EBMLReader.unsigned(try reader.readData(field)) != 0
            case ID.flagForced:
                track.isForced = EBMLReader.unsigned(try reader.readData(field)) != 0
            case ID.trackType:
                switch EBMLReader.unsigned(try reader.readData(field)) {
                case 1: track.type = .video
                case 2: track.type = .audio
                case 0x11: track.type = .subtitle
                default: track.type = .other
                }
            case ID.codecID: track.codecID = EBMLReader.string(try reader.readData(field))
            case ID.codecPrivate: track.codecPrivate = try reader.readData(field)
            case ID.defaultDuration: track.defaultDuration = EBMLReader.unsigned(try reader.readData(field))
            case ID.codecDelay: track.codecDelay = EBMLReader.unsigned(try reader.readData(field))
            case ID.name: track.name = EBMLReader.string(try reader.readData(field))
            case ID.language: track.language = EBMLReader.string(try reader.readData(field))
            case ID.video:
                var video = MatroskaTrack.Video(pixelWidth: 0, pixelHeight: 0)
                try forEachChild(of: field) { item, reader in
                    // Colour is a master element; everything else here is an unsigned integer.
                    let value = item.id == ID.colour ? 0 : Int(clamping: EBMLReader.unsigned(try reader.readData(item)))
                    switch item.id {
                    case ID.pixelWidth: video.pixelWidth = value
                    case ID.pixelHeight: video.pixelHeight = value
                    case ID.displayWidth: video.displayWidth = value
                    case ID.displayHeight: video.displayHeight = value
                    case ID.flagInterlaced: video.isInterlaced = value == 1
                    case ID.colour: video.colour = try parseColour(item)
                    default: break
                    }
                }
                track.video = video
            case ID.audio:
                var audio = MatroskaTrack.Audio(samplingFrequency: 8000, channels: 1)
                try forEachChild(of: field) { item, reader in
                    switch item.id {
                    case ID.samplingFrequency: audio.samplingFrequency = EBMLReader.float(try reader.readData(item))
                    case ID.channels: audio.channels = Int(clamping: EBMLReader.unsigned(try reader.readData(item)))
                    case ID.bitDepth: audio.bitDepth = Int(clamping: EBMLReader.unsigned(try reader.readData(item)))
                    default: break
                    }
                }
                track.audio = audio
            case ID.contentEncodings:
                track.strippedHeader = try parseStrippedHeader(field)
            default:
                break
            }
        }
        return track.number == 0 ? nil : track
    }

    private func parseColour(_ element: EBMLElementHeader) throws -> MatroskaTrack.Colour {
        var colour = MatroskaTrack.Colour()
        try forEachChild(of: element) { field, reader in
            guard field.id != ID.masteringMetadata else { return }
            let value = Int(clamping: EBMLReader.unsigned(try reader.readData(field)))
            switch field.id {
            case ID.matrixCoefficients: colour.matrixCoefficients = value
            case ID.bitsPerChannel: colour.bitsPerChannel = value
            case ID.range: colour.range = value
            case ID.transferCharacteristics: colour.transferCharacteristics = value
            case ID.primaries: colour.primaries = value
            case ID.maxCLL: colour.maxContentLightLevel = value
            case ID.maxFALL: colour.maxFrameAverageLightLevel = value
            default: break
            }
        }
        return colour
    }

    /// Header stripping (ContentCompAlgo 3) is common in mkvmerge output; other encodings are left as-is.
    private func parseStrippedHeader(_ encodings: EBMLElementHeader) throws -> Data? {
        var stripped: Data?
        try forEachChild(of: encodings) { encoding, _ in
            guard encoding.id == ID.contentEncoding else { return }
            try forEachChild(of: encoding) { compression, _ in
                guard compression.id == ID.contentCompression else { return }
                var algorithm: UInt64 = 0
                var settings: Data?
                try forEachChild(of: compression) { field, reader in
                    if field.id == ID.contentCompAlgo { algorithm = EBMLReader.unsigned(try reader.readData(field)) }
                    if field.id == ID.contentCompSettings { settings = try reader.readData(field) }
                }
                if algorithm == 3 { stripped = settings }
            }
        }
        return stripped
    }

    private func forEachChild(
        of parent: EBMLElementHeader,
        _ body: (EBMLElementHeader, inout EBMLReader) throws -> Void
    ) throws {
        let end = parent.end(limit: source.size)
        var reader = EBMLReader(source: source, offset: parent.dataOffset)
        while reader.offset < end {
            let child = try reader.readElementHeader()
            guard case .known = child.size else { return }
            var childReader = reader
            try body(child, &childReader)
            reader.offset = child.end(limit: end)
        }
    }

    // MARK: - Recovery

    /// An element whose declared size fits in its parent. Garbage bytes rarely decode to one.
    func isPlausible(_ element: EBMLElementHeader, within end: Int64) -> Bool {
        switch element.size {
        case .unknown:
            return element.id == ID.cluster
        case .known(let size):
            // The last cluster of a truncated file may claim more bytes than remain.
            let limit = element.id == ID.cluster ? Int64.max : end
            return size <= UInt64(Int64.max) && element.dataOffset + Int64(size) <= limit
        }
    }

    /// ID bytes also occur inside elements (a SeekHead lists the IDs it points to), so a candidate
    /// counts only if another top-level element — or the end of the segment — follows it.
    private func isResyncPoint(_ offset: Int64, limit: Int64) -> Bool {
        var reader = EBMLReader(source: source, offset: offset)
        guard let header = try? reader.readElementHeader(), isPlausible(header, within: limit) else { return false }

        guard case .known(let size) = header.size else {
            // Unknown-size cluster (live streams): its first child must be the cluster timestamp.
            return (try? reader.readElementHeader().id) == ID.clusterTimestamp
        }
        let end = header.dataOffset + Int64(size)
        if end >= limit { return true }
        var next = EBMLReader(source: source, offset: end)
        guard let following = try? next.readElementHeader() else { return false }
        return (ID.topLevel.contains(following.id) || following.id == ID.void) && isPlausible(following, within: limit)
    }

    /// Scans forward for the next element with one of `ids` that has a plausible header.
    func resync(from offset: Int64, to ids: Set<UInt32>) -> Int64? {
        let limit = segmentEnd > 0 ? segmentEnd : source.size
        let chunkSize = 256 * 1024
        let firstBytes = Set(ids.map { UInt8($0 >> 24) })
        var position = max(0, offset)

        while position + 4 <= limit {
            let count = Int(min(Int64(chunkSize), limit - position))
            guard let chunk = try? source.read(at: position, count: count) else { return nil }
            var index = 0
            while index + 4 <= chunk.count {
                if firstBytes.contains(chunk[index]) {
                    let id = UInt32(chunk[index]) << 24 | UInt32(chunk[index + 1]) << 16
                        | UInt32(chunk[index + 2]) << 8 | UInt32(chunk[index + 3])
                    if ids.contains(id) {
                        let candidate = position + Int64(index)
                        if isResyncPoint(candidate, limit: limit) {
                            return candidate
                        }
                    }
                }
                index += 1
            }
            guard position + Int64(count) < limit else { return nil }
            // Overlap by three bytes so an ID split across chunks is still found.
            position += Int64(count - 3)
        }
        return nil
    }

    // MARK: - Element IDs

    enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let docType: UInt32 = 0x4282
        static let segment: UInt32 = 0x1853_8067
        static let seekHead: UInt32 = 0x114D_9B74
        static let seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB
        static let seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549_A966
        static let timestampScale: UInt32 = 0x2A_D7B1
        static let duration: UInt32 = 0x4489
        static let title: UInt32 = 0x7BA9
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let defaultDuration: UInt32 = 0x23_E383
        static let codecDelay: UInt32 = 0x56AA
        static let name: UInt32 = 0x536E
        static let language: UInt32 = 0x22_B59C
        static let video: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0
        static let pixelHeight: UInt32 = 0xBA
        static let displayWidth: UInt32 = 0x54B0
        static let displayHeight: UInt32 = 0x54BA
        static let audio: UInt32 = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let channels: UInt32 = 0x9F
        static let bitDepth: UInt32 = 0x6264
        static let contentEncodings: UInt32 = 0x6D80
        static let contentEncoding: UInt32 = 0x6240
        static let contentCompression: UInt32 = 0x5034
        static let contentCompAlgo: UInt32 = 0x4254
        static let contentCompSettings: UInt32 = 0x4255
        static let cues: UInt32 = 0x1C53_BB6B
        static let cuePoint: UInt32 = 0xBB
        static let cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7
        static let cueTrack: UInt32 = 0xF7
        static let cueClusterPosition: UInt32 = 0xF1
        static let cluster: UInt32 = 0x1F43_B675
        static let clusterTimestamp: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let referenceBlock: UInt32 = 0xFB
        static let void: UInt32 = 0xEC
        static let muxingApp: UInt32 = 0x4D80
        static let writingApp: UInt32 = 0x5741
        static let dateUTC: UInt32 = 0x4461
        static let trackUID: UInt32 = 0x73C5
        static let flagDefault: UInt32 = 0x88
        static let flagForced: UInt32 = 0x55AA
        static let flagInterlaced: UInt32 = 0x9A
        static let colour: UInt32 = 0x55B0
        static let matrixCoefficients: UInt32 = 0x55B1
        static let bitsPerChannel: UInt32 = 0x55B2
        static let range: UInt32 = 0x55B9
        static let transferCharacteristics: UInt32 = 0x55BA
        static let primaries: UInt32 = 0x55BB
        static let maxCLL: UInt32 = 0x55BC
        static let maxFALL: UInt32 = 0x55BD
        static let masteringMetadata: UInt32 = 0x55D0
        static let tags: UInt32 = 0x1254_C367
        static let tag: UInt32 = 0x7373
        static let targets: UInt32 = 0x63C0
        static let tagTrackUID: UInt32 = 0x63C5
        static let simpleTag: UInt32 = 0x67C8
        static let tagName: UInt32 = 0x45A3
        static let tagString: UInt32 = 0x4487
        static let chapters: UInt32 = 0x1043_A770
        static let editionEntry: UInt32 = 0x45B9
        static let chapterAtom: UInt32 = 0xB6
        static let attachments: UInt32 = 0x1941_A469
        static let attachedFile: UInt32 = 0x61A7
        static let fileName: UInt32 = 0x466E
        static let fileMediaType: UInt32 = 0x4660
        static let fileData: UInt32 = 0x465C

        /// Level-1 elements: inside a cluster of unknown size, one of these ends the cluster.
        static let topLevel: Set<UInt32> = [cluster, cues, seekHead, info, tracks, tags, chapters, attachments]
    }

    // MARK: - Frame reading

    fileprivate var segmentLimit: Int64 { segmentEnd }

    fileprivate func track(_ number: UInt64) -> MatroskaTrack? {
        tracks.first { $0.number == number }
    }
}

/// Lazily walks clusters and yields frames. A damaged or truncated file ends the sequence
/// at the last readable frame instead of failing the whole preview.
public struct MatroskaFrameSequence: Sequence {
    let demuxer: MatroskaDemuxer
    let start: Int64

    public func makeIterator() -> Iterator {
        Iterator(demuxer: demuxer, position: start)
    }

    public final class Iterator: IteratorProtocol {
        private let demuxer: MatroskaDemuxer
        private var reader: EBMLReader
        private var clusterEnd: Int64?
        private var clusterTimestamp: Int64 = 0
        private var pending: [MatroskaFrame] = []
        private var finished = false

        init(demuxer: MatroskaDemuxer, position: Int64) {
            self.demuxer = demuxer
            self.reader = EBMLReader(source: demuxer.source, offset: position)
        }

        public func next() -> MatroskaFrame? {
            while pending.isEmpty && !finished {
                let start = reader.offset
                do {
                    try advance()
                } catch {
                    recover(from: start)
                }
            }
            return pending.isEmpty ? nil : pending.removeFirst()
        }

        /// Skips damaged bytes by jumping to the next cluster; the end of the file ends the sequence.
        private func recover(from offset: Int64) {
            clusterEnd = nil
            if let next = demuxer.resync(from: offset + 1, to: [MatroskaDemuxer.ID.cluster]) {
                reader.offset = next
            } else {
                finished = true
            }
        }

        private func advance() throws {
            let limit = demuxer.segmentLimit
            guard reader.offset < limit else {
                finished = true
                return
            }
            let element = try reader.readElementHeader()
            typealias ID = MatroskaDemuxer.ID

            if let end = clusterEnd, element.offset >= end || ID.topLevel.contains(element.id) {
                clusterEnd = nil
            }
            guard demuxer.isPlausible(element, within: clusterEnd ?? limit) else {
                throw MatroskaError.invalidBlock
            }

            switch element.id {
            case ID.cluster:
                clusterEnd = element.end(limit: limit)
                clusterTimestamp = 0
                reader.offset = element.dataOffset
            case ID.clusterTimestamp where clusterEnd != nil:
                clusterTimestamp = Int64(clamping: EBMLReader.unsigned(try reader.readData(element)))
            case ID.simpleBlock where clusterEnd != nil:
                // A corrupt block costs only itself: its size was plausible, so the next one is intact.
                if let block = try? MatroskaBlock.parse(try reader.readData(element)) {
                    emit(block, isKeyframe: block.isKeyframe)
                }
            case ID.blockGroup where clusterEnd != nil:
                try readBlockGroup(element)
            default:
                guard case .known = element.size else { throw MatroskaError.invalidBlock }
                reader.offset = element.end(limit: limit)
            }
        }

        private func readBlockGroup(_ group: EBMLElementHeader) throws {
            let end = group.end(limit: demuxer.segmentLimit)
            var child = EBMLReader(source: demuxer.source, offset: group.dataOffset)
            var blockData: Data?
            var hasReference = false
            while child.offset < end {
                let element = try child.readElementHeader()
                switch element.id {
                case MatroskaDemuxer.ID.block: blockData = try child.readData(element)
                case MatroskaDemuxer.ID.referenceBlock: hasReference = true
                default: break
                }
                child.offset = element.end(limit: end)
            }
            reader.offset = end
            if let blockData, let block = try? MatroskaBlock.parse(blockData) {
                emit(block, isKeyframe: !hasReference)
            }
        }

        private func emit(_ block: MatroskaBlock, isKeyframe: Bool) {
            let track = demuxer.track(block.trackNumber)
            let base = clusterTimestamp + Int64(block.relativeTimestamp)
            let step = track?.defaultDuration.map { Int64($0 / demuxer.timestampScale) } ?? 0
            for (index, frame) in block.frames.enumerated() {
                var data = frame
                if let header = track?.strippedHeader {
                    data = header + frame
                }
                pending.append(MatroskaFrame(
                    trackNumber: block.trackNumber,
                    timestamp: base + Int64(index) * step,
                    isKeyframe: isKeyframe,
                    data: data
                ))
            }
        }
    }
}
