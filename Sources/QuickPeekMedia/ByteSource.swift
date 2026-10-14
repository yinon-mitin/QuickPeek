import Foundation

/// Random-access bytes. Demuxers read small pieces at known offsets, so a whole file
/// never has to be loaded into memory.
public protocol ByteSource {
    var size: Int64 { get }
    func read(at offset: Int64, count: Int) throws -> Data
}

public final class FileByteSource: ByteSource {
    public let size: Int64
    private let handle: FileHandle

    // A small read-ahead window: EBML headers are a few bytes each and arrive in order.
    private var window = Data()
    private var windowOffset: Int64 = 0
    private static let windowSize = 64 * 1024

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = Int64(try handle.seekToEnd())
    }

    deinit {
        try? handle.close()
    }

    public func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + Int64(count) <= size else {
            throw MatroskaError.truncated(offset: offset)
        }
        let windowEnd = windowOffset + Int64(window.count)
        if offset >= windowOffset, offset + Int64(count) <= windowEnd {
            let start = window.startIndex + Int(offset - windowOffset)
            return window.subdata(in: start..<start + count)
        }
        if count >= Self.windowSize {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
        try handle.seek(toOffset: UInt64(offset))
        window = try handle.read(upToCount: Self.windowSize) ?? Data()
        windowOffset = offset
        guard window.count >= count else {
            throw MatroskaError.truncated(offset: offset)
        }
        return window.subdata(in: window.startIndex..<window.startIndex + count)
    }
}

public struct DataByteSource: ByteSource {
    private let data: Data

    public init(_ data: Data) {
        self.data = Data(data)
    }

    public var size: Int64 { Int64(data.count) }

    public func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + Int64(count) <= size else {
            throw MatroskaError.truncated(offset: offset)
        }
        let start = data.startIndex + Int(offset)
        return data.subdata(in: start..<start + count)
    }
}
