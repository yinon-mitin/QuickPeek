import Foundation

public enum PreviewError: Error, Equatable {
    case binaryContent
}

/// File on disk → HTML document. Shared by the Quick Look extension and the host app.
public enum PreviewPipeline {
    public static func html(for url: URL, assets: PreviewAssets, options: RenderOptions = .init()) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: options.maxBytes + 1) ?? Data()
        let truncated = data.count > options.maxBytes

        guard let text = TextDecoder.decode(truncated ? data.prefix(options.maxBytes) : data, truncated: truncated) else {
            throw PreviewError.binaryContent
        }
        let kind = FileClassifier.classify(fileName: url.lastPathComponent, prefix: String(text.prefix(256)))
        return PreviewRenderer.render(
            kind: kind,
            text: text,
            fileName: url.lastPathComponent,
            assets: assets,
            options: options,
            truncated: truncated
        )
    }
}
