import Foundation

/// Stylesheets and scripts inlined into every preview (themes, highlight.js, markdown-it).
public struct PreviewAssets: Sendable {
    public var styles: [String]
    public var scripts: [String]

    public init(styles: [String], scripts: [String]) {
        self.styles = styles
        self.scripts = scripts
    }

    /// Reads the vendored assets laid out by `script/fetch_vendor.sh`.
    public static func load(from directory: URL) throws -> PreviewAssets {
        func read(_ path: String) throws -> String {
            try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8)
        }

        var scripts = [try read("highlight.min.js")]
        let languages = directory.appendingPathComponent("languages", isDirectory: true)
        let languageFiles = try FileManager.default.contentsOfDirectory(atPath: languages.path)
            .filter { $0.hasSuffix(".js") }
            .sorted()
        for file in languageFiles {
            scripts.append(try read("languages/\(file)"))
        }
        scripts.append(try read("markdown-it.min.js"))

        let styles = [
            "@media (prefers-color-scheme: light) {\n\(try read("github.min.css"))\n}",
            "@media (prefers-color-scheme: dark) {\n\(try read("github-dark.min.css"))\n}",
        ]
        return PreviewAssets(styles: styles, scripts: scripts)
    }
}

public struct RenderOptions: Sendable {
    /// Bytes read from disk; the rest of the file is omitted with a notice.
    public var maxBytes: Int
    /// Rows rendered for tables, header included.
    public var maxTableRows: Int

    public init(maxBytes: Int = 2 * 1024 * 1024, maxTableRows: Int = 5000) {
        self.maxBytes = maxBytes
        self.maxTableRows = maxTableRows
    }
}

/// Builds a self-contained HTML document for one file.
public enum PreviewRenderer {
    public static func render(
        kind: FileKind,
        text: String,
        fileName: String,
        assets: PreviewAssets,
        options: RenderOptions = .init(),
        truncated: Bool = false
    ) -> String {
        var body: String
        var boot = ""

        switch kind {
        case .code(let language):
            body = "<pre class=\"code\"><code class=\"hljs language-\(HTML.escape(language))\">\(HTML.escape(text))</code></pre>"
            boot = highlightBoot
        case .notebook:
            // Dedicated notebook rendering is on the roadmap; until then show the raw JSON.
            body = "<pre class=\"code\"><code class=\"hljs language-json\">\(HTML.escape(text))</code></pre>"
            boot = highlightBoot
        case .markdown:
            body = "<article id=\"markdown\" class=\"markdown-body\"></article>"
            boot = markdownBoot(source: text)
        case .table(let delimiter):
            body = table(text: text, delimiter: delimiter ?? CSVParser.sniffDelimiter(text), maxRows: options.maxTableRows)
        case .plainText, .archive, .image, .video:
            body = "<pre class=\"code\"><code class=\"nohighlight\">\(HTML.escape(text))</code></pre>"
        }

        if truncated {
            body += "<p class=\"truncated\">File is larger than \(options.maxBytes / 1024) KB; the rest is not shown.</p>"
        }

        return document(title: fileName, kindClass: kindClass(kind), body: body, boot: boot, assets: assets)
    }

    private static func kindClass(_ kind: FileKind) -> String {
        switch kind {
        case .code, .notebook: return "kind-code"
        case .plainText, .archive, .image, .video: return "kind-text"
        case .markdown: return "kind-markdown"
        case .table: return "kind-table"
        }
    }

    private static func table(text: String, delimiter: Character, maxRows: Int) -> String {
        let rows = CSVParser.parse(text, delimiter: delimiter, maxRows: maxRows + 1)
        guard let header = rows.first else {
            return "<p class=\"empty\">Empty table</p>"
        }
        let shown = rows.prefix(maxRows)
        var html = "<table><thead><tr>"
        html += header.map { "<th>\(HTML.escape($0))</th>" }.joined()
        html += "</tr></thead><tbody>"
        for row in shown.dropFirst() {
            html += "<tr>" + row.map { "<td>\(HTML.escape($0))</td>" }.joined() + "</tr>"
        }
        html += "</tbody></table>"
        if rows.count > maxRows {
            html += "<p class=\"truncated\">Showing the first \(maxRows - 1) rows.</p>"
        }
        return html
    }

