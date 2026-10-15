import AppKit
import QuickPeekMedia

/// `--play` opens the Quick Look player in a regular window; `--play-snapshot` plays for a moment
/// and saves what the window shows — a way to check the player without Finder.
@MainActor
enum PlayerWindow {
    nonisolated static func run(_ input: URL, snapshotTo output: URL?) -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(output == nil ? .regular : .prohibited)

            let player: MediaPlayer
            do {
                player = try MediaPlayer(url: input)
            } catch {
                Main.fail("\(input.path): \(error)")
            }
            if output != nil { player.isMuted = true }

            let size = PreviewGeometry.fit(player.videoSize ?? CGSize(width: 480, height: 270), in: CGSize(width: 960, height: 540), allowUpscale: true)
            let window = NSWindow(
                contentRect: NSRect(origin: output == nil ? .zero : CGPoint(x: -10_000, y: -10_000), size: size),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = input.lastPathComponent
            let view = PlayerView(player: player)
            window.contentView = view
            if output == nil { window.center() }
            window.makeKeyAndOrderFront(nil)
            view.start()
            objc_setAssociatedObject(app, "playerWindow", window, .OBJC_ASSOCIATION_RETAIN)

            if let output {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    MainActor.assumeIsolated {
                        player.pause()
                        guard let png = view.snapshot()?.representation(using: .png, properties: [:]) else {
                            Main.fail("snapshot failed")
                        }
                        do { try png.write(to: output) } catch { Main.fail("\(error)") }
                        exit(0)
                    }
                }
            } else {
                app.activate()
            }
            app.run()
        }
        exit(0)
    }
}
