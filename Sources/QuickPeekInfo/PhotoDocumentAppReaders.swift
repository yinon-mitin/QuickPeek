import Foundation
import ImageIO
import QuickPeekFormats
import Security
import UniformTypeIdentifiers

// MARK: - Photos and RAW

enum PhotoInfo: InfoReader {
    static func canRead(_ type: UTType, url: URL) -> Bool {
        type.conforms(to: .image)
    }

    static func read(_ url: URL, format: InfoFormat) throws -> (sections: [InfoSection], summary: String?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let typeName = CGImageSourceGetType(source).flatMap { formatName(UTType($0 as String)) } ?? "Image"
        var image = [InfoItem("Format", typeName)]
        var summaryParts = [typeName]

        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        if var width = properties[kCGImagePropertyPixelWidth] as? Int, var height = properties[kCGImagePropertyPixelHeight] as? Int {
            if (5...8).contains(orientation) { swap(&width, &height) }
            image.append(InfoItem("Resolution", "\(width) × \(height)"))
            image.append(InfoItem("Megapixels", "\(format.decimal(Double(width * height) / 1_000_000, digits: 1)) MP"))
            summaryParts.insert("\(width)×\(height)", at: 0)
        }
        if let dpi = properties[kCGImagePropertyDPIWidth] as? Double { image.append(InfoItem("Resolution (print)", "\(format.decimal(dpi, digits: 0)) dpi")) }
        if let model = properties[kCGImagePropertyColorModel] as? String { image.append(InfoItem("Colour model", model)) }
        if let profile = properties[kCGImagePropertyProfileName] as? String { image.append(InfoItem("Colour profile", profile)) }
        if let depth = properties[kCGImagePropertyDepth] as? Int { image.append(InfoItem("Bit depth", "\(depth) bits per channel")) }
        if let alpha = properties[kCGImagePropertyHasAlpha] as? Bool { image.append(InfoItem("Alpha channel", format.yesNo(alpha))) }
        let frames = CGImageSourceGetCount(source)
        if frames > 1 { image.append(InfoItem("Frames", "\(format.number(frames)) (animated or multi-page)")) }
        if orientation != 1 { image.append(InfoItem("Orientation", orientationName(orientation))) }
        var sections = [InfoSection("Image", symbol: "photo", items: image)]

        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        var camera: [InfoItem] = []
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let name = cameraName(make: make, model: model) {
            camera.append(InfoItem("Camera", name))
            summaryParts.append(name)
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String ?? exifAux[kCGImagePropertyExifAuxLensModel] as? String {
            camera.append(InfoItem("Lens", lens))
        }
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            camera.append(InfoItem("Exposure", time < 1 ? "1/\(Int((1 / time).rounded())) s" : "\(format.decimal(time, digits: 1)) s"))
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double { camera.append(InfoItem("Aperture", "f/\(format.decimal(aperture, digits: 1))")) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { camera.append(InfoItem("ISO", String(iso))) }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            var text = "\(format.decimal(focal, digits: 1)) mm"
            if let equivalent = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, equivalent > 0, Double(equivalent) != focal {
                text += " (\(equivalent) mm full-frame equivalent)"
            }
            camera.append(InfoItem("Focal length", text))
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, bias != 0 {
            camera.append(InfoItem("Exposure bias", "\(bias > 0 ? "+" : "")\(format.decimal(bias, digits: 1)) EV"))
        }
        if let flash = exif[kCGImagePropertyExifFlash] as? Int { camera.append(InfoItem("Flash", flash & 1 == 1 ? "Fired" : "Did not fire")) }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let date = exifDate(taken, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String) {
            camera.append(InfoItem("Taken", format.date(date)))
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String { camera.append(InfoItem("Software", software)) }
        if let artist = tiff[kCGImagePropertyTIFFArtist] as? String { camera.append(InfoItem("Artist", artist)) }
        if let copyright = tiff[kCGImagePropertyTIFFCopyright] as? String { camera.append(InfoItem("Copyright", copyright)) }
        if !camera.isEmpty { sections.append(InfoSection("Camera", symbol: "camera", items: camera)) }

        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude] as? Double, let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            let north = (gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N") != "S"
            let east = (gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E") != "W"
            let coordinate = { (value: Double) in value.formatted(.number.precision(.fractionLength(4)).locale(format.locale)) }
            var location = [InfoItem("Coordinates", "\(coordinate(latitude))° \(north ? "N" : "S"), \(coordinate(longitude))° \(east ? "E" : "W")")]
            if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double {
                let below = gps[kCGImagePropertyGPSAltitudeRef] as? Int == 1
                location.append(InfoItem("Altitude", "\(below ? "-" : "")\(format.decimal(altitude, digits: 0)) m"))
            }
            sections.append(InfoSection("Location", symbol: "location", items: location))
        }
        return (sections, summaryParts.joined(separator: " · "))
    }

    /// "Canon" + "Canon EOS R5" reads better as just the model.
    static func cameraName(make: String?, model: String?) -> String? {
        guard let model, !model.isEmpty else { return make }
        guard let make, !make.isEmpty else { return model }
        let firstWord = make.split(separator: " ").first.map(String.init) ?? make
        return model.lowercased().hasPrefix(firstWord.lowercased()) ? model : "\(make) \(model)"
    }

    static func formatName(_ type: UTType?) -> String? {
        guard let type else { return nil }
        let names = [
            "public.jpeg": "JPEG", "public.png": "PNG", "public.heic": "HEIC", "public.heif": "HEIF", "public.avif": "AVIF",
            "com.compuserve.gif": "GIF", "org.webmproject.webp": "WebP", "public.tiff": "TIFF", "com.microsoft.bmp": "BMP",
            "com.microsoft.ico": "ICO", "com.adobe.photoshop-image": "Photoshop (PSD)", "com.adobe.raw-image": "DNG",
            "public.svg-image": "SVG", "public.jpeg-2000": "JPEG 2000",
        ]
        if let name = names[type.identifier] { return name }
        if type.conforms(to: .rawImage) { return (type.localizedDescription ?? "RAW") }
        return type.localizedDescription
    }

    static func orientationName(_ value: Int) -> String {
        [2: "Mirrored", 3: "Rotated 180°", 4: "Mirrored vertically", 5: "Mirrored, rotated 90°", 6: "Rotated 90° clockwise",
         7: "Mirrored, rotated 270°", 8: "Rotated 90° counter-clockwise"][value] ?? "Normal"
    }

    /// EXIF dates are local time ("2026:01:02 15:30:00"), with an optional "+02:00" offset tag.
    static func exifDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset, let zone = TimeZone(iso8601Offset: offset) { formatter.timeZone = zone }
        return formatter.date(from: text)
    }
}

extension TimeZone {
    init?(iso8601Offset text: String) {
        let sign = text.hasPrefix("-") ? -1 : 1
        let parts = text.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(secondsFromGMT: sign * (parts[0] * 3600 + parts[1] * 60))
    }
}

// MARK: - Office Open XML

enum OfficeInfo: InfoReader {
    static let extensions: Set<String> = ["docx", "docm", "dotx", "xlsx", "xlsm", "xltx", "pptx", "pptm", "potx"]

    static func canRead(_ type: UTType, url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func read(_ url: URL, format: InfoFormat) throws -> (sections: [InfoSection], summary: String?) {
        let core = try ArchiveListing.data(ofEntry: "docProps/core.xml", in: url).map(XMLFields.parse) ?? [:]
        let app = try ArchiveListing.data(ofEntry: "docProps/app.xml", in: url).map(XMLFields.parse) ?? [:]

        var items: [InfoItem] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { items.append(InfoItem(label, value)) }
        }
        add("Title", core["title"])
        add("Subject", core["subject"])
        add("Author", core["creator"])
        add("Last modified by", core["lastModifiedBy"])
        add("Keywords", core["keywords"])
        add("Description", core["description"])
        add("Revision", core["revision"])
        add("Created", core["created"].flatMap { ISO8601DateFormatter().date(from: $0) }.map(format.date))
        add("Modified", core["modified"].flatMap { ISO8601DateFormatter().date(from: $0) }.map(format.date))

        let count = { (key: String) in app[key].flatMap(Int.init) }
        var summary: [String] = []
        if let pages = count("Pages"), pages > 0 {
            add("Pages", format.number(pages))
            summary.append(pages == 1 ? "1 page" : "\(format.number(pages)) pages")
        }
        if let words = count("Words"), words > 0 {
            add("Words", format.number(words))
            summary.append("\(format.number(words)) words")
        }
        if let characters = count("Characters"), characters > 0 { add("Characters", format.number(characters)) }
        if let slides = count("Slides"), slides > 0 {
            add("Slides", format.number(slides))
            summary.append(slides == 1 ? "1 slide" : "\(format.number(slides)) slides")
        }
        if let notes = count("Notes"), notes > 0 { add("Notes", format.number(notes)) }
        if url.pathExtension.lowercased().hasPrefix("xl"),
           let workbook = try ArchiveListing.data(ofEntry: "xl/workbook.xml", in: url) {
            let sheets = XMLFields.attributeValues(in: workbook, element: "sheet", attribute: "name")
            if !sheets.isEmpty {
                add("Sheets", "\(sheets.count) (\(sheets.prefix(8).joined(separator: ", "))\(sheets.count > 8 ? ", …" : ""))")
                summary.append(sheets.count == 1 ? "1 sheet" : "\(sheets.count) sheets")
            }
        }
        add("Application", app["Application"])
        add("Company", app["Company"])
        if let minutes = count("TotalTime"), minutes > 0 { add("Editing time", "\(format.number(minutes)) min") }

        return ([InfoSection("Document", symbol: "doc.text", items: items)], summary.isEmpty ? nil : summary.joined(separator: " · "))
    }
}

/// Minimal XML reading: the text of each element (first occurrence, by local name) and
/// attribute values of a given element.
enum XMLFields {
    static func parse(_ data: Data) -> [String: String] {
        let delegate = TextCollector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.fields
    }

    static func attributeValues(in data: Data, element: String, attribute: String) -> [String] {
        let delegate = AttributeCollector(element: element, attribute: attribute)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.values
    }

    private final class TextCollector: NSObject, XMLParserDelegate {
        var fields: [String: String] = [:]
        private var current: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            current = name.split(separator: ":").last.map(String.init)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if let current, fields[current] == nil {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { fields[current] = value }
            }
            current = nil
            text = ""
        }
    }

    private final class AttributeCollector: NSObject, XMLParserDelegate {
        let element: String
        let attribute: String
        var values: [String] = []

        init(element: String, attribute: String) {
            self.element = element
            self.attribute = attribute
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name.split(separator: ":").last.map(String.init) == element, let value = attributes[attribute] {
                values.append(value)
            }
        }
    }
}

// MARK: - Applications

enum AppInfo: InfoReader {
    static func canRead(_ type: UTType, url: URL) -> Bool {
        type.conforms(to: .applicationBundle) || url.pathExtension.lowercased() == "app"
    }

