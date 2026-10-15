import Cocoa
import FinderSync
import QuickPeekInfo

/// Adds the selected file's summary to Finder's context menu ("1920×1080 · HEVC · 24 fps · 1:42:05"),
/// with its technical details in a submenu. Choosing a line copies its value.
final class FinderSync: FIFinderSync {
    private var values: [String] = []
    private var report = ""

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let selection = FIFinderSyncController.default().selectedItemURLs(),
              selection.count == 1, let url = selection.first else {
            return nil
        }
        let info = FileInfoReader.read(url, quick: true)
        let (menu, values) = InfoMenu.build(info, action: #selector(copyValue(_:)), target: self,
                                            appearance: NSApplication.shared.effectiveAppearance)
        self.values = values
        report = info.report
        return menu
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        let text = values.indices.contains(sender.tag) ? values[sender.tag] : report
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
