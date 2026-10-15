import AppKit
import SwiftUI
import QuickPeekCore
import QuickPeekFormats
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
///     QuickPeek --snapshot-info <file> <out.png>    the ⓘ details panel as a PNG
///     QuickPeek --play <video>                      play in a window with the Quick Look player
///     QuickPeek --play-snapshot <video> <out.png>   play briefly and save the player as a PNG
@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first {
        case "--snapshot-info" where arguments.count >= 3:
            let input = URL(fileURLWithPath: arguments[1])
            ViewSnapshot.run(output: URL(fileURLWithPath: arguments[2]), dark: arguments.contains("--dark"),
                             size: NSSize(width: 440, height: 520)) {
                NSHostingView(rootView: InfoPanel(info: FileInfoReader.read(input)))
            }
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
            // --quick reads within the time budget of Finder's context menu.
            let quick = arguments.contains("--quick")
            for path in arguments.dropFirst() where path != "--quick" {
                let started = Date()
                let info = FileInfoReader.read(URL(fileURLWithPath: path), quick: quick)
                printInfo(info)
                if quick { print(String(format: "(%.0f ms)\n", Date().timeIntervalSince(started) * 1000)) }
            }
        case "--package" where arguments.count >= 2:
            // JSON per package, for comparing the APK/IPA readers with other tools.
            for path in arguments.dropFirst() {
                var fields: [String: Any] = ["file": (path as NSString).lastPathComponent]
                do {
                    let package = try AppPackage.read(url: URL(fileURLWithPath: path))
                    fields["name"] = package.name
                    fields["identifier"] = package.identifier ?? NSNull()
                    fields["version"] = package.version ?? NSNull()
                    fields["build"] = package.build ?? NSNull()
                    fields["minimumOS"] = package.minimumOS ?? NSNull()
                    fields["permissions"] = package.permissions
                    fields["iconBytes"] = package.iconData?.count ?? 0
                } catch {
                    fields["error"] = "\(error)"
                }
                let json = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
                print(String(decoding: json ?? Data(), as: UTF8.self))
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
            let container = try MediaContainers.open(input)
            print("format=\(container.formatName) duration=\(container.durationSeconds.map { String(format: "%.3f", $0) } ?? "?")")
            var packets: [UInt64: (count: Int, keyframes: Int, bytes: Int)] = [:]
            for packet in try container.packets(from: nil) {
                var entry = packets[packet.streamID] ?? (0, 0, 0)
                entry.count += 1
                entry.keyframes += packet.isKeyframe ? 1 : 0
                entry.bytes += packet.data.count
                packets[packet.streamID] = entry
            }
            for stream in container.streams {
                let stats = packets[stream.id] ?? (0, 0, 0)
                var details = ""
                if stream.kind == .video { details = "\(stream.width)x\(stream.height)" }
                if stream.kind == .audio { details = "\(Int(stream.sampleRate))Hz \(stream.channels)ch" }
                print("stream \(stream.id) \(stream.kind) \(stream.codecName) \(details) packets=\(stats.count) keyframes=\(stats.keyframes) bytes=\(stats.bytes)")
            }
            print(String(format: "parsed in %.0f ms", Date().timeIntervalSince(started) * 1000))
        } catch {
            fail("\(input.path): \(error)")
        }
    }

    private static func printInfo(_ info: FileInfo) {
        print(info.report + "\n")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("QuickPeek: \(message)\n".utf8))
        exit(1)
    }
}
