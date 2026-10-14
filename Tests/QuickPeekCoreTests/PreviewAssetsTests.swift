import Foundation
import Testing
@testable import QuickPeekCore

@Suite("PreviewAssets")
struct PreviewAssetsTests {
    let vendor = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Vendor", isDirectory: true)

    @Test("Loads highlight.js before its extra languages, then markdown-it")
    func scriptOrder() throws {
        let assets = try PreviewAssets.load(from: vendor)
        let core = try #require(assets.scripts.firstIndex { $0.contains("Highlight.js v11") })
        let dockerfile = try #require(assets.scripts.firstIndex { $0.contains("hljs.registerLanguage(\"dockerfile\"") })
        #expect(core < dockerfile)
        #expect(assets.scripts.contains { $0.contains("markdownit") })
    }

    @Test("Themes switch with the system appearance")
    func themes() throws {
        let assets = try PreviewAssets.load(from: vendor)
        #expect(assets.styles.count == 2)
        #expect(assets.styles[0].hasPrefix("@media (prefers-color-scheme: light)"))
        #expect(assets.styles[1].hasPrefix("@media (prefers-color-scheme: dark)"))
    }

    @Test("A missing vendor folder is an error")
    func missing() {
        #expect(throws: (any Error).self) {
            try PreviewAssets.load(from: URL(fileURLWithPath: "/nonexistent-quickpeek"))
        }
    }
}
