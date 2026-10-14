import Foundation

/// A SimpleBlock or Block payload: one or more frames of a single track.
struct MatroskaBlock {
    let trackNumber: UInt64
    let relativeTimestamp: Int16
    let isKeyframe: Bool
    let frames: [Data]

    static func parse(_ data: Data) throws -> MatroskaBlock {
        let data = Data(data)
        let (track, trackLength) = try data.ebmlVariableInteger(at: 0)
        var index = trackLength
        guard index + 3 <= data.count else { throw MatroskaError.invalidBlock }

        let timestamp = Int16(bitPattern: UInt16(data[index]) << 8 | UInt16(data[index + 1]))
        let flags = data[index + 2]
        index += 3

        let frames: [Data]
        switch (flags & 0x06) >> 1 {
        case 0:
            frames = [data.subdata(in: index..<data.count)]
        case 1:
            frames = try xiphLaced(data, from: index)
        case 2:
            frames = try fixedLaced(data, from: index)
        default:
            frames = try ebmlLaced(data, from: index)
        }

        return MatroskaBlock(
            trackNumber: track,
            relativeTimestamp: timestamp,
            isKeyframe: flags & 0x80 != 0,
            frames: frames
        )
    }

    private static func xiphLaced(_ data: Data, from start: Int) throws -> [Data] {
        guard start < data.count else { throw MatroskaError.invalidBlock }
        let count = Int(data[start]) + 1
        var index = start + 1
        var sizes: [Int] = []
        for _ in 0..<(count - 1) {
            var size = 0
            while true {
                guard index < data.count else { throw MatroskaError.invalidBlock }
                let byte = data[index]
                index += 1
                size += Int(byte)
                if byte != 0xFF { break }
            }
            sizes.append(size)
        }
        return try split(data, from: index, sizes: sizes)
    }

    private static func fixedLaced(_ data: Data, from start: Int) throws -> [Data] {
        guard start < data.count else { throw MatroskaError.invalidBlock }
        let count = Int(data[start]) + 1
        let payload = data.count - start - 1
        guard payload % count == 0 else { throw MatroskaError.invalidBlock }
        return try split(data, from: start + 1, sizes: Array(repeating: payload / count, count: count - 1))
    }

    private static func ebmlLaced(_ data: Data, from start: Int) throws -> [Data] {
        guard start < data.count else { throw MatroskaError.invalidBlock }
        let count = Int(data[start]) + 1
        var index = start + 1
        var sizes: [Int] = []
        if count > 1 {
            let (first, length) = try data.ebmlVariableInteger(at: index)
            index += length
            sizes.append(Int(clamping: first))
            for _ in 1..<(count - 1) {
                let (raw, length) = try data.ebmlVariableInteger(at: index)
                index += length
                // Signed: subtract half the range of a `length`-byte integer.
                let bias = (Int64(1) << (7 * length - 1)) - 1
                let size = Int64(sizes[sizes.count - 1]) + Int64(clamping: raw) - bias
                guard size >= 0 else { throw MatroskaError.invalidBlock }
                sizes.append(Int(size))
            }
        }
        return try split(data, from: index, sizes: sizes)
    }

    /// Splits laced frames; the last frame takes whatever bytes remain.
    private static func split(_ data: Data, from start: Int, sizes: [Int]) throws -> [Data] {
        var frames: [Data] = []
        var index = start
        for size in sizes {
            guard size >= 0, index + size <= data.count else { throw MatroskaError.invalidBlock }
            frames.append(data.subdata(in: index..<index + size))
            index += size
        }
        guard index <= data.count else { throw MatroskaError.invalidBlock }
        frames.append(data.subdata(in: index..<data.count))
        return frames
    }
}
