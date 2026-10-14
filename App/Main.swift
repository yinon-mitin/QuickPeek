import AppKit
import QuickPeekCore
import QuickPeekMedia

/// Entry point. Without arguments it opens the settings window; the command-line modes exist
/// so previews can be checked and debugged without going through Quick Look:
///
///     QuickPeek --render <file>                     print the preview HTML
///     QuickPeek --snapshot <file> <out.png> [--dark] render the preview in WebKit to a PNG
///     QuickPeek --thumbnail <video> <out.png> [size]  decode the thumbnail frame of a video
///     QuickPeek --probe <video>                     list tracks and count frames, like ffprobe
@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first {
        case "--render" where arguments.count == 2:
            render(URL(fileURLWithPath: arguments[1]))
        case "--snapshot" where arguments.count >= 3:
            Snapshotter.run(
                input: URL(fileURLWithPath: arguments[1]),
                output: URL(fileURLWithPath: arguments[2]),
                dark: arguments.contains("--dark")
            )
        case "--thumbnail" where arguments.count >= 3:
            thumbnail(
                URL(fileURLWithPath: arguments[1]),
                output: URL(fileURLWithPath: arguments[2]),
                maxPixelSize: arguments.count > 3 ? Int(arguments[3]) : nil
            )
        case "--probe" where arguments.count == 2:
            probe(URL(fileURLWithPath: arguments[1]))
        default:
            QuickPeekApp.main()
        }
    }

    static var assets: PreviewAssets {
        let vendor = Bundle.main.resourceURL!.appendingPathComponent("Vendor", isDirectory: true)
        do {
            return try PreviewAssets.load(from: vendor)
        } catch {
            fail("cannot load assets from \(vendor.path): \(error)")
        }
    }

    private static func render(_ input: URL) {
        do {
            print(try PreviewPipeline.html(for: input, assets: assets))
        } catch {
            fail("\(input.path): \(error)")
        }
    }

    private static func thumbnail(_ input: URL, output: URL, maxPixelSize: Int?) {
        do {
            let image = try VideoFrameExtractor(url: input).image(maxPixelSize: maxPixelSize)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fail("cannot encode PNG")
            }
            try png.write(to: output)
        } catch {
            fail("\(input.path): \(error)")
        }
    }

    private static func probe(_ input: URL) {
        do {
            let started = Date()
            let demuxer = try MatroskaDemuxer(url: input)
            print("doctype=\(demuxer.docType) duration=\(demuxer.durationSeconds.map { String(format: "%.3f", $0) } ?? "?") cues=\(demuxer.cues.count)")
            var frames: [UInt64: (count: Int, keyframes: Int, bytes: Int)] = [:]
            for frame in try demuxer.frames() {
                var entry = frames[frame.trackNumber] ?? (0, 0, 0)
                entry.count += 1
                entry.keyframes += frame.isKeyframe ? 1 : 0
                entry.bytes += frame.data.count
                frames[frame.trackNumber] = entry
            }
            for track in demuxer.tracks {
                let stats = frames[track.number] ?? (0, 0, 0)
                var details = ""
                if let video = track.video { details = "\(video.pixelWidth)x\(video.pixelHeight)" }
                if let audio = track.audio { details = "\(Int(audio.samplingFrequency))Hz \(audio.channels)ch" }
                print("track \(track.number) \(track.type) \(track.codecID) \(details) frames=\(stats.count) keyframes=\(stats.keyframes) bytes=\(stats.bytes)")
            }
            print(String(format: "parsed in %.0f ms", Date().timeIntervalSince(started) * 1000))
        } catch {
            fail("\(input.path): \(error)")
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("QuickPeek: \(message)\n".utf8))
        exit(1)
    }
}
