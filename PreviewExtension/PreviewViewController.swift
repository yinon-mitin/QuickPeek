import Cocoa
import Quartz
import QuickPeekCore
import WebKit

/// Quick Look preview: renders the file to HTML with QuickPeekCore and shows it in a WKWebView,
/// so highlight.js and markdown-it can run (data-based HTML previews have JavaScript disabled).
final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    private static let assets: PreviewAssets = {
        let vendor = Bundle.main.resourceURL!.appendingPathComponent("Vendor", isDirectory: true)
        return (try? PreviewAssets.load(from: vendor)) ?? PreviewAssets(styles: [], scripts: [])
    }()

    private let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        return webView
    }()

    private var loadFinished: CheckedContinuation<Void, Never>?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        webView.navigationDelegate = self
        view = webView
        preferredContentSize = NSSize(width: 900, height: 700)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let html = try PreviewPipeline.html(for: url, assets: Self.assets)
        // Return only once the page is drawn, so Quick Look never shows an empty white frame.
        await withCheckedContinuation { continuation in
            loadFinished = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
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
