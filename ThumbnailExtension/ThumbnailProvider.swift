import AppKit
import QuickLookThumbnailing
import QuickPeekFormats
import QuickPeekMedia

/// Finder thumbnails: a keyframe for video formats macOS cannot read (decoded by VideoToolbox),
/// and the app's own icon for .ipa, .apk and Xcode archives.
final class ThumbnailProvider: QLThumbnailProvider {
    private static let packageExtensions: Set<String> = ["ipa", "apk", "xcarchive"]

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        do {
            if Self.packageExtensions.contains(request.fileURL.pathExtension.lowercased()) {
                handler(try packageThumbnail(request), nil)
            } else {
                handler(try videoThumbnail(request), nil)
            }
        } catch {
            handler(nil, error)
        }
    }

    private func videoThumbnail(_ request: QLFileThumbnailRequest) throws -> QLThumbnailReply {
        let maxPixels = Int((max(request.maximumSize.width, request.maximumSize.height) * request.scale).rounded(.up))
        let image = try VideoFrameExtractor(url: request.fileURL).image(maxPixelSize: maxPixels)
        let fitted = Self.fit(CGSize(width: image.width, height: image.height), in: request.maximumSize)
        let reply = QLThumbnailReply(contextSize: fitted) { context in
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: fitted))
            return true
        }
        reply.extensionBadge = request.fileURL.pathExtension.uppercased()
        return reply
    }

    /// The package's icon, square; iOS-family icons get the rounded-square mask they have on devices.
    private func packageThumbnail(_ request: QLFileThumbnailRequest) throws -> QLThumbnailReply {
        let package = try AppPackage.read(url: request.fileURL)
        guard let data = package.iconData, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let side = min(request.maximumSize.width, request.maximumSize.height)
        let size = CGSize(width: side, height: side)
        let masked = package.platform != .android && package.platform != .macOS
        let reply = QLThumbnailReply(contextSize: size) { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: side * 0.06, dy: side * 0.06)
            if masked {
                let radius = rect.width * 0.2237
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.clip()
            }
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            return true
        }
        reply.extensionBadge = request.fileURL.pathExtension.uppercased()
        return reply
    }

    /// Largest size with the image's aspect ratio that fits in `bounds` (in points).
    static func fit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
