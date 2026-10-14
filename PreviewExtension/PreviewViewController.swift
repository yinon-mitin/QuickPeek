import Cocoa
import Quartz
import QuickPeekCore
import QuickPeekMedia
import WebKit

/// Quick Look preview entry point. Matroska/WebM goes to the native player; text formats are
/// rendered to HTML by QuickPeekCore and shown in a WKWebView, created only when needed so a
/// video preview never starts a WebKit process.
final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    private static let assets: PreviewAssets = {
        let vendor = Bundle.main.resourceURL!.appendingPathComponent("Vendor", isDirectory: true)
        return (try? PreviewAssets.load(from: vendor)) ?? PreviewAssets(styles: [], scripts: [])
    }()

    private static let matroskaExtensions: Set<String> = ["mkv", "mka", "mk3d", "webm"]

    private var playerView: PlayerView?
    private var loadFinished: CheckedContinuation<Void, Never>?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        playerView?.stop()
    }

    func preparePreviewOfFile(at url: URL) async throws {
        if Self.matroskaExtensions.contains(url.pathExtension.lowercased()) {
            try showPlayer(for: url)
        } else {
            try await showDocument(url)
        }
    }

    // MARK: - Video

    private func showPlayer(for url: URL) throws {
        let player = try MatroskaPlayer(url: url)
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

    // MARK: - Documents

    private func showDocument(_ url: URL) async throws {
        let html = try PreviewPipeline.html(for: url, assets: Self.assets)
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.navigationDelegate = self
        install(webView)
        preferredContentSize = NSSize(width: 900, height: 700)

        // Return only once the page is drawn, so Quick Look never shows an empty white frame.
        await withCheckedContinuation { continuation in
            loadFinished = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func install(_ content: NSView) {
        content.frame = view.bounds
        content.autoresizingMask = [.width, .height]
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(content)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeLoad()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeLoad()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resumeLoad()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Links in Markdown open in the default browser instead of replacing the preview.
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func resumeLoad() {
        loadFinished?.resume()
        loadFinished = nil
    }
}
