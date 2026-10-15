import AppKit
import PDFKit
import QuickPeekFormats
import QuickPeekText
import SwiftUI

/// The selected file of an archive, read into memory and shown next to the tree: text and code
/// as in a regular preview, images, PDFs; anything else is named with the reason it is not shown.
struct ArchiveEntryPane: View {
    let node: FileTreeNode?
    let entry: ArchiveEntry?
    let archive: URL
    let services: TextServices
    @State private var peek: (id: String, result: ArchivePeek)?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: node?.id) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let node {
            if node.isDirectory {
                let files = node.fileCount == 1 ? "1 file" : "\(node.fileCount.formatted()) files"
                ContentUnavailableView(node.name, systemImage: "folder",
                                       description: Text("\(files) · \(Format.bytes(node.size ?? 0))"))
            } else if let target = node.linkTarget {
                ContentUnavailableView(node.name, systemImage: "arrow.turn.up.right", description: Text("Link to \(target)"))
            } else if let peek, peek.id == node.id {
                result(peek.result, node: node).id(node.id)
            } else {
                ProgressView()
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "eye", description: Text("Select a file to preview it."))
        }
    }

    @ViewBuilder private func result(_ peek: ArchivePeek, node: FileTreeNode) -> some View {
        switch peek {
        case .text(let document):
            HostedView { DocumentViews.view(for: document, services: services) }
        case .image(let data):
            if let image = NSImage(data: data) {
                VStack(spacing: 8) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    Text(Self.pixelSize(image) ?? node.name).font(.callout).foregroundStyle(.secondary)
                }
                .padding(16)
            } else {
                unavailable(node, "The image could not be decoded.")
            }
        case .pdf(let data):
            if let document = PDFDocument(data: data) {
                HostedView {
                    let view = PDFView()
                    view.document = document
                    view.autoScales = true
                    return view
                }
            } else {
                unavailable(node, "The PDF could not be opened.")
            }
        case .unavailable(let reason):
            unavailable(node, Self.describe(reason))
        }
    }

    private func unavailable(_ node: FileTreeNode, _ text: String) -> some View {
        ContentUnavailableView(node.name, systemImage: FileTreeTable.symbol(for: node), description: Text(text))
    }

    private func load() async {
        guard let node, !node.isDirectory, node.linkTarget == nil else { return }
        guard let entry else {
            peek = (node.id, .unavailable(.unreadable))
            return
        }
        let archive = archive
        let result = await Task.detached(priority: .userInitiated) { ArchivePeek.read(entry, in: archive) }.value
        guard !Task.isCancelled else { return }
        peek = (node.id, result)
    }

    static func describe(_ reason: ArchivePeek.Reason) -> String {
        switch reason {
        case .encrypted: "Encrypted. A password is needed to read it."
        case .tooLarge(let size): "Too large to preview inside the archive (\(Format.bytes(size)))."
        case .media: "Audio and video are not played from inside an archive."
        case .binary: "No preview for this kind of file."
        case .unreadable: "The file could not be read from the archive."
        }
    }

    /// Pixel dimensions, which `NSImage.size` (in points) does not give.
    private static func pixelSize(_ image: NSImage) -> String? {
        guard let rep = image.representations.first, rep.pixelsWide > 0 else { return nil }
        return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
    }
}

/// An AppKit view made once and kept: the text views and PDFView have their own scrolling and state.
private struct HostedView: NSViewRepresentable {
    let make: @MainActor () -> NSView

    func makeNSView(context: Context) -> NSView { make() }
    func updateNSView(_ view: NSView, context: Context) {}
}
