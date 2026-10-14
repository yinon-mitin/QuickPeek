import AppKit
import QuickPeekCore
import WebKit

/// Renders a preview in an off-screen WKWebView and writes it to a PNG, exactly as the
/// extension would display it (same HTML, same scripts, same appearance handling).
@MainActor
final class Snapshotter: NSObject, WKNavigationDelegate {
    private let output: URL
    private let window: NSWindow
    private let webView: WKWebView

    private init(output: URL, dark: Bool) {
        self.output = output
        let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        super.init()
        webView.navigationDelegate = self
    }

    nonisolated static func run(input: URL, output: URL, dark: Bool) -> Never {
        MainActor.assumeIsolated {
            let html: String
            do {
                html = try PreviewPipeline.html(for: input, assets: Main.assets)
            } catch {
                Main.fail("\(input.path): \(error)")
            }

            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let snapshotter = Snapshotter(output: output, dark: dark)
            snapshotter.window.orderFront(nil)
            snapshotter.webView.loadHTMLString(html, baseURL: nil)
            objc_setAssociatedObject(app, "snapshotter", snapshotter, .OBJC_ASSOCIATION_RETAIN)
            app.run()
        }
        exit(0)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.takeSnapshot(with: nil) { image, error in
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else {
                Main.fail("snapshot failed: \(String(describing: error))")
            }
            do {
                try png.write(to: self.output)
                exit(0)
            } catch {
                Main.fail("cannot write \(self.output.path): \(error)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Main.fail("page failed to load: \(error)")
    }
}
