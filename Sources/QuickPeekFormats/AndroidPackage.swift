import Foundation

public enum AndroidResourceError: Error, Equatable {
    case malformed(offset: Int)
}

/// Bounds-checked little-endian reads over a byte array.
struct ByteReader {
    let bytes: [UInt8]

    func u8(_ offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < bytes.count else { throw AndroidResourceError.malformed(offset: offset) }
        return bytes[offset]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        UInt16(try u8(offset)) | UInt16(try u8(offset + 1)) << 8
    }

    func u32(_ offset: Int) throws -> UInt32 {
        UInt32(try u16(offset)) | UInt32(try u16(offset + 2)) << 16
    }

    /// Reads a chunk header and checks the chunk fits inside `limit`.
    func chunk(at offset: Int, limit: Int) throws -> (type: UInt16, headerSize: Int, size: Int) {
        let type = try u16(offset), headerSize = Int(try u16(offset + 2)), size = Int(try u32(offset + 4))
        guard headerSize >= 8, size >= headerSize, offset + size <= limit else { throw AndroidResourceError.malformed(offset: offset) }
        return (type, headerSize, size)
    }
}

/// ResStringPool: the string table of binary XML and resource tables (UTF-8 or UTF-16).
struct StringPool {
    var strings: [String] = []

    subscript(index: UInt32) -> String? {
        index < strings.count ? strings[Int(index)] : nil
    }

    static func parse(_ reader: ByteReader, at offset: Int, limit: Int) throws -> StringPool {
        let (_, headerSize, size) = try reader.chunk(at: offset, limit: limit)
        let count = Int(try reader.u32(offset + 8))
        let isUTF8 = try reader.u32(offset + 16) & (1 << 8) != 0
        let stringsStart = offset + Int(try reader.u32(offset + 20))
        guard count <= (size - headerSize) / 4 else { throw AndroidResourceError.malformed(offset: offset) }

        var pool = StringPool()
        pool.strings.reserveCapacity(count)
        for index in 0..<count {
            var position = stringsStart + Int(try reader.u32(offset + headerSize + index * 4))
            if isUTF8 {
                // UTF-16 length, then UTF-8 byte length, each one or two bytes.
                position += try reader.u8(position) & 0x80 != 0 ? 2 : 1
                var length = Int(try reader.u8(position))
                if length & 0x80 != 0 {
                    length = (length & 0x7F) << 8 | Int(try reader.u8(position + 1))
                    position += 2
                } else {
                    position += 1
                }
                guard position + length <= offset + size else { throw AndroidResourceError.malformed(offset: position) }
                pool.strings.append(String(decoding: reader.bytes[position..<position + length], as: UTF8.self))
            } else {
                var length = Int(try reader.u16(position))
                position += 2
                if length & 0x8000 != 0 {
                    length = (length & 0x7FFF) << 16 | Int(try reader.u16(position))
                    position += 2
                }
                guard position + length * 2 <= offset + size else { throw AndroidResourceError.malformed(offset: position) }
                var units: [UInt16] = []
                units.reserveCapacity(length)
                for unit in 0..<length { units.append(try reader.u16(position + unit * 2)) }
                pool.strings.append(String(decoding: units, as: UTF16.self))
            }
        }
        return pool
    }
}

/// Android's compiled XML (AndroidManifest.xml inside an APK).
struct AndroidBinaryXML {
    enum Value: Equatable {
        case string(String)
        case integer(Int)
        case boolean(Bool)
        case reference(UInt32)
        case other(UInt32)
    }

    struct Attribute {
        var name: String
        var resourceID: UInt32?
        var value: Value
    }

    enum Event {
        case start(name: String, attributes: [Attribute])
        case end(name: String)
    }