    static func read(_ url: URL, format: InfoFormat) throws -> (sections: [InfoSection], summary: String?) {
        let contents = url.appendingPathComponent("Contents")
        let plistURL = FileManager.default.fileExists(atPath: contents.path)
            ? contents.appendingPathComponent("Info.plist") : url.appendingPathComponent("Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }

        let name = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        let shortVersion = plist["CFBundleShortVersionString"] as? String
        let build = plist["CFBundleVersion"] as? String
        var items = [InfoItem("Name", name)]
        if let identifier = plist["CFBundleIdentifier"] as? String { items.append(InfoItem("Bundle ID", identifier)) }
        if let shortVersion {
            items.append(InfoItem("Version", build.map { $0 == shortVersion ? shortVersion : "\(shortVersion) (\($0))" } ?? shortVersion))
        }
        if let minimum = plist["LSMinimumSystemVersion"] as? String { items.append(InfoItem("Minimum macOS", minimum)) }
        if let minimum = plist["MinimumOSVersion"] as? String { items.append(InfoItem("Minimum iOS", minimum)) }
        if let category = plist["LSApplicationCategoryType"] as? String {
            let words = category.replacingOccurrences(of: "public.app-category.", with: "").split(separator: "-").map(\.capitalized)
            items.append(InfoItem("Category", words.joined(separator: " ")))
        }

        var architectures: [String] = []
        if let executable = plist["CFBundleExecutable"] as? String {
            let path = FileManager.default.fileExists(atPath: contents.path)
                ? contents.appendingPathComponent("MacOS/\(executable)") : url.appendingPathComponent(executable)
            architectures = MachO.architectures(of: path)
            if !architectures.isEmpty {
                let label = Set(architectures).isSuperset(of: ["arm64", "x86_64"]) ? "Universal: " : ""
                items.append(InfoItem("Architectures", label + architectures.joined(separator: ", ")))
            }
        }
        if let copyright = plist["NSHumanReadableCopyright"] as? String { items.append(InfoItem("Copyright", copyright)) }
        if let size = directorySize(url) { items.append(InfoItem("Size on disk", format.bytes(size))) }

        var sections = [InfoSection("Application", symbol: "app", items: items)]
        if let signature = signatureItems(url) { sections.append(InfoSection("Signature", symbol: "checkmark.seal", items: signature)) }

        var summary = [shortVersion.map { "\(name) \($0)" } ?? name]
        if Set(architectures).isSuperset(of: ["arm64", "x86_64"]) {
            summary.append("Universal")
        } else if let only = architectures.first, architectures.count == 1 {
            summary.append(only == "arm64" ? "Apple silicon" : only)
        }
        return (sections, summary.joined(separator: " · "))
    }

    private static func signatureItems(_ url: URL) -> [InfoItem]? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let info = information as? [String: Any] else {
            return [InfoItem("Signed", "No")]
        }
        guard info[kSecCodeInfoIdentifier as String] != nil else { return [InfoItem("Signed", "No")] }

        var items: [InfoItem] = []
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let chain = certificates.compactMap { SecCertificateCopySubjectSummary($0) as String? }
        if chain.isEmpty {
            items.append(InfoItem("Signed by", "Ad hoc (no developer identity)"))
        } else {
            items.append(InfoItem("Signed by", chain.joined(separator: " ← ")))
        }
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String { items.append(InfoItem("Team ID", team)) }
        if let identifier = info[kSecCodeInfoIdentifier as String] as? String { items.append(InfoItem("Identifier", identifier)) }
        let codeFlags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        items.append(InfoItem("Hardened runtime", codeFlags & 0x10000 != 0 ? "Yes" : "No"))
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        items.append(InfoItem("App Sandbox", entitlements["com.apple.security.app-sandbox"] as? Bool == true ? "Yes" : "No"))
        return items
    }

