import Foundation

/// One path from an archive or torrent, before it is placed in a tree.
public struct FileTreeItem: Sendable {
    public var components: [String]
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?
    public var isEncrypted = false
    public var linkTarget: String?

    public init(path: String, isDirectory: Bool, size: Int64?, modified: Date? = nil,
                isEncrypted: Bool = false, linkTarget: String? = nil) {
        self.init(components: FileTree.components(path), isDirectory: isDirectory, size: size,
                  modified: modified, isEncrypted: isEncrypted, linkTarget: linkTarget)
    }

    public init(components: [String], isDirectory: Bool, size: Int64?, modified: Date? = nil,
                isEncrypted: Bool = false, linkTarget: String? = nil) {
        self.components = components.filter { !$0.isEmpty && $0 != "." } // torrents give components directly
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.isEncrypted = isEncrypted
        self.linkTarget = linkTarget
    }
}

public struct FileTreeNode: Identifiable, Sendable, Equatable {
    /// Full path, unique within the tree.
    public let id: String
    public let name: String
    public let isDirectory: Bool
    /// For folders, the sum of the files inside.
    public let size: Int64?
    public let modified: Date?
    public let isEncrypted: Bool
    public let linkTarget: String?
    /// Number of files inside a folder (recursively); 1 for a file.
    public let fileCount: Int
    /// `nil` for files, so outline views show no disclosure triangle.
    public let children: [FileTreeNode]?
}

public enum FileTree {
    /// The id a path from an archive gets in the tree: `./docs//a.txt` becomes `docs/a.txt`.
    public static func id(forPath path: String) -> String {
        components(path).joined(separator: "/")
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
    }

    public static func build(_ items: [FileTreeItem]) -> [FileTreeNode] {
        let root = Builder(name: "", path: "")
        for item in items where !item.components.isEmpty {
            var node = root
            for (index, component) in item.components.enumerated() {
                let isLast = index == item.components.count - 1
                node = node.child(component, isDirectory: !isLast || item.isDirectory)
                if isLast {
                    node.size = item.isDirectory ? node.size : item.size
                    node.modified = item.modified ?? node.modified
                    node.isEncrypted = item.isEncrypted
                    node.linkTarget = item.linkTarget
                }
            }
        }
        return root.freeze().children ?? []
    }

    /// Archives usually wrap everything in one folder; showing that folder already opened saves
    /// a click on every preview. Returns the folder's name, if one was opened.
    public static func openingSingleFolder(_ roots: [FileTreeNode]) -> (folder: String?, nodes: [FileTreeNode]) {
        guard roots.count == 1, let root = roots.first, let children = root.children else { return (nil, roots) }
        return (root.name, children)
    }

    /// Folders to show already opened: level by level, every folder whose contents still fit in
    /// `rowLimit` visible rows. Small archives open completely; a big one opens its upper levels
    /// and keeps folders that would flood the list closed.
    public static func initiallyExpanded(_ roots: [FileTreeNode], rowLimit: Int = 200) -> Set<String> {
        var expanded: Set<String> = []
        var rows = roots.count
        var level = roots
        while !level.isEmpty {
            var next: [FileTreeNode] = []
            for node in level {
                guard let children = node.children, !children.isEmpty, rows + children.count <= rowLimit else { continue }
                expanded.insert(node.id)
                rows += children.count
                next += children
            }
            level = next
        }
        return expanded
    }

    public static func build(_ listing: ArchiveListing) -> [FileTreeNode] {
        build(listing.entries.map {
            FileTreeItem(path: $0.path, isDirectory: $0.kind == .directory, size: $0.size, modified: $0.modified,
                         isEncrypted: $0.isEncrypted, linkTarget: $0.linkTarget)
        })
    }

    public static func build(_ torrent: Torrent) -> [FileTreeNode] {
        build(torrent.files.map { FileTreeItem(components: $0.path, isDirectory: false, size: $0.length) })
    }

    private final class Builder {
        let name: String
        let path: String
        var isDirectory = true
        var size: Int64?
        var modified: Date?
        var isEncrypted = false
        var linkTarget: String?
        private var children: [String: Builder] = [:]

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func child(_ name: String, isDirectory: Bool) -> Builder {
            if let existing = children[name] {
                existing.isDirectory = existing.isDirectory || isDirectory
                return existing
            }
            let node = Builder(name: name, path: path.isEmpty ? name : path + "/" + name)
            node.isDirectory = isDirectory
            children[name] = node
            return node
        }

        func freeze() -> FileTreeNode {
            guard isDirectory else {
                return FileTreeNode(id: path, name: name, isDirectory: false, size: size, modified: modified,
                                    isEncrypted: isEncrypted, linkTarget: linkTarget, fileCount: 1, children: nil)
            }
            let frozen = children.values.map { $0.freeze() }.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return FileTreeNode(
                id: path, name: name, isDirectory: true,
                size: frozen.reduce(Int64(0)) { $0.addingClamped($1.size ?? 0) },
                modified: modified, isEncrypted: isEncrypted, linkTarget: nil,
                fileCount: frozen.reduce(0) { $0 + $1.fileCount },
                children: frozen
            )
        }
    }
}

extension Int64 {
    /// Sizes come from file headers, which can claim anything: their sum stops at the limit instead of trapping.
    func addingClamped(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }
}