    static func parse(_ data: Data) throws -> [Event] {
        let reader = ByteReader(bytes: [UInt8](data))
        let (type, headerSize, size) = try reader.chunk(at: 0, limit: reader.bytes.count)
        guard type == 0x0003 else { throw AndroidResourceError.malformed(offset: 0) }

        var pool = StringPool()
        var resourceIDs: [UInt32] = []
        var events: [Event] = []
        var position = headerSize
        while position + 8 <= size {
            let chunk = try reader.chunk(at: position, limit: size)
            let body = position + chunk.headerSize
            switch chunk.type {
            case 0x0001:
                pool = try StringPool.parse(reader, at: position, limit: size)
            case 0x0180:
                resourceIDs = try stride(from: body, to: position + chunk.size, by: 4).map { try reader.u32($0) }
            case 0x0102:
                let name = pool[try reader.u32(body + 4)] ?? ""
                let attributesStart = body + Int(try reader.u16(body + 8))
                let attributeSize = max(20, Int(try reader.u16(body + 10)))
                let count = Int(try reader.u16(body + 12))
                var attributes: [Attribute] = []
                for index in 0..<count {
                    let base = attributesStart + index * attributeSize
                    let nameIndex = try reader.u32(base + 4)
                    let raw = try reader.u32(base + 8)
                    let dataType = try reader.u8(base + 15)
                    let data = try reader.u32(base + 16)
                    let value: Value
                    switch dataType {
                    case 0x03: value = .string(pool[data] ?? "")
                    case 0x01: value = .reference(data)
                    case 0x10, 0x11: value = .integer(Int(Int32(bitPattern: data)))
                    case 0x12: value = .boolean(data != 0)
                    default: value = raw != 0xFFFF_FFFF ? .string(pool[raw] ?? "") : .other(data)
                    }
                    attributes.append(Attribute(
                        name: pool[nameIndex] ?? "",
                        resourceID: nameIndex < resourceIDs.count ? resourceIDs[Int(nameIndex)] : nil,
                        value: value
                    ))
                }
                events.append(.start(name: name, attributes: attributes))
            case 0x0103:
                events.append(.end(name: pool[try reader.u32(body + 4)] ?? ""))
            default:
                break
            }
            position += chunk.size
        }
        return events
    }
}

/// resources.arsc: enough of the resource table to resolve strings and file paths by ID.
struct ResourceTable {
    struct Candidate {
        var density: Int
        var isDefault: Bool
        var dataType: UInt8
        var data: UInt32
    }

    var strings = StringPool()
    var entries: [UInt32: [Candidate]] = [:]

    static func parse(_ data: Data) throws -> ResourceTable {
        let reader = ByteReader(bytes: [UInt8](data))
        let (type, headerSize, size) = try reader.chunk(at: 0, limit: reader.bytes.count)
        guard type == 0x0002 else { throw AndroidResourceError.malformed(offset: 0) }

        var table = ResourceTable()
        var position = headerSize
        while position + 8 <= size {
            let chunk = try reader.chunk(at: position, limit: size)
            if chunk.type == 0x0001 {
                table.strings = try StringPool.parse(reader, at: position, limit: size)
            } else if chunk.type == 0x0200 {
                try table.parsePackage(reader, at: position, header: chunk.headerSize, size: chunk.size)
            }
            position += chunk.size
        }
        return table
    }

    private mutating func parsePackage(_ reader: ByteReader, at start: Int, header: Int, size: Int) throws {
        let packageID = try reader.u32(start + 8)
        var position = start + header
        while position + 8 <= start + size {
            let chunk = try reader.chunk(at: position, limit: start + size)
            if chunk.type == 0x0201 {
                try parseType(reader, at: position, header: chunk.headerSize, size: chunk.size, packageID: packageID)
            }
            position += chunk.size
        }
    }

