import Cocoa
import OSLog
import Quartz
import QuickPeekCore
import QuickPeekFormats
import QuickPeekMedia
import QuickPeekText

/// Quick Look preview entry point. Every preview is a native view: the Matroska player,
/// SwiftUI lists for archives and torrents, and TextKit for code, Markdown and tables.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private static let matroskaExtensions: Set<String> = ["mkv", "mka", "mk3d", "webm"]

    /// Failures show up in Console.app under this subsystem.
    private static let log = Logger(subsystem: "io.github.yinon-mitin.QuickPeek", category: "preview")

    private var playerView: PlayerView?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        playerView?.stop()
    }

    func preparePreviewOfFile(at url: URL) async throws {
        do {
            try preparePreview(url)
        } catch {
            Self.log.error("Preview of \(url.pathExtension, privacy: .public) file failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func preparePreview(_ url: URL) throws {
        defer { InfoButton.attach(to: view, fileURL: url) }
        if Self.matroskaExtensions.contains(url.pathExtension.lowercased()) {
            try showPlayer(for: url)
        } else if StructuredPreview.handles(url) {
            install(try StructuredPreview.view(for: url))
            preferredContentSize = NSSize(width: 760, height: 560)
        } else {
            install(DocumentViews.view(for: try TextDocument.load(url), services: TextPreview.services))
            preferredContentSize = NSSize(width: 900, height: 700)
        }
    }

    private func showPlayer(for url: URL) throws {
        let player = try MediaPlayer(url: url)
        let playerView = PlayerView(player: player)
        install(playerView)
        self.playerView = playerView

        if let size = player.videoSize {
            preferredContentSize = PreviewGeometry.fit(size, in: CGSize(width: 1280, height: 800))
        } else {
            preferredContentSize = CGSize(width: 480, height: 270)
        }
        playerView.start()
    }

    private func install(_ content: NSView) {
        content.frame = view.bounds
        content.autoresizingMask = [.width, .height]
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(content)
    }
}

enum TextPreview {
    /// One highlighter per process: loading highlight.js takes a moment, previews reuse it.
    static let services = TextServices(vendorDirectory: Bundle.main.resourceURL!.appendingPathComponent("Vendor", isDirectory: true))
}