    /// Allocated size of a bundle; gives up on enormous bundles rather than stalling a menu.
    private static func directorySize(_ url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return nil }
        var total: Int64 = 0
        let deadline = Date().addingTimeInterval(1.5)
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            if Date() > deadline { return nil }
        }
        return total
    }
}

/// Reads the CPU types of a Mach-O executable, thin or universal.
enum MachO {
    static func architectures(of url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url), let header = try? handle.read(upToCount: 4096) else { return [] }
        try? handle.close()
        let bytes = [UInt8](header)
        guard bytes.count >= 8 else { return [] }
        func bigEndian(_ offset: Int) -> UInt32 {
            offset + 4 <= bytes.count ? bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) } : 0
        }
        func littleEndian(_ offset: Int) -> UInt32 {
            offset + 4 <= bytes.count ? bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } : 0
        }
        switch bigEndian(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF: // universal: big-endian fat header, 20- or 32-byte entries
            let is64 = bigEndian(0) == 0xCAFE_BABF
            let count = Int(min(bigEndian(4), 16))
            return (0..<count).map { name(cpuType: bigEndian(8 + $0 * (is64 ? 32 : 20)), subtype: bigEndian(12 + $0 * (is64 ? 32 : 20))) }
        case 0xCFFA_EDFE, 0xCEFA_EDFE: // thin, little-endian
            return [name(cpuType: littleEndian(4), subtype: littleEndian(8))]
        default:
            return []
        }
    }

    static func name(cpuType: UInt32, subtype: UInt32) -> String {
        switch cpuType {
        case 0x0100_000C: subtype & 0xFF == 2 ? "arm64e" : "arm64"
        case 0x0100_0007: "x86_64"
        case 7: "i386"
        case 12: "arm"
        default: String(format: "cpu 0x%x", cpuType)
        }
    }
}