    private mutating func parseType(_ reader: ByteReader, at start: Int, header: Int, size: Int, packageID: UInt32) throws {
        let typeID = UInt32(try reader.u8(start + 8))
        let flags = try reader.u8(start + 9)
        let entryCount = Int(try reader.u32(start + 12))
        let entriesStart = start + Int(try reader.u32(start + 16))
        let config = start + 20
        let configSize = Int(try reader.u32(config))
        let density = configSize >= 16 ? Int(try reader.u16(config + 14)) : 0
        let isDefault = try (4..<min(configSize, 64)).allSatisfy { try reader.u8(config + $0) == 0 }
        guard entryCount <= size else { throw AndroidResourceError.malformed(offset: start) }

        // Entry offsets: dense 32-bit, dense 16-bit (aapt2 "offset16"), or sparse (index, offset/4) pairs.
        var offsets: [(index: Int, offset: Int)] = []
        let table = start + header
        for slot in 0..<entryCount {
            if flags & 0x01 != 0 {
                offsets.append((Int(try reader.u16(table + slot * 4)), Int(try reader.u16(table + slot * 4 + 2)) * 4))
            } else if flags & 0x02 != 0 {
                let value = try reader.u16(table + slot * 2)
                if value != 0xFFFF { offsets.append((slot, Int(value) * 4)) }
            } else {
                let value = try reader.u32(table + slot * 4)
                if value != 0xFFFF_FFFF { offsets.append((slot, Int(value))) }
            }
        }

        for (index, offset) in offsets {
            let entry = entriesStart + offset
            let entryFlags = try reader.u16(entry + 2)
            let dataType: UInt8, data: UInt32
            if entryFlags & 0x0008 != 0 {
                // Compact entry: key (16 bits), flags with the value type in the high byte, then data.
                dataType = UInt8(entryFlags >> 8)
                data = try reader.u32(entry + 4)
            } else if entryFlags & 0x0001 != 0 {
                continue // complex (bag) entries carry no single value
            } else {
                let entrySize = Int(try reader.u16(entry))
                dataType = try reader.u8(entry + entrySize + 3)
                data = try reader.u32(entry + entrySize + 4)
            }
            let id = packageID << 24 | typeID << 16 | UInt32(index)
            entries[id, default: []].append(Candidate(density: density, isDefault: isDefault, dataType: dataType, data: data))
        }
    }

    /// A string resource, preferring the default configuration; follows references.
    func string(for id: UInt32, depth: Int = 0) -> String? {
        guard depth < 5, let candidates = entries[id], let chosen = candidates.first(where: \.isDefault) ?? candidates.first else { return nil }
        switch chosen.dataType {
        case 0x03: return strings[chosen.data]
        case 0x01: return string(for: chosen.data, depth: depth + 1)
        default: return nil
        }
    }

    /// File paths a resource resolves to in every configuration, with their densities.
    func files(for id: UInt32, depth: Int = 0) -> [(path: String, density: Int)] {
        guard depth < 5, let candidates = entries[id] else { return [] }
        return candidates.flatMap { candidate -> [(path: String, density: Int)] in
            switch candidate.dataType {
            case 0x03: return strings[candidate.data].map { [($0, candidate.density == 0 ? 160 : candidate.density)] } ?? []
            case 0x01: return files(for: candidate.data, depth: depth + 1)
            default: return []
            }
        }
    }
}

enum AndroidPackage {
    // Attribute resource IDs from android.R.attr — names can be stripped by obfuscators, IDs cannot.
    static let label: UInt32 = 0x0101_0001
    static let icon: UInt32 = 0x0101_0002
    static let name: UInt32 = 0x0101_0003
    static let versionCode: UInt32 = 0x0101_021B
    static let versionName: UInt32 = 0x0101_021C
    static let minSdkVersion: UInt32 = 0x0101_020C
    static let targetSdkVersion: UInt32 = 0x0101_0270

