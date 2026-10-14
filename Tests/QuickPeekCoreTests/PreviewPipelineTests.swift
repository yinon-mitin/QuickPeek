import Foundation
import Testing
@testable import QuickPeekCore

@Suite("PreviewPipeline")
struct PreviewPipelineTests {
    let assets = PreviewAssets(styles: [], scripts: [])

    private func temporaryFile(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickPeekTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    @Test("Reads, classifies and renders a file")
    func rendersFile() throws {
        let url = try temporaryFile(named: "compose.yaml", contents: Data("services:\n  web: {}\n".utf8))
        let html = try PreviewPipeline.html(for: url, assets: assets)
        #expect(html.contains("language-yaml"))
        #expect(html.contains("services:"))
    }

    @Test("Large files are cut at the byte limit with a notice")
    func truncatesLargeFiles() throws {
        let body = String(repeating: "qpk\n", count: 1000)
        let url = try temporaryFile(named: "big.log", contents: Data(body.utf8))
        let html = try PreviewPipeline.html(for: url, assets: assets, options: RenderOptions(maxBytes: 100))
        #expect(html.contains("class=\"truncated\""))
        #expect(html.components(separatedBy: "qpk").count - 1 <= 25)
    }

    @Test("Binary files are reported, not dumped")
    func binary() throws {
        let url = try temporaryFile(named: "blob.bin", contents: Data([0x00, 0x01, 0x02, 0xFF]))
        #expect(throws: PreviewError.binaryContent) {
            try PreviewPipeline.html(for: url, assets: assets)
        }
    }
}