    private static let highlightBoot = """
    if (window.hljs) {
      hljs.configure({ ignoreUnescapedHTML: true });
      document.querySelectorAll('pre code.hljs').forEach(function (el) {
        try { hljs.highlightElement(el); } catch (e) {}
      });
    }
    """

    private static func markdownBoot(source: String) -> String {
        """
        (function () {
          var source = \(HTML.javaScriptString(source));
          var target = document.getElementById('markdown');
          if (!window.markdownit) { target.textContent = source; return; }
          var md = window.markdownit({
            html: false,
            linkify: true,
            highlight: function (code, lang) {
              if (window.hljs && lang && hljs.getLanguage(lang)) {
                try { return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value; } catch (e) {}
              }
              return '';
            }
          });
          target.innerHTML = md.render(source);
          target.querySelectorAll('pre > code').forEach(function (el) { el.classList.add('hljs'); });
        })();
        """
    }

    private static func document(title: String, kindClass: String, body: String, boot: String, assets: PreviewAssets) -> String {
        var html = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:">
        <meta name="color-scheme" content="light dark">
        <title>\(HTML.escape(title))</title>
        <style>\(baseStyle)</style>

        """
        for style in assets.styles {
            html += "<style>\(style.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive))</style>\n"
        }
        html += "</head><body class=\"\(kindClass)\">\n\(body)\n"
        for script in assets.scripts {
            html += "<script>\(HTML.inlineScript(script))</script>\n"
        }
        if !boot.isEmpty {
            html += "<script>\(boot)</script>\n"
        }
        html += "</body></html>\n"
        return html
    }

    static let baseStyle = """
    :root { --fg: #1f2328; --bg: #ffffff; --muted: #59636e; --border: #d1d9e0; --stripe: #f6f8fa; }
    @media (prefers-color-scheme: dark) {
      :root { --fg: #e6edf3; --bg: #0d1117; --muted: #9198a1; --border: #3d444d; --stripe: #151b23; }
    }
    html, body { margin: 0; background: var(--bg); color: var(--fg); }
    body { font: 13px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
    pre.code { margin: 0; padding: 12px 16px; }
    pre.code code, pre.code code.hljs { padding: 0; background: transparent; }
    code, pre { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 12px; }
    pre { white-space: pre-wrap; word-break: break-word; }
    .markdown-body { max-width: 900px; margin: 0 auto; padding: 24px 32px; font-size: 14px; line-height: 1.6; }
    .markdown-body h1, .markdown-body h2 { border-bottom: 1px solid var(--border); padding-bottom: .3em; }
    .markdown-body pre { background: var(--stripe); padding: 12px 16px; border-radius: 6px; }
    .markdown-body code { background: var(--stripe); padding: .15em .35em; border-radius: 4px; }
    .markdown-body pre code { background: transparent; padding: 0; }
    .markdown-body table { border-collapse: collapse; }
    .markdown-body th, .markdown-body td { border: 1px solid var(--border); padding: 4px 10px; }
    .markdown-body blockquote { margin: 0; padding: 0 1em; color: var(--muted); border-left: 4px solid var(--border); }
    .markdown-body img { max-width: 100%; }
    .kind-table table { border-collapse: collapse; font-size: 12px; margin: 0; }
    .kind-table th { position: sticky; top: 0; background: var(--stripe); text-align: left; font-weight: 600; }
    .kind-table th, .kind-table td { border: 1px solid var(--border); padding: 3px 8px; white-space: nowrap; }
    .kind-table tbody tr:nth-child(even) { background: var(--stripe); }
    .truncated, .empty { color: var(--muted); font-style: italic; padding: 8px 16px; margin: 0; }
    """
}
