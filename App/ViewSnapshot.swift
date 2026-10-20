import AppKit

/// Renders a preview view in an off-screen window and saves it as a PNG — `--snapshot` for
/// previews that are native views rather than HTML.
@MainActor
enum ViewSnapshot {
    nonisolated static func run(output: URL, dark: Bool, size: NSSize, makeView: @MainActor @escaping () async throws -> NSView) -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            // The view may load its content asynchronously (archives are read off the main thread).
            Task { @MainActor in
                let view: NSView
                do {
                    view = try await makeView()
                } catch {
                    Main.fail("\(error)")
                }
                let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.backgroundColor = .windowBackgroundColor
                // cacheDisplay skips the window background, so draw it in a container behind the view.
                let container = BackgroundView(frame: NSRect(origin: .zero, size: size))
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
                window.contentView = container
                window.orderFront(nil)

                // Let SwiftUI lay out, tables load rows and the background highlighter finish.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    MainActor.assumeIsolated {
                        container.layoutSubtreeIfNeeded()
                        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { Main.fail("snapshot failed") }
                        container.cacheDisplay(in: container.bounds, to: rep)
                        do {
                            try rep.representation(using: .png, properties: [:])?.write(to: output)
                        } catch {
                            Main.fail("\(error)")
                        }
                        exit(0)
                    }
                }
            }
            app.run()
        }
        exit(0)
    }
}

private final class BackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
