import Foundation

public enum BencodeError: Error, Equatable {
    case malformed(offset: Int)
    case tooDeep
}

/// A decoded bencode value (the serialization used by .torrent files).
public indirect enum Bencode: Equatable, Sendable {
    case integer(Int64)
    case string(Data)
    case list([Bencode])
    case dictionary([String: Bencode])

    public subscript(key: String) -> Bencode? {
        if case .dictionary(let dictionary) = self { return dictionary[key] }
        return nil
    }

    public var integer: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var bytes: Data? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The string as UTF-8, falling back to Latin-1 for legacy torrents in other encodings.
    public var text: String? {
        guard let bytes else { return nil }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1)
    }

    public var list: [Bencode]? {
        if case .list(let value) = self { return value }
        return nil
    }

    public var dictionary: [String: Bencode]? {
        if case .dictionary(let value) = self { return value }
        return nil
    }

    static let maxDepth = 64

    public static func decode(_ data: Data) throws -> Bencode {
        var parser = Parser(bytes: [UInt8](data))
        return try parser.value(depth: 0)
    }

    /// The exact bytes of a top-level dictionary value — a torrent's info hash is the hash of
    /// the "info" bytes as written, which re-encoding might not reproduce.
    public static func rawValue(forKey key: String, in data: Data) throws -> Data? {
        var parser = Parser(bytes: [UInt8](data))
        guard parser.peek() == UInt8(ascii: "d") else { throw BencodeError.malformed(offset: 0) }
        parser.index += 1
        while parser.peek() != UInt8(ascii: "e") {
            let name = try parser.string()
            let start = parser.index
            _ = try parser.value(depth: 1)
            if String(decoding: name, as: UTF8.self) == key {
                return data.subdata(in: (data.startIndex + start)..<(data.startIndex + parser.index))
            }
        }
        return nil
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func peek() -> UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        mutating func value(depth: Int) throws -> Bencode {
            guard depth < Bencode.maxDepth else { throw BencodeError.tooDeep }
            guard let byte = peek() else { throw BencodeError.malformed(offset: index) }
            switch byte {
            case UInt8(ascii: "i"):
                index += 1
                let number = try integer(until: UInt8(ascii: "e"))
                return .integer(number)
            case UInt8(ascii: "l"):
                index += 1
                var items: [Bencode] = []
                while peek() != UInt8(ascii: "e") {
                    guard peek() != nil else { throw BencodeError.malformed(offset: index) }
                    items.append(try value(depth: depth + 1))
                }
                index += 1
                return .list(items)
            case UInt8(ascii: "d"):
                index += 1
                var items: [String: Bencode] = [:]
                while peek() != UInt8(ascii: "e") {
                    guard peek() != nil else { throw BencodeError.malformed(offset: index) }
                    let key = String(decoding: try string(), as: UTF8.self)
                    items[key] = try value(depth: depth + 1)
                }
                index += 1
                return .dictionary(items)
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                return .string(Data(try string()))
            default:
                throw BencodeError.malformed(offset: index)
            }
        }

        mutating func string() throws -> ArraySlice<UInt8> {
            let length = try integer(until: UInt8(ascii: ":"))
            guard length >= 0, length <= bytes.count - index else { throw BencodeError.malformed(offset: index) }
            let start = index
            index += Int(length)
            return bytes[start..<index]
        }

        /// Digits up to `terminator`; rejects leading zeros, "-0" and overflow, as the spec requires.
        mutating func integer(until terminator: UInt8) throws -> Int64 {
            let start = index
            guard let end = bytes[index...].firstIndex(of: terminator), end > start, end - start <= 20 else {
                throw BencodeError.malformed(offset: start)
            }
            let text = String(decoding: bytes[start..<end], as: UTF8.self)
            let digits = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
            guard !digits.isEmpty,
                  digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
                  digits == "0" || !digits.hasPrefix("0"),
                  text != "-0",
                  let value = Int64(text)
            else {
                throw BencodeError.malformed(offset: start)
            }
            index = end + 1
            return value
        }
    }
}
