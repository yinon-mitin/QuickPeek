// Renders an SVG to a transparent PNG with WebKit (which supports the SVG filters and
// gradients the icon uses). Usage: swift script/render_svg.swift input.svg output.png size
import AppKit
import WebKit

let arguments = CommandLine.arguments
guard arguments.count == 4, let size = Int(arguments[3]) else {
    FileHandle.standardError.write(Data("usage: render_svg.swift input.svg output.png size\n".utf8))
    exit(2)
}
let svg = try String(contentsOfFile: arguments[1], encoding: .utf8)
let output = URL(fileURLWithPath: arguments[2])

final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    let output: URL
    let size: Int

    init(svg: String, size: Int, output: URL) {
        self.output = output
        self.size = size
        let frame = NSRect(x: 0, y: 0, width: size, height: size)
        webView = WKWebView(frame: frame)
        webView.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        let html = """
        <html><head><style>html,body{margin:0;background:transparent}svg{width:\(size)px;height:\(size)px;display:block}</style></head>
        <body>\(svg)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: size) // points; scaled to pixels below
        webView.takeSnapshot(with: configuration) { image, error in
            guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                FileHandle.standardError.write(Data("snapshot failed: \(String(describing: error))\n".utf8))
                exit(1)
            }
            // Redraw at exactly size × size pixels regardless of the screen's backing scale.
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: self.size, pixelsHigh: self.size, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            NSGraphicsContext.current?.cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: self.size, height: self.size))
            NSGraphicsContext.restoreGraphicsState()
            try! rep.representation(using: .png, properties: [:])!.write(to: self.output)
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer(svg: svg, size: size, output: output)
renderer.window.orderFront(nil)
app.run()
