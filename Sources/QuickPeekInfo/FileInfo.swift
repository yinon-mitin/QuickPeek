import Foundation
import UniformTypeIdentifiers

public struct InfoItem: Sendable, Equatable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

public struct InfoSection: Sendable, Equatable {
    public var title: String
    public var symbol: String
    public var items: [InfoItem]

    public init(_ title: String, symbol: String, items: [InfoItem]) {
        self.title = title
        self.symbol = symbol
        self.items = items
    }
}

/// Technical details of a file, grouped like MediaInfo: General first, then type-specific sections.
public struct FileInfo: Sendable {
    public var sections: [InfoSection]
    /// One line for menus and headers, for example "1920×1080 · H.264 · 2:03".
    public var summary: String
}

/// A source of type-specific sections. Readers are tried in order; each decides from the
/// file's type whether it applies.
protocol InfoReader {
    static func canRead(_ type: UTType, url: URL) -> Bool
    static func read(_ url: URL, format: InfoFormat) throws -> (sections: [InfoSection], summary: String?)
}

public enum FileInfoReader {
    static let readers: [any InfoReader.Type] = [
        MatroskaInfo.self, AVMediaInfo.self, PhotoInfo.self, TorrentInfo.self, OfficeInfo.self, AppInfo.self,
        ArchiveInfo.self, PDFInfo.self, FontInfo.self, TextInfo.self,
    ]

    /// - Parameter quick: keep to a fraction of a second (Finder's context menu waits for the
    ///   answer): archives are listed only briefly, media loading times out sooner, bundle
    ///   sizes are skipped.
    public static func read(_ url: URL, locale: Locale = .autoupdatingCurrent, quick: Bool = false) -> FileInfo {
        let format = InfoFormat(locale: locale, quick: quick)
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .totalFileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey,
            .localizedTypeDescriptionKey, .contentTypeKey, .isDirectoryKey,
        ])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data

        var general: [InfoItem] = [InfoItem("Name", url.lastPathComponent)]
        // The type's own description is more reliable than the resource value, which can be a
        // bare "text" for files Spotlight has not indexed.
        if let kind = type.localizedDescription ?? values?.localizedTypeDescription {
            general.append(InfoItem("Kind", kind))
        }
        let size = values?.fileSize.map(Int64.init)
        if let size { general.append(InfoItem("Size", format.bytesWithCount(size))) }
        if let created = values?.creationDate { general.append(InfoItem("Created", format.date(created))) }
        if let modified = values?.contentModificationDate { general.append(InfoItem("Modified", format.date(modified))) }

        var sections = [InfoSection("General", symbol: "doc", items: general)]
        var summary: String?
        for reader in readers where reader.canRead(type, url: url) {
            guard let result = try? reader.read(url, format: format) else { continue }
            sections += result.sections
            summary = result.summary
            break
        }
        return FileInfo(sections: sections, summary: summary ?? size.map(format.bytes) ?? "")
    }
}

/// Locale-aware formatting shared by all readers.
struct InfoFormat: Sendable {
    let locale: Locale
    var quick = false

    /// Time budget for slow readers.
    var timeLimit: TimeInterval { quick ? 0.4 : 3 }

    func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file).locale(locale))
    }

    func bytesWithCount(_ count: Int64) -> String {
        "\(bytes(count)) (\(number(count)) bytes)"
    }

    func number<Value: BinaryInteger>(_ value: Value) -> String {
        Int64(value).formatted(.number.locale(locale))
    }

    func decimal(_ value: Double, digits: Int = 2) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).locale(locale))
    }

    func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    /// 1:02:03 or 2:03.
    func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// Bits per second as kb/s or Mb/s.
    func bitrate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? "\(decimal(bitsPerSecond / 1_000_000, digits: 1)) Mb/s"
            : "\(decimal(bitsPerSecond / 1_000, digits: 0)) kb/s"
    }

    func percent(_ fraction: Double) -> String {
        "\(decimal(fraction * 100, digits: 1))%"
    }

    func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }
}

extension FileInfo {
    /// The details as plain text, for "Copy All" and the command line.
    public var report: String {
        var lines = [summary]
        for section in sections {
            lines.append("")
            lines.append(section.title)
            let width = section.items.map(\.label.count).max() ?? 0
            for item in section.items {
                lines.append("  " + item.label.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + item.value)
            }
        }
        return lines.joined(separator: "\n")
    }
}
