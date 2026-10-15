import AppKit
import AVFoundation
import QuickPeekMedia
import VideoToolbox

/// Minimal native player chrome around `MediaPlayer`: video, a HUD bar that hides while
/// playing, click to play/pause. Space is left to Quick Look, which uses it to close the preview.
@MainActor
final class PlayerView: NSView {
    let player: MediaPlayer

    private let videoHost = NSView()
    private let bar = NSVisualEffectView()
    private let playButton = NSButton()
    private let muteButton = NSButton()
    private let slider = NSSlider()
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "0:00")
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private var isScrubbing = false

    init(player: MediaPlayer) {
        self.player = player
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        videoHost.wantsLayer = true
        videoHost.layer?.addSublayer(player.videoLayer)
        videoHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoHost)

        if !player.hasVideo {
            addPlaceholder(symbol: "waveform", text: player.unsupportedCodecs.isEmpty ? "Audio" : "No native decoder for \(player.unsupportedCodecs.joined(separator: ", "))")
        } else if !player.unsupportedCodecs.isEmpty {
            addBanner("No native decoder for \(player.unsupportedCodecs.joined(separator: ", ")) — playing the rest")
        }

        buildBar()
        NSLayoutConstraint.activate([
            videoHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoHost.topAnchor.constraint(equalTo: topAnchor),
            videoHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        player.onEnd = { [weak self] in
            self?.refresh()
            self?.showBar()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        timer?.invalidate()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        player.videoLayer.frame = videoHost.bounds
        CATransaction.commit()
    }

    func start() {
        player.play()
        refresh()
        scheduleHide()
    }

    func stop() {
        player.pause()
        timer?.invalidate()
    }

    // MARK: - Controls

    private func buildBar() {
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        configure(playButton, symbol: "pause.fill", action: #selector(togglePlayback))
        configure(muteButton, symbol: "speaker.wave.2.fill", action: #selector(toggleMute))
        muteButton.isHidden = !player.hasAudio

        slider.minValue = 0
        slider.maxValue = max(player.duration, 0.01)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(scrubbed)

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
        }

        let stack = NSStackView(views: [playButton, elapsedLabel, slider, remainingLabel, muteButton])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            bar.heightAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    private func configure(_ button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
    }

    @objc private func togglePlayback() {
        player.togglePlayback()
        refresh()
        player.isPlaying ? scheduleHide() : showBar()
    }

    @objc private func toggleMute() {
        player.isMuted.toggle()
        refresh()
    }

    @objc private func scrubbed() {
        isScrubbing = NSApp.currentEvent?.type == .leftMouseDragged
        player.seek(to: slider.doubleValue)
        refresh()
    }

    private func refresh() {
        let time = player.currentTime
        if !isScrubbing { slider.doubleValue = time }
        elapsedLabel.stringValue = Self.format(time)
        remainingLabel.stringValue = "-" + Self.format(max(0, player.duration - time))
        playButton.image = NSImage(systemSymbolName: player.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        muteButton.image = NSImage(systemSymbolName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - Auto-hiding bar

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        showBar()
        scheduleHide()
    }

    override func mouseUp(with event: NSEvent) {
        // A click on the picture (not on the bar) toggles playback, like QuickTime Player.
        if !bar.frame.contains(convert(event.locationInWindow, from: nil)) {
            togglePlayback()
        }
    }

    private func showBar() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; bar.animator().alphaValue = 1 }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.player.isPlaying else { return }
                NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self.bar.animator().alphaValue = 0 }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - Snapshot

    /// The view as it looks on screen: the displayed video frame with the controls on top.
    /// (`cacheDisplay` alone leaves the video black, since AVSampleBufferDisplayLayer draws out of process.)
    func snapshot() -> NSBitmapImageRep? {
        layoutSubtreeIfNeeded()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        if let pixelBuffer = player.displayedFrame() {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
            if let image {
                let size = PreviewGeometry.fit(player.videoSize ?? CGSize(width: image.width, height: image.height), in: bounds.size, allowUpscale: true)
                let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
                context.cgContext.draw(image, in: rect)
            }
        }
        if bar.alphaValue > 0, let barRep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: barRep)
            barRep.draw(in: bar.frame)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - Messages

    private func addPlaceholder(symbol: String, text: String) {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 64, weight: .light)
        image.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [image, label])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
        ])
    }

    private func addBanner(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }
}

enum PreviewGeometry {
    /// Largest size with `size`'s aspect ratio inside `bounds`.
    static func fit(_ size: CGSize, in bounds: CGSize, allowUpscale: Bool = false) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        var scale = min(bounds.width / size.width, bounds.height / size.height)
        if !allowUpscale { scale = min(1, scale) }
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
