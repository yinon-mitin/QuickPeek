import AppKit
import QuickPeekCore

/// Entry point. Without arguments it opens the settings window; the command-line modes exist
/// so previews can be checked and debugged without going through Quick Look:
///
///     QuickPeek --render <file>                     print the preview HTML
///     QuickPeek --snapshot <file> <out.png> [--dark] render the preview in WebKit to a PNG
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

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("QuickPeek: \(message)\n".utf8))
        exit(1)
    }
}
