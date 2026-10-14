import AppKit
import AVFoundation
import Foundation
import Testing
@testable import QuickPeekMedia

/// GitHub's macOS runners are VMs without a hardware video decoder or an audio device, so
/// presenting frames and reaching the end on the audio clock are only checked on real Macs.
let onRealMac = ProcessInfo.processInfo.environment["CI"] == nil

@Suite("MatroskaPlayer", .serialized)
@MainActor
struct MatroskaPlayerTests {
    private func waitUntil(timeout: Double = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Plays video and audio in sync and shows decoded frames",
          arguments: ["h264_aac.mkv", "hevc_ac3.mkv", "vp9_opus.webm"])
    func plays(file: String) async throws {
        let player = try MatroskaPlayer(url: fixtureURL(file))
        player.isMuted = true
        // The display layer only presents frames while it is part of an on-screen layer tree.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 160, height: 120),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        player.videoLayer.frame = CGRect(x: 0, y: 0, width: 160, height: 120)
        window.contentView?.layer?.addSublayer(player.videoLayer)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        #expect(player.hasVideo)
        #expect(player.hasAudio)
        #expect(abs(player.duration - 1.0) < 0.1)

        player.play()
        await waitUntil { player.currentTime > 0.4 }
        #expect(player.currentTime > 0.4)
        #expect(player.error == nil)
        if onRealMac {
            #expect(player.displayedFrame() != nil)
        }
        player.pause()
    }

    @Test("Stops at the end and reports it", .enabled(if: onRealMac, "needs an audio device and real-time decoding"))
    func ends() async throws {
        let player = try MatroskaPlayer(url: fixtureURL("h264_aac.mkv"))
        player.isMuted = true
        var ended = false
        player.onEnd = { ended = true }
        player.play()
        await waitUntil(timeout: 4) { ended }
        #expect(ended)
        #expect(!player.isPlaying)
    }

    @Test("Seeking lands on the keyframe at or before the target")
    func seeks() async throws {
        let player = try MatroskaPlayer(url: fixtureURL("h264_aac.mkv"))
        player.isMuted = true
        player.seek(to: 0.7)
        // The fixture has keyframes at 0.0 and 0.5 s.
        #expect(abs(player.currentTime - 0.5) < 0.05)
        player.play()
        await waitUntil { player.currentTime > 0.8 }
        #expect(player.currentTime > 0.8)
        #expect(player.error == nil)
        player.pause()
    }

    @Test("Tracks without a native decoder are listed, the rest still plays")
    func unsupportedAudio() throws {
        // AV1 has no decoder on Macs before M3; FLAC audio always works.
        let player = try MatroskaPlayer(url: fixtureURL("av1_flac.mkv"))
        #expect(player.hasAudio)
        if !player.hasVideo {
            #expect(player.unsupportedCodecs == ["V_AV1"])
        }
    }
}
