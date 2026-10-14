import AppKit
import QuickPeekInfo
import SwiftUI

/// The ⓘ panel: every section of a file's details, selectable, with a "Copy All" button.
struct InfoPanel: View {
    let info: FileInfo
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.summary)
                    .font(.headline)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.report, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
            .padding(16)
            Divider()
            ScrollView {
                InfoSectionsView(sections: info.sections)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 440, height: 520)
    }
}

/// Sections of label–value rows; values are selectable. Values flagged "— expired" are red.
struct InfoSectionsView: View {
    let sections: [InfoSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 6) {
                    Label(section.title, systemImage: section.symbol)
                        .font(.subheadline.weight(.semibold))
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            GridRow {
                                Text(item.label)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(item.value)
                                    .foregroundStyle(item.value.hasSuffix("— expired") ? Color.red : Color.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }
}

/// A small ⓘ button pinned to the top-right corner of a preview; it reads the details in the
/// background and shows them in a popover.
@MainActor
final class InfoButton: NSButton {
    private let fileURL: URL
    private let popover = NSPopover()

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        image = NSImage(systemSymbolName: "info", accessibilityDescription: "File details")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        imagePosition = .imageOnly
        isBordered = false
        // White on a translucent dark disc: visible over video, dark mode and light documents alike.
        contentTintColor = .white
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        layer?.cornerRadius = 14
        toolTip = "File details"
        target = self
        action = #selector(toggle)
        popover.behavior = .transient
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Adds the button to the top-right corner of `container`.
    static func attach(to container: NSView, fileURL: URL) {
        let button = InfoButton(fileURL: fileURL)
        button.frame.origin = CGPoint(x: container.bounds.width - 38, y: container.bounds.height - 38)
        button.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(button)
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let url = fileURL
        Task {
            let info = await Task.detached(priority: .userInitiated) { await FileInfoReader.read(url) }.value
            popover.contentViewController = NSHostingController(rootView: InfoPanel(info: info))
            popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        }
    }
}
