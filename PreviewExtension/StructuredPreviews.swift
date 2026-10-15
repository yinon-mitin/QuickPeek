import AppKit
import QuickPeekFormats
import QuickPeekInfo
import QuickPeekText
import SwiftUI

/// Native previews for files whose content is a list: archives and torrents.
enum StructuredPreview {
    static let archiveExtensions: Set<String> = [
        "zip", "jar", "tar", "tgz", "gz", "tbz", "tbz2", "bz2", "txz", "xz", "lzma", "z",
        "rar", "7z", "iso", "cpio", "xar", "cab", "lha", "lzh",
    ]

    static func handles(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return isFolder(url) || ext == "torrent" || archiveExtensions.contains(ext) || AppPackagePreview.extensions.contains(ext)
            || SQLitePreview.extensions.contains(ext)
    }

    /// Two-pane previews (a database, an archive with a file preview) get a wider window, an
    /// empty folder a small one.
    static func preferredSize(for url: URL) -> NSSize {
        let ext = url.pathExtension.lowercased()
        if isFolder(url) {
            let visible = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            return visible?.isEmpty == true ? NSSize(width: 480, height: 110) : NSSize(width: 760, height: 560)
        }
        let twoPanes = SQLitePreview.extensions.contains(ext) || archiveExtensions.contains(ext)
        return twoPanes ? NSSize(width: 1000, height: 620) : NSSize(width: 760, height: 560)
    }

    /// A plain folder, not a package such as an app or an Xcode archive.
    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// Parses the file and returns the view to host, or throws if it cannot be read at all.
    @MainActor
    static func view(for url: URL, services: TextServices) throws -> NSView {
        if isFolder(url) {
            let listing = try FolderListing.read(url: url)
            return NSHostingView(rootView: FolderPreview(name: FileManager.default.displayName(atPath: url.path), listing: listing))
        }
        if SQLitePreview.extensions.contains(url.pathExtension.lowercased()) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            return NSHostingView(rootView: SQLitePreview(fileName: url.lastPathComponent, fileSize: size, database: try SQLiteDatabase(url: url)))
        }
        if AppPackagePreview.extensions.contains(url.pathExtension.lowercased()) {
            let package = try AppPackage.read(url: url)
            return NSHostingView(rootView: AppPackagePreview(package: package, info: FileInfoReader.read(url)))
        }
        if url.pathExtension.lowercased() == "torrent" {
            let torrent = try Torrent(data: Data(contentsOf: url, options: .mappedIfSafe))
            return NSHostingView(rootView: TorrentPreview(torrent: torrent, tree: FileTree.openingSingleFolder(FileTree.build(torrent)).nodes))
        }
        let listing = try ArchiveListing.read(url: url)
        let (folder, nodes) = FileTree.openingSingleFolder(FileTree.build(listing))
        return NSHostingView(rootView: ArchivePreview(fileName: url.lastPathComponent, archive: url, listing: listing,
                                                      tree: nodes, folder: folder, services: services))
    }
}

// MARK: - Archive

struct ArchivePreview: View {
    let fileName: String
    let archive: URL
    let listing: ArchiveListing
    let tree: [FileTreeNode]
    /// The single top-level folder whose contents are shown, if there was one.
    var folder: String?
    let services: TextServices
    private let nodes: [String: FileTreeNode]
    private let entries: [String: ArchiveEntry]
    @State private var selection: String?

    init(fileName: String, archive: URL, listing: ArchiveListing, tree: [FileTreeNode], folder: String?, services: TextServices) {
        self.fileName = fileName
        self.archive = archive
        self.listing = listing
        self.tree = tree
        self.folder = folder
        self.services = services
        var nodes: [String: FileTreeNode] = [:]
        func add(_ level: [FileTreeNode]) {
            for node in level {
                nodes[node.id] = node
                add(node.children ?? [])
            }
        }
        add(tree)
        self.nodes = nodes
        entries = Dictionary(listing.entries.map { (FileTree.id(forPath: $0.path), $0) }, uniquingKeysWith: { first, _ in first })
        _selection = State(initialValue: Self.firstSelection(tree))
    }

    /// A lone file (a .gz) or a README at the top is shown right away, as on GitHub.
    private static func firstSelection(_ tree: [FileTreeNode]) -> String? {
        if tree.count == 1, let only = tree.first, !only.isDirectory { return only.id }
        let readmes = ["readme.md", "readme", "readme.txt", "readme.markdown"]
        return tree.first { !$0.isDirectory && readmes.contains($0.name.lowercased()) }?.id
    }