    static func read(_ url: URL) throws -> AppPackage {
        guard let manifest = try ArchiveListing.data(ofEntry: "AndroidManifest.xml", in: url) else {
            throw AppPackageError.noApplication
        }
        let events = try AndroidBinaryXML.parse(manifest)
        let resources = try? ArchiveListing.data(ofEntry: "resources.arsc", in: url, maxBytes: 64 * 1024 * 1024)
            .flatMap { try ResourceTable.parse($0) }

        func value(_ attributes: [AndroidBinaryXML.Attribute], _ id: UInt32, _ fallbackName: String) -> AndroidBinaryXML.Value? {
            (attributes.first { $0.resourceID == id } ?? attributes.first { $0.name == fallbackName })?.value
        }
        func text(_ value: AndroidBinaryXML.Value?) -> String? {
            switch value {
            case .string(let string): string
            case .integer(let number): String(number)
            case .reference(let id): resources?.string(for: id)
            default: nil
            }
        }

        var package = AppPackage(platform: .android, name: "")
        var applicationLabel: String?
        var iconReference: UInt32?
        var activity: (label: String?, isLauncher: Bool)?
        var launcherLabel: String?
        for event in events {
            switch event {
            case .start(let element, let attributes):
                switch element {
                case "manifest":
                    package.identifier = text(attributes.first { $0.name == "package" }?.value)
                    package.build = text(value(attributes, versionCode, "versionCode"))
                    package.version = text(value(attributes, versionName, "versionName"))
                case "uses-sdk":
                    package.minimumOS = text(value(attributes, minSdkVersion, "minSdkVersion")).map(versionName(apiText:))
                    package.targetOS = text(value(attributes, targetSdkVersion, "targetSdkVersion")).map(versionName(apiText:))
                case "uses-permission", "uses-permission-sdk-23":
                    if let permission = text(value(attributes, name, "name")) { package.permissions.append(permission) }
                case "application":
                    applicationLabel = text(value(attributes, label, "label"))
                    if case .reference(let id) = value(attributes, icon, "icon") { iconReference = id }
                case "activity", "activity-alias":
                    activity = (text(value(attributes, label, "label")), false)
                case "category" where text(value(attributes, name, "name")) == "android.intent.category.LAUNCHER":
                    // The activity shown in the launcher; its label names apps that set none of their own.
                    activity?.isLauncher = true
                default:
                    break
                }
            case .end(let element):
                if element == "activity" || element == "activity-alias" {
                    if let current = activity, current.isLauncher, launcherLabel == nil { launcherLabel = current.label }
                    activity = nil
                }
            }
        }
        package.name = applicationLabel ?? launcherLabel ?? package.identifier ?? url.deletingPathExtension().lastPathComponent

        let listing = try? ArchiveListing.read(url: url, maxEntries: 200_000, timeLimit: 2)
        let paths = listing?.entries.map(\.path) ?? []
        package.nativeABIs = Array(Set(paths.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            return parts.count >= 3 && parts[0] == "lib" ? String(parts[1]) : nil
        })).sorted()
        // Manifests sometimes repeat a permission; uses-permission-sdk-23 entries are included, as aapt lists them.
        package.permissions = Array(Set(package.permissions)).sorted()

        if let iconReference {
            // Highest-density bitmap; adaptive icons (XML) fall back to the launcher PNGs by name.
            let files = resources?.files(for: iconReference) ?? []
            var best = files.filter { $0.path.lowercased().hasSuffix(".png") || $0.path.lowercased().hasSuffix(".webp") }
                .max { $0.density < $1.density }?.path
            if best == nil, let xml = files.first?.path {
                let stem = (xml as NSString).lastPathComponent.replacingOccurrences(of: ".xml", with: "")
                let sizes = Dictionary((listing?.entries ?? []).map { ($0.path, $0.size ?? 0) }, uniquingKeysWith: max)
                best = paths.filter { $0.hasPrefix("res/") && ($0 as NSString).lastPathComponent.hasPrefix(stem) && $0.hasSuffix(".png") }
                    .max { (sizes[$0] ?? 0) < (sizes[$1] ?? 0) }
            }
            if let best { package.iconData = try ArchiveListing.data(ofEntry: best, in: url) }
        }
        return package
    }

    static func versionName(apiText: String) -> String {
        Int(apiText).map { versionName(apiLevel: $0) } ?? apiText
    }

    static func versionName(apiLevel: Int) -> String {
        let versions = [
            1: "1.0", 2: "1.1", 3: "1.5", 4: "1.6", 5: "2.0", 6: "2.0.1", 7: "2.1", 8: "2.2", 9: "2.3", 10: "2.3.3",
            11: "3.0", 12: "3.1", 13: "3.2", 14: "4.0", 15: "4.0.3", 16: "4.1", 17: "4.2", 18: "4.3", 19: "4.4",
            20: "4.4W", 21: "5.0", 22: "5.1", 23: "6.0", 24: "7.0", 25: "7.1", 26: "8.0", 27: "8.1", 28: "9",
            29: "10", 30: "11", 31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16",
        ]
        return versions[apiLevel].map { "Android \($0) (API \(apiLevel))" } ?? "API \(apiLevel)"
    }
}
