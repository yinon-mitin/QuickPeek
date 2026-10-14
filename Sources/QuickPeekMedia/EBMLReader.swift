import Foundation

public enum MatroskaError: Error, Equatable {
    case notMatroska
    case truncated(offset: Int64)
    case invalidVariableInteger(offset: Int64)
    case invalidBlock
}

enum EBMLSize: Equatable {
    case known(UInt64)
    case unknown
}

struct EBMLElementHeader {
    let id: UInt32
    let size: EBMLSize
    /// Offset of the element's first header byte.
    let offset: Int64
    /// Offset of the element's payload.
    let dataOffset: Int64

    func end(limit: Int64) -> Int64 {
        switch size {
        case .known(let size): return min(dataOffset + Int64(clamping: size), limit)
        case .unknown: return limit
        }
    }
}

/// Sequential reader of EBML, the binary format underneath Matroska and WebM.
struct EBMLReader {
    let source: any ByteSource
    var offset: Int64

    init(source: any ByteSource, offset: Int64 = 0) {
        self.source = source
        self.offset = offset
    }

    mutating func readID() throws -> UInt32 {
        let (value, _, _) = try readVariableInteger(maxLength: 4, keepMarker: true)
        return UInt32(value)
    }

    mutating func readSize() throws -> EBMLSize {
        let (value, _, allOnes) = try readVariableInteger(maxLength: 8, keepMarker: false)
        return allOnes ? .unknown : .known(value)
    }

    mutating func readElementHeader() throws -> EBMLElementHeader {
        let start = offset
        let id = try readID()
        let size = try readSize()
        return EBMLElementHeader(id: id, size: size, offset: start, dataOffset: offset)
    }

    mutating func readData(_ header: EBMLElementHeader) throws -> Data {
        guard case .known(let size) = header.size, size <= UInt64(Int32.max) else {
            throw MatroskaError.invalidVariableInteger(offset: header.offset)
        }
        let data = try source.read(at: header.dataOffset, count: Int(size))
        offset = header.dataOffset + Int64(size)
        return data
    }

    private mutating func readVariableInteger(maxLength: Int, keepMarker: Bool) throws -> (UInt64, Int, Bool) {
        let start = offset
        let first = try source.read(at: offset, count: 1)[0]
        let length = first.leadingZeroBitCount + 1
        guard first != 0, length <= maxLength else {
            throw MatroskaError.invalidVariableInteger(offset: start)
        }
        let bytes = length > 1 ? try source.read(at: offset + 1, count: length - 1) : Data()
        offset += Int64(length)

        let markerMask: UInt8 = length == 8 ? 0 : 0xFF >> length
        var value = UInt64(keepMarker ? first : first & markerMask)
        var allOnes = (first & markerMask) == markerMask
        for byte in bytes {
            value = value << 8 | UInt64(byte)
            allOnes = allOnes && byte == 0xFF
        }
        return (value, length, allOnes)
    }

    // MARK: Payload decoding

    static func unsigned(_ data: Data) -> UInt64 {
        data.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func signed(_ data: Data) -> Int64 {
        guard let first = data.first else { return 0 }
        var value: Int64 = first & 0x80 != 0 ? -1 : 0
        for byte in data.prefix(8) {
            value = value << 8 | Int64(byte)
        }
        return value
    }

    static func float(_ data: Data) -> Double {
        let bits = unsigned(data)
        switch data.count {
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case 8: return Double(bitPattern: bits)
        default: return 0
        }
    }

    static func string(_ data: Data) -> String {
        String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }
}

extension Data {
    /// Reads an EBML variable-size integer from a byte buffer (used inside block lacing).
    /// Returns the value without its marker bit and the number of bytes consumed.
    func ebmlVariableInteger(at index: Int) throws -> (value: UInt64, length: Int) {
        guard index < endIndex else { throw MatroskaError.invalidBlock }
        let first = self[index]
        let length = first.leadingZeroBitCount + 1
        guard first != 0, index + length <= endIndex else { throw MatroskaError.invalidBlock }
        var value = UInt64(length == 8 ? 0 : first & (0xFF >> length))
        for byte in self[(index + 1)..<(index + length)] {
            value = value << 8 | UInt64(byte)
        }
        return (value, length)
    }
}
