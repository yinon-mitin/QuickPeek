import Foundation

/// The contents of a folder on disk, listed the way Finder shows them: hidden files are skipped
/// and packages such as apps are single items. The walk stops after `limit` entries, so a
/// preview of a huge folder (a home folder, `node_modules`) still opens at once.
public struct FolderListing: Sendable {
    public var items: [FileTreeItem]
    /// Files read, not counting folders.
    public var fileCount: Int
    public var totalSize: Int64
    /// The walk stopped at the limit; counts and sizes cover only what was read.
    public var isTruncated: Bool

    public static func read(url: URL, limit: Int = 5_000) throws -> FolderListing {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true } // an unreadable subfolder should not hide the rest
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: url])
        }
        let rootDepth = url.standardizedFileURL.pathComponents.count
        var listing = FolderListing(items: [], fileCount: 0, totalSize: 0, isTruncated: false)
        for case let item as URL in walk {
            guard listing.items.count < limit else {
                listing.isTruncated = true
                break
            }
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            let size = isFolder ? nil : values?.fileSize.map(Int64.init)
            let linkTarget = values?.isSymbolicLink == true
                ? try? FileManager.default.destinationOfSymbolicLink(atPath: item.path) : nil
            listing.items.append(FileTreeItem(
                components: Array(item.standardizedFileURL.pathComponents.dropFirst(rootDepth)),
                isDirectory: isFolder, size: size, modified: values?.contentModificationDate, linkTarget: linkTarget
            ))
            if !isFolder {
                listing.fileCount += 1
                listing.totalSize += size ?? 0
            }
        }
        return listing
    }
}
