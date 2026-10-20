import CryptoKit
import Foundation

public enum TorrentError: Error, Equatable {
    case missingInfo
}

/// The metadata of a .torrent file (BitTorrent v1, v2 and hybrid).
public struct Torrent: Sendable {
    public struct File: Sendable, Equatable {
        public var path: [String]
        public var length: Int64
    }

    public let name: String
    public let files: [File]
    public let totalLength: Int64
    public let pieceLength: Int64
    public let pieceCount: Int
    public let trackers: [String]
    public let webSeeds: [String]
    public let comment: String?
    public let createdBy: String?
    public let creationDate: Date?
    public let isPrivate: Bool
    /// SHA-1 of the info dictionary (v1 and hybrid torrents), as lowercase hex.
    public let infoHash: String
    /// SHA-256 of the info dictionary, present for v2 and hybrid torrents.
    public let infoHashV2: String?

    public init(data: Data) throws {
        let root = try Bencode.decode(data)
        guard let info = root["info"], info.dictionary != nil,
              let infoBytes = try Bencode.rawValue(forKey: "info", in: data) else {
            throw TorrentError.missingInfo
        }

        name = (info["name.utf-8"] ?? info["name"])?.text ?? "Untitled"
        pieceLength = info["piece length"]?.integer ?? 0
        isPrivate = info["private"]?.integer == 1
        comment = (root["comment.utf-8"] ?? root["comment"])?.text
        createdBy = root["created by"]?.text
        creationDate = root["creation date"]?.integer.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        let isVersion2 = info["meta version"]?.integer == 2
        if let fileList = info["files"]?.list {
            files = fileList.map { entry in
                let path = (entry["path.utf-8"] ?? entry["path"])?.list?.compactMap(\.text) ?? []
                return File(path: path, length: entry["length"]?.integer ?? 0)
            }
        } else if isVersion2, let tree = info["file tree"] {
            files = Self.files(in: tree, prefix: []).sorted { $0.path.lexicographicallyPrecedes($1.path) }
        } else {
            files = [File(path: [name], length: info["length"]?.integer ?? 0)]
        }
        totalLength = files.reduce(0) { $0.addingClamped($1.length) }

        if let pieces = info["pieces"]?.bytes {
            pieceCount = pieces.count / 20
        } else if pieceLength > 0 {
            pieceCount = Int(totalLength / pieceLength + (totalLength % pieceLength > 0 ? 1 : 0))
        } else {
            pieceCount = 0
        }

        var trackers: [String] = []
        let tiers = root["announce-list"]?.list?.compactMap(\.list) ?? []
        for url in [root["announce"]?.text].compactMap({ $0 }) + tiers.flatMap({ $0.compactMap(\.text) })
            where !trackers.contains(url) {
            trackers.append(url)
        }
        self.trackers = trackers
        if let seeds = root["url-list"]?.list {
            webSeeds = seeds.compactMap(\.text)
        } else {
            webSeeds = root["url-list"]?.text.map { [$0] } ?? []
        }

        infoHash = Insecure.SHA1.hash(data: infoBytes).map { String(format: "%02x", $0) }.joined()
        infoHashV2 = isVersion2 ? SHA256.hash(data: infoBytes).map { String(format: "%02x", $0) }.joined() : nil
    }

    /// A magnet link that opens the same torrent. Trackers of private torrents are left out:
    /// their URLs usually contain a personal passkey that should not travel with a shared link.
    public var magnetLink: String {
        var components = ["xt=urn:btih:\(infoHash)"]
        if let infoHashV2 {
            components.append("xt=urn:btmh:1220\(infoHashV2)")
        }
        components.append("dn=\(Self.escape(name))")
        if !isPrivate {
            components += trackers.map { "tr=\(Self.escape($0))" }
        }
        return "magnet:?" + components.joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// v2 "file tree": nested dictionaries keyed by path component; a file is a dictionary
    /// with an empty-string key holding its length.
    private static func files(in tree: Bencode, prefix: [String]) -> [File] {
        guard let entries = tree.dictionary else { return [] }
        var result: [File] = []
        for (component, node) in entries {
            if component.isEmpty {
                result.append(File(path: prefix, length: node["length"]?.integer ?? 0))
            } else {
                result += files(in: node, prefix: prefix + [component])
            }
        }
        return result
    }
}
