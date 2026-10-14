import CArchive
import Foundation

public enum ArchiveError: Error, Equatable {
    case unrecognized(String)
}

public struct ArchiveEntry: Sendable, Equatable {
    public enum Kind: Sendable { case file, directory, symlink, other }

    public var path: String
    public var kind: Kind
    public var size: Int64?
    public var modified: Date?
    public var isEncrypted: Bool
    public var linkTarget: String?
}

/// The table of contents of an archive, read with the libarchive that ships with macOS:
/// ZIP, TAR (gzip, bzip2, xz, lzma), RAR, RAR5, 7-Zip, ISO 9660, CPIO, XAR, CAB, LHA and AR.
/// Nothing is extracted; compressed TARs are decompressed in a stream to reach their headers.
public struct ArchiveListing: Sendable {
    public var format: String
    /// Outer compression, for example "gzip" for a .tar.gz.
    public var compression: String?
    public var entries: [ArchiveEntry]
    /// The listing stopped early (entry or time limit); `entries` is the beginning.
    public var isTruncated: Bool
    public var isEncrypted: Bool
    /// Why the listing ended early, if it did (for example encrypted headers).
    public var problem: String?

    public var totalSize: Int64 {
        entries.reduce(0) { $0 + ($1.kind == .file ? $1.size ?? 0 : 0) }
    }

    public static func read(url: URL, maxEntries: Int = 20_000, timeLimit: TimeInterval = 3) throws -> ArchiveListing {
        // A lone .gz/.bz2/.xz holds one compressed file, not an archive. Format detection would
        // guess (libarchive takes plain text for an mtree spec), so read it as a raw stream.
        let isSingleStream = ["gz", "bz2", "xz", "lzma", "z"].contains(url.pathExtension.lowercased())
            && url.deletingPathExtension().pathExtension.lowercased() != "tar"
        return try list(url: url, raw: isSingleStream, maxEntries: maxEntries, timeLimit: timeLimit)
    }

    private static func list(url: URL, raw: Bool, maxEntries: Int, timeLimit: TimeInterval) throws -> ArchiveListing {
        guard let archive = archive_read_new() else { throw ArchiveError.unrecognized("libarchive unavailable") }
        defer { archive_read_free(archive) }
        archive_read_support_filter_all(archive)
        if raw {
            archive_read_support_format_raw(archive)
        } else {
            archive_read_support_format_all(archive)
        }
        guard archive_read_open_filename(archive, url.path, 64 * 1024) == ARCHIVE_OK else {
            throw ArchiveError.unrecognized(errorMessage(archive))
        }

        var listing = ArchiveListing(format: "", compression: nil, entries: [], isTruncated: false, isEncrypted: false, problem: nil)
        let deadline = Date().addingTimeInterval(timeLimit)
        var entry: OpaquePointer?

        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { break }
            if status < ARCHIVE_WARN || entry == nil {
                let message = errorMessage(archive)
                if listing.entries.isEmpty && listing.format.isEmpty && !message.lowercased().contains("encrypt") {
                    throw ArchiveError.unrecognized(message)
                }
                listing.problem = message
                listing.isEncrypted = listing.isEncrypted || message.lowercased().contains("encrypt")
                break
            }
            if listing.format.isEmpty {
                listing.format = formatName(archive)
                listing.compression = compressionName(archive)
            }
            guard let entry else { break }

            var item = describe(entry)
            if raw {
                item.path = url.deletingPathExtension().lastPathComponent
                item.size = countBytes(archive, until: deadline)
            }
            listing.isEncrypted = listing.isEncrypted || item.isEncrypted
            listing.entries.append(item)

            if listing.entries.count >= maxEntries || Date() > deadline {
                listing.isTruncated = true
                break
            }
            if !raw { archive_read_data_skip(archive) }
        }

        if listing.format.isEmpty {
            listing.format = formatName(archive)
            listing.compression = compressionName(archive)
        }
        if archive_read_has_encrypted_entries(archive) > 0 {
            listing.isEncrypted = true
        }
        return listing
    }

    private static func describe(_ entry: OpaquePointer) -> ArchiveEntry {
        let path = string(archive_entry_pathname_utf8(entry)) ?? string(archive_entry_pathname(entry)) ?? "?"
        let kind: ArchiveEntry.Kind
        switch archive_entry_filetype(entry) & AE_IFMT {
        case AE_IFDIR: kind = .directory
        case AE_IFLNK: kind = .symlink
        case AE_IFREG: kind = .file
        default: kind = path.hasSuffix("/") ? .directory : .other
        }
        return ArchiveEntry(
            path: path.hasSuffix("/") ? String(path.dropLast()) : path,
            kind: kind,
            size: kind == .file && archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil,
            modified: archive_entry_mtime_is_set(entry) != 0 ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry))) : nil,
            isEncrypted: archive_entry_is_encrypted(entry) != 0,
            linkTarget: kind == .symlink ? string(archive_entry_symlink_utf8(entry)) ?? string(archive_entry_symlink(entry)) : nil
        )
    }

    /// Size of a raw compressed stream, which only decompression reveals.
    private static func countBytes(_ archive: OpaquePointer, until deadline: Date) -> Int64? {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var total: Int64 = 0
        while Date() < deadline {
            let count = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
            if count == 0 { return total }
            if count < 0 { return nil }
            total += Int64(count)
        }
        return nil
    }

    private static func formatName(_ archive: OpaquePointer) -> String {
        switch archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK {
        case ARCHIVE_FORMAT_ZIP: "ZIP"
        case ARCHIVE_FORMAT_TAR: "TAR"
        case ARCHIVE_FORMAT_RAR: "RAR"
        case ARCHIVE_FORMAT_RAR_V5: "RAR5"
        case ARCHIVE_FORMAT_7ZIP: "7-Zip"
        case ARCHIVE_FORMAT_ISO9660: "ISO 9660"
        case ARCHIVE_FORMAT_CPIO: "CPIO"
        case ARCHIVE_FORMAT_XAR: "XAR"
        case ARCHIVE_FORMAT_CAB: "CAB"
        case ARCHIVE_FORMAT_LHA: "LHA"
        case ARCHIVE_FORMAT_AR: "AR"
        case ARCHIVE_FORMAT_RAW: "Compressed file"
        default: "Archive"
        }
    }

    private static func compressionName(_ archive: OpaquePointer) -> String? {
        // Filter 0 is the outermost; the last one is always "none".
        guard archive_filter_count(archive) > 1 else { return nil }
        return string(archive_filter_name(archive, 0))
    }

    private static func errorMessage(_ archive: OpaquePointer) -> String {
        string(archive_error_string(archive)) ?? "Unreadable archive"
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }
}