    private var summary: String {
        var parts = [listing.compression.map { "\(listing.format) · \($0)" } ?? listing.format]
        if listing.entries.isEmpty && listing.isEncrypted {
            parts.append("Encrypted")
        } else {
            let files = listing.entries.filter { $0.kind != .directory }.count
            parts.append(files == 1 ? "1 file" : "\(files.formatted()) files")
            parts.append(Format.bytes(listing.totalSize))
        }
        if let folder { parts.append("in \(folder)/") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewHeader(symbol: listing.isEncrypted ? "lock.doc" : "archivebox", title: fileName, subtitle: summary)
            if listing.isEncrypted {
                Banner(symbol: "lock.fill", text: listing.entries.isEmpty
                    ? "File names are encrypted. A password is needed to see the contents."
                    : "Some files are encrypted.")
            }
            if listing.isTruncated {
                Banner(symbol: "ellipsis.circle", text: "Showing the first \(listing.entries.count.formatted()) entries.")
            } else if let problem = listing.problem, !listing.isEncrypted {
                Banner(symbol: "exclamationmark.triangle", text: "The archive could not be read to the end: \(problem)")
            }
            if tree.isEmpty {
                Spacer()
            } else {
                HSplitView {
                    FileTreeTable(nodes: tree, showsDates: true, selection: $selection)
                        .frame(minWidth: 400, idealWidth: 520)
                    ArchiveEntryPane(node: selection.flatMap { nodes[$0] }, entry: selection.flatMap { entries[$0] },
                                     archive: archive, services: services)
                        .frame(minWidth: 300, idealWidth: 480, maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Folder

struct FolderPreview: View {
    let name: String
    let listing: FolderListing
    let tree: [FileTreeNode]

    init(name: String, listing: FolderListing) {
        self.name = name
        self.listing = listing
        tree = FileTree.build(listing.items)
    }

    private var summary: String {
        if tree.isEmpty { return "Empty folder" }
        let files = listing.fileCount.formatted() + (listing.isTruncated ? "+" : "")
        return [listing.fileCount == 1 ? "1 file" : "\(files) files", Format.bytes(listing.totalSize)].joined(separator: " · ")
    }

    var body: some View {
        // An empty folder is just the header, in a window sized for it (see `preferredSize`).
        VStack(alignment: .leading, spacing: 0) {
            PreviewHeader(symbol: "folder", title: name, subtitle: summary)
            if listing.isTruncated {
                Banner(symbol: "ellipsis.circle", text: "Showing the first \(listing.items.count.formatted()) items.")
            }
            if !tree.isEmpty {
                FileTreeTable(nodes: tree, showsDates: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Torrent

struct TorrentPreview: View {
    let torrent: Torrent
    let tree: [FileTreeNode]
    @State private var copied = false

    private var summary: String {
        let files = torrent.files.count
        var parts = ["Torrent", files == 1 ? "1 file" : "\(files.formatted()) files", Format.bytes(torrent.totalLength)]
        if torrent.isPrivate { parts.append("Private") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewHeader(symbol: "arrow.down.circle", title: torrent.name, subtitle: summary) {
                Button(copied ? "Copied" : "Copy Magnet Link", systemImage: copied ? "checkmark" : "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(torrent.magnetLink, forType: .string)
                    copied = true
                }
            }
            details
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            FileTreeTable(nodes: tree, showsDates: false)
        }
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Info hash", torrent.infoHash, monospaced: true)
            if let v2 = torrent.infoHashV2 { row("Info hash v2", v2, monospaced: true) }
            if torrent.pieceCount > 0 {
                row("Pieces", "\(torrent.pieceCount.formatted()) × \(Format.binaryBytes(torrent.pieceLength))")
            }
            if let date = torrent.creationDate {
                row("Created", date.formatted(date: .abbreviated, time: .shortened) + (torrent.createdBy.map { " by \($0)" } ?? ""))
            } else if let createdBy = torrent.createdBy {
                row("Created by", createdBy)
            }
            if let comment = torrent.comment, !comment.isEmpty { row("Comment", comment) }
            if !torrent.trackers.isEmpty {
                row(torrent.trackers.count == 1 ? "Tracker" : "Trackers", torrent.trackers.prefix(4).joined(separator: "\n")
                    + (torrent.trackers.count > 4 ? "\n+ \(torrent.trackers.count - 4) more" : ""))
            }
            if !torrent.webSeeds.isEmpty { row("Web seeds", torrent.webSeeds.joined(separator: "\n")) }
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .lineLimit(5)
        }
    }
}

// MARK: - Shared pieces

struct PreviewHeader<Accessory: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: () -> Accessory

    init(symbol: String, title: String, subtitle: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(20)
    }
}

struct Banner: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.15), in: .rect(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
    }
}

struct FileTreeTable: View {
    let nodes: [FileTreeNode]
    let showsDates: Bool
    /// Rows are selectable only where a selection shows something (an archive's file preview);
    /// elsewhere a click must not highlight a row that leads nowhere.
    var selection: Binding<String?>?
    @State private var expanded: Set<String>
    private let levels: [[String]]

    init(nodes: [FileTreeNode], showsDates: Bool, selection: Binding<String?>? = nil) {
        self.nodes = nodes
        self.showsDates = showsDates
        self.selection = selection
        // The outline opens a folder only after its parent's rows are loaded, so the top level
        // opens with the table and each deeper level a moment later (see `body`).
        let opened = FileTree.initiallyExpanded(nodes)
        levels = Dictionary(grouping: opened) { $0.split(separator: "/").count }.sorted { $0.key < $1.key }.map(\.value)
        _expanded = State(initialValue: Set(levels.first ?? []))
    }

    var body: some View {
        Group {
            if let selection {
                Table(of: FileTreeNode.self, selection: selection) { columns } rows: { FileTreeRows(nodes: nodes, expanded: $expanded) }
            } else {
                Table(of: FileTreeNode.self) { columns } rows: { FileTreeRows(nodes: nodes, expanded: $expanded) }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .task {
            for level in levels.dropFirst() {
                try? await Task.sleep(for: .milliseconds(10))
                expanded.formUnion(level)
            }
        }
    }

    @TableColumnBuilder<FileTreeNode, Never> private var columns: some TableColumnContent<FileTreeNode, Never> {
        TableColumn("Name") { node in
            Label {
                Text(node.name).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: Self.symbol(for: node)).foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
            }
            .help(node.linkTarget.map { "\(node.id) → \($0)" } ?? node.id)
        }
        .width(min: 160, ideal: 220)
        TableColumn("Size") { node in
            Text(node.size.map(Format.bytes) ?? "—").monospacedDigit().foregroundStyle(.secondary)
        }
        .width(min: 70, ideal: 90, max: 120)
        if showsDates {
            TableColumn("Modified") { node in
                Text(node.modified?.formatted(date: .abbreviated, time: .shortened) ?? "").foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150, max: 200)
        }
    }

    static func symbol(for node: FileTreeNode) -> String {
        if node.isDirectory { return "folder.fill" }
        if node.isEncrypted { return "lock.doc" }
        if node.linkTarget != nil { return "arrow.turn.up.right" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp", "svg", "arw", "cr2", "nef", "dng": return "photo"
        case "mp4", "mov", "mkv", "webm", "avi", "m4v": return "film"
        case "mp3", "m4a", "flac", "wav", "aac", "opus", "ogg": return "music.note"
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz": return "archivebox"
        case "pdf": return "doc.richtext"
        case "txt", "md", "rtf", "log", "csv", "json", "yaml", "yml", "xml": return "doc.text"
        case "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "java", "kt", "rb", "sh": return "chevron.left.forwardslash.chevron.right"
        case "app", "exe", "dmg", "pkg", "msi", "apk", "ipa": return "app.badge"
        default: return "doc"
        }
    }
}

/// Outline rows whose folders open and close through `expanded`, so a preview can start with
/// them open (`Table(_:children:)` always starts collapsed).
struct FileTreeRows: TableRowContent {
    let nodes: [FileTreeNode]
    let expanded: Binding<Set<String>>

    var tableRowBody: some TableRowContent<FileTreeNode> {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureTableRow(node, isExpanded: isExpanded(node.id)) {
                    FileTreeRows(nodes: children, expanded: expanded)
                }
            } else {
                TableRow(node)
            }
        }
    }

    private func isExpanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.wrappedValue.contains(id) },
            set: { open in
                if open { expanded.wrappedValue.insert(id) } else { expanded.wrappedValue.remove(id) }
            }
        )
    }
}

enum Format {
    /// File sizes as Finder shows them (decimal units).
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Power-of-two sizes such as torrent pieces (256 KB, not 262 KB).
    static func binaryBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .memory)
    }
}
