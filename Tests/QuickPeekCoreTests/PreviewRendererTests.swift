import Testing
@testable import QuickPeekCore

@Suite("PreviewRenderer")
struct PreviewRendererTests {
    let assets = PreviewAssets(styles: ["/* theme */"], scripts: ["/* hljs */"])

    @Test("HTML escaping")
    func escaping() {
        #expect(HTML.escape("<a href=\"x\">&'</a>") == "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;")
    }

    @Test("Code is escaped and tagged with its language")
    func code() {
        let html = PreviewRenderer.render(
            kind: .code(language: "yaml"),
            text: "key: <script>alert(1)</script>\n",
            fileName: "a.yaml",
            assets: assets
        )
        #expect(html.contains("<code class=\"hljs language-yaml\">"))
        #expect(html.contains("key: &lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!html.contains("<script>alert(1)"))
        #expect(html.contains("/* hljs */"))
        #expect(html.contains("/* theme */"))
    }

    @Test("Every preview blocks network access with a CSP")
    func contentSecurityPolicy() {
        let html = PreviewRenderer.render(kind: .plainText, text: "x", fileName: "x", assets: assets)
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("default-src 'none'"))
    }

    @Test("Markdown source is embedded as a JS string that cannot close the script tag")
    func markdown() {
        let html = PreviewRenderer.render(
            kind: .markdown,
            text: "# Title\n</script><img src=x onerror=alert(1)>",
            fileName: "README.md",
            assets: assets
        )
        #expect(!html.contains("</script><img"))
        #expect(html.contains("\\u003c/script\\u003e"))
        #expect(html.contains("id=\"markdown\""))
    }

    @Test("Tables render a header row and escape cells")
    func table() {
        let html = PreviewRenderer.render(
            kind: .table(delimiter: nil),
            text: "name;value\n<b>x</b>;1\n",
            fileName: "data.csv",
            assets: assets
        )
        #expect(html.contains("<th>name</th><th>value</th>"))
        #expect(html.contains("<td>&lt;b&gt;x&lt;/b&gt;</td><td>1</td>"))
    }

    @Test("Large tables are truncated with a notice")
    func tableTruncation() {
        let text = (0...50).map { "r\($0),v" }.joined(separator: "\n")
        let html = PreviewRenderer.render(
            kind: .table(delimiter: ","),
            text: text,
            fileName: "big.csv",
            assets: assets,
            options: RenderOptions(maxTableRows: 10)
        )
        #expect(html.contains("<td>r9</td>"))
        #expect(!html.contains("<td>r10</td>"))
        #expect(html.contains("class=\"truncated\""))
    }
}
