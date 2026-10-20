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
        entries.reduce(0) { $0.addingClamped($1.kind == .file ? $1.size ?? 0 : 0) }
    }

    public static func read(url: URL, maxEntries: Int = 20_000, timeLimit: TimeInterval = 3) throws -> ArchiveListing {
        try list(url: url, raw: isSingleStream(url), maxEntries: maxEntries, timeLimit: timeLimit)
    }

    /// A lone .gz/.bz2/.xz holds one compressed file, not an archive. Format detection would
    /// guess (libarchive takes plain text for an mtree spec), so it is read as a raw stream.
    static func isSingleStream(_ url: URL) -> Bool {
        ["gz", "bz2", "xz", "lzma", "z"].contains(url.pathExtension.lowercased())
            && url.deletingPathExtension().pathExtension.lowercased() != "tar"
    }

    /// The contents of one entry (for example `docProps/core.xml` in a .docx), up to `maxBytes`.
    /// In a lone .gz or .xz the one decompressed file is the entry, whatever `path` says.
    /// Gives up with `nil` after `timeLimit` or when the calling task is cancelled: reaching the
    /// end of a big .tar.gz means decompressing everything before it.
    public static func data(ofEntry path: String, in url: URL, maxBytes: Int = 4 * 1024 * 1024,
                            timeLimit: TimeInterval = 5) throws -> Data? {
        let raw = isSingleStream(url)
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
        let pass = Pass(archive: archive, url: url, timeLimit: timeLimit)
        var entry: OpaquePointer?
        while !pass.isOver, archive_read_next_header(archive, &entry) >= ARCHIVE_WARN, let current = entry {
            let name = string(archive_entry_pathname_utf8(current)) ?? string(archive_entry_pathname(current))
            guard raw || name == path else {
                guard pass.skip(current) else { return nil }
                continue
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while data.count < maxBytes {
                if pass.isOver { return nil }
                let count = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(min(count, maxBytes - data.count)))
            }
            return data
        }
        return nil
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
        let pass = Pass(archive: archive, url: url, timeLimit: timeLimit)
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
                item.size = countBytes(pass)
            }
            listing.isEncrypted = listing.isEncrypted || item.isEncrypted
            listing.entries.append(item)

            if listing.entries.count >= maxEntries || pass.isOver || !raw && !pass.skip(entry) {
                listing.isTruncated = true
                break
            }
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

    /// The limits of one pass through an archive: a deadline and cancellation of the calling task.
    private struct Pass {
        let archive: OpaquePointer
        let deadline: Date
        /// The most an entry may claim to hold and still be skipped in one uninterruptible call.
        let skipLimit: Int64

        init(archive: OpaquePointer, url: URL, timeLimit: TimeInterval) {
            self.archive = archive
            deadline = Date().addingTimeInterval(timeLimit)
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            skipLimit = max(16 * 1024 * 1024, 2 * Int64(fileSize))
        }

        var isOver: Bool { Date() >= deadline || Task.isCancelled }

        /// Moves past the data of the current entry; `false` if time ran out or the task was cancelled.
        /// libarchive's skip is one call that cannot be interrupted, and in a compressed TAR or a solid
        /// 7-Zip or RAR it decompresses the whole entry: 50 KB of bzip2 can hold 64 GB of zeros. It is
        /// used where it is a seek, or where the entry claims no more than an archive of this size could
        /// honestly hold; anything else is read through in blocks, checking the clock between them.
        func skip(_ entry: OpaquePointer) -> Bool {
            if archive_entry_size_is_set(entry) != 0 {
                let seeks = archive_filter_count(archive) <= 1
                    && Self.seekingFormats.contains(archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK)
                if seeks || archive_entry_size(entry) <= skipLimit {
                    archive_read_data_skip(archive)
                    return true
                }
            }
            var block: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            while !isOver {
                let status = archive_read_data_block(archive, &block, &size, &offset)
                if status == ARCHIVE_EOF || status < ARCHIVE_WARN { return true }
            }
            return false
        }

        /// Uncompressed containers whose skip moves the file position without decompressing anything.
        private static let seekingFormats = [
            ARCHIVE_FORMAT_ZIP, ARCHIVE_FORMAT_TAR, ARCHIVE_FORMAT_ISO9660, ARCHIVE_FORMAT_CPIO,
            ARCHIVE_FORMAT_AR, ARCHIVE_FORMAT_XAR, ARCHIVE_FORMAT_LHA,
        ]
    }

    /// Size of a raw compressed stream, which only decompression reveals.
    private static func countBytes(_ pass: Pass) -> Int64? {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var total: Int64 = 0
        while !pass.isOver {
            let count = buffer.withUnsafeMutableBytes { archive_read_data(pass.archive, $0.baseAddress, $0.count) }
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
