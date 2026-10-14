import AppKit
import QuickPeekCore
import QuickPeekInfo
import QuickPeekMedia
import QuickPeekText

/// Entry point. Without arguments it opens the settings window; the command-line modes exist
/// so previews can be checked and debugged without going through Quick Look:
///
///     QuickPeek --snapshot <file> <out.png> [--dark] render a document, archive or torrent preview to a PNG
///     QuickPeek --thumbnail <video> <out.png> [size]  decode the thumbnail frame of a video
///     QuickPeek --probe <video>                     list tracks and count frames, like ffprobe
///     QuickPeek --info <file> [...]                 technical details of any file, like mediainfo
///     QuickPeek --play <video>                      play in a window with the Quick Look player
///     QuickPeek --play-snapshot <video> <out.png>   play briefly and save the player as a PNG
@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first {
        case "--snapshot" where arguments.count >= 3:
            let input = URL(fileURLWithPath: arguments[1])
            let services = TextServices(vendorDirectory: Bundle.main.resourceURL!.appendingPathComponent("Vendor", isDirectory: true))
            ViewSnapshot.run(output: URL(fileURLWithPath: arguments[2]), dark: arguments.contains("--dark"),
                             size: StructuredPreview.handles(input) ? NSSize(width: 760, height: 560) : NSSize(width: 900, height: 700)) {
                StructuredPreview.handles(input)
                    ? try StructuredPreview.view(for: input)
                    : DocumentViews.view(for: try TextDocument.load(input), services: services)
            }
        case "--thumbnail" where arguments.count >= 3:
            thumbnail(
                URL(fileURLWithPath: arguments[1]),
                output: URL(fileURLWithPath: arguments[2]),
                maxPixelSize: arguments.count > 3 ? Int(arguments[3]) : nil
            )
        case "--probe" where arguments.count == 2:
            probe(URL(fileURLWithPath: arguments[1]))
        case "--info" where arguments.count >= 2:
            for path in arguments.dropFirst() {
                printInfo(FileInfoReader.read(URL(fileURLWithPath: path)))
            }
        case "--play" where arguments.count == 2:
            PlayerWindow.run(URL(fileURLWithPath: arguments[1]), snapshotTo: nil)
        case "--play-snapshot" where arguments.count == 3:
            PlayerWindow.run(URL(fileURLWithPath: arguments[1]), snapshotTo: URL(fileURLWithPath: arguments[2]))
        default:
            QuickPeekApp.main()
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

    private static func printInfo(_ info: FileInfo) {
        print(info.summary)
        for section in info.sections {
            print("\n\(section.title)")
            let width = section.items.map(\.label.count).max() ?? 0
            for item in section.items {
                print("  " + item.label.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + item.value)
            }
        }
        print("")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("QuickPeek: \(message)\n".utf8))
        exit(1)
    }
}
