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
    public private(set) var cues: [MatroskaCuePoint] = []
    /// Nanoseconds per timestamp tick; 1 ms unless the file says otherwise.
    public private(set) var timestampScale: UInt64 = 1_000_000
    public private(set) var title: String?
    public private(set) var durationSeconds: Double?

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
            guard let element = try? reader.readElementHeader() else { break }
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
        for id in [ID.info, ID.tracks, ID.cues] where !seen.contains(id) {
            guard let position = seekEntries[id], position < segmentEnd else { continue }
            var seekReader = EBMLReader(source: source, offset: position)
            if let element = try? seekReader.readElementHeader(), element.id == id {
                try? parseTopLevel(element, seekEntries: &seekEntries)
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
                    let value = Int(clamping: EBMLReader.unsigned(try reader.readData(item)))
                    switch item.id {
                    case ID.pixelWidth: video.pixelWidth = value
                    case ID.pixelHeight: video.pixelHeight = value
                    case ID.displayWidth: video.displayWidth = value
                    case ID.displayHeight: video.displayHeight = value
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

        /// Level-1 elements: inside a cluster of unknown size, one of these ends the cluster.
        static let topLevel: Set<UInt32> = [cluster, cues, seekHead, info, tracks, 0x1254_C367, 0x1043_A770, 0x1941_A469]
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
                do {
                    try advance()
                } catch {
                    finished = true
                }
            }
            return pending.isEmpty ? nil : pending.removeFirst()
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

            switch element.id {
            case ID.cluster:
                clusterEnd = element.end(limit: limit)
                clusterTimestamp = 0
                reader.offset = element.dataOffset
            case ID.clusterTimestamp where clusterEnd != nil:
                clusterTimestamp = Int64(clamping: EBMLReader.unsigned(try reader.readData(element)))
            case ID.simpleBlock where clusterEnd != nil:
                let block = try MatroskaBlock.parse(try reader.readData(element))
                emit(block, isKeyframe: block.isKeyframe)
            case ID.blockGroup where clusterEnd != nil:
                try readBlockGroup(element)
            default:
                guard case .known = element.size else {
                    finished = true
                    return
                }
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
            if let blockData {
                let block = try MatroskaBlock.parse(blockData)
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
