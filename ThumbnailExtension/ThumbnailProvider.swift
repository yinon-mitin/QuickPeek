import AppKit
import QuickLookThumbnailing
import QuickPeekMedia

/// Finder thumbnails for video formats macOS cannot read: one keyframe, decoded by VideoToolbox.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let maxPixels = Int((max(request.maximumSize.width, request.maximumSize.height) * request.scale).rounded(.up))
        let image: CGImage
        do {
            image = try VideoFrameExtractor(url: request.fileURL).image(maxPixelSize: maxPixels)
        } catch {
            handler(nil, error)
            return
        }

        let pixelSize = CGSize(width: image.width, height: image.height)
        let fitted = Self.fit(pixelSize, in: request.maximumSize)
        let reply = QLThumbnailReply(contextSize: fitted) { context in
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: fitted))
            return true
        }
        reply.extensionBadge = request.fileURL.pathExtension.uppercased()
        handler(reply, nil)
    }

    /// Largest size with the image's aspect ratio that fits in `bounds` (in points).
    static func fit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
