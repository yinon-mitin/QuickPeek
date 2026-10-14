import Cocoa
import FinderSync
import QuickPeekInfo

/// Adds "QuickPeek Info" to Finder's context menu: the technical details of the selected file,
/// one line per value. Choosing a line copies its value; "Copy All Details" copies everything.
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
        let (menu, values) = InfoMenu.build(info, action: #selector(copyValue(_:)), target: self)
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
