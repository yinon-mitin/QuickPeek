import AppKit
import QuickPeekFormats
import SwiftUI

/// Native previews for files whose content is a list: archives and torrents.
enum StructuredPreview {
    static let archiveExtensions: Set<String> = [
        "zip", "jar", "tar", "tgz", "gz", "tbz", "tbz2", "bz2", "txz", "xz", "lzma", "z",
        "rar", "7z", "iso", "cpio", "xar", "cab", "lha", "lzh",
    ]

    static func handles(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "torrent" || archiveExtensions.contains(ext)
    }

    /// Parses the file and returns the view to host, or throws if it cannot be read at all.
    @MainActor
    static func view(for url: URL) throws -> NSView {
        if url.pathExtension.lowercased() == "torrent" {
            let torrent = try Torrent(data: Data(contentsOf: url, options: .mappedIfSafe))
            return NSHostingView(rootView: TorrentPreview(torrent: torrent, tree: FileTree.build(torrent)))
        }
        let listing = try ArchiveListing.read(url: url)
        return NSHostingView(rootView: ArchivePreview(fileName: url.lastPathComponent, listing: listing, tree: FileTree.build(listing)))
    }
}

// MARK: - Archive

struct ArchivePreview: View {
    let fileName: String
    let listing: ArchiveListing
    let tree: [FileTreeNode]

    private var summary: String {
        var parts = [listing.compression.map { "\(listing.format) · \($0)" } ?? listing.format]
        if listing.entries.isEmpty && listing.isEncrypted {
            parts.append("Encrypted")
        } else {
            let files = listing.entries.filter { $0.kind != .directory }.count
            parts.append(files == 1 ? "1 file" : "\(files.formatted()) files")
            parts.append(Format.bytes(listing.totalSize))
        }
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
                FileTreeTable(nodes: tree, showsDates: true)
            }
        }
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

    var body: some View {
        Table(nodes, children: \.children) {
            TableColumn("Name") { node in
                Label {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: Self.symbol(for: node)).foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                }
                .help(node.linkTarget.map { "\(node.id) → \($0)" } ?? node.id)
            }
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
        .tableStyle(.inset(alternatesRowBackgrounds: true))
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
