# QuickPeek

One Quick Look extension for the files developers look at all day: source code,
configs, Markdown and tables. Select a file in Finder, press Space, and get a
highlighted, theme-aware preview instead of plain text.

QuickPeek is free and open source (MIT). It replaces a stack of single-format
plugins with one app.

## What it previews

| Kind | Formats | Rendering |
|------|---------|-----------|
| Code and config | YAML, JSON, TOML, INI, XML, Swift, Python, Shell, Ruby, JS, Go, Rust, C/C++, Java, Kotlin, C#, PHP, Lua, SQL, CSS/SCSS, Dockerfile, Makefile, Protobuf, Terraform, GraphQL, diffs and more | Syntax highlighting with [highlight.js](https://highlightjs.org) |
| Markdown | `.md`, `.markdown` | GitHub-flavoured rendering with [markdown-it](https://github.com/markdown-it/markdown-it), highlighted code blocks |
| Tables | CSV, TSV, semicolon- and pipe-separated | Real table with a sticky header; delimiter is detected automatically |
| Text | `.txt`, `.log`, other plain text | Monospaced, wrapped |

Previews follow the system light/dark appearance. Files larger than 2 MB are
shown up to the limit, tables up to 5,000 rows. See the [roadmap](docs/ROADMAP.md)
for what comes next (Jupyter notebooks, archives, images, video, thumbnails).

## Install

Requires macOS 14 or newer.

```sh
brew install xcodegen
script/build.sh      # runs the tests, builds build/QuickPeek.app
script/install.sh    # copies it to /Applications and enables the extension
```

If another Quick Look extension handles the same files (for example Syntax
Highlight or PreviewYaml), macOS picks one of them. Turn the others off in
**System Settings → General → Login Items & Extensions → Quick Look**.

## Privacy and security

Previews render untrusted files, so the extension is built defensively:

- It runs in the App Sandbox with read-only access to the file being previewed.
- Every preview carries a Content Security Policy of `default-src 'none'`. Remote
  images, scripts and fonts referenced by a file are never fetched.
- Markdown is rendered with raw HTML disabled, and file content is escaped before
  it reaches the page.
- All JavaScript is vendored and pinned with SHA-256 checksums (`Vendor/`). Builds
  never touch the network.

The extension holds the `network.client` entitlement only because WebKit's
content process does not start in a sandboxed extension without it.

## Development

```
Sources/QuickPeekCore   file classification, decoding, CSV parsing, HTML rendering
Tests/QuickPeekCoreTests  swift test
PreviewExtension        Quick Look extension (WKWebView)
App                     host app; also a CLI for debugging previews
Vendor                  pinned highlight.js and markdown-it
project.yml             XcodeGen spec for the app and extension
```

Rendering logic lives in `QuickPeekCore` and is covered by `swift test`. To see a
preview exactly as the extension draws it, without Quick Look:

```sh
build/QuickPeek.app/Contents/MacOS/QuickPeek --snapshot file.yaml out.png [--dark]
build/QuickPeek.app/Contents/MacOS/QuickPeek --render file.yaml > out.html
```

To bump highlight.js or markdown-it, edit the versions in `script/fetch_vendor.sh`
and run `script/fetch_vendor.sh --update-checksums`.

## License

MIT, see [LICENSE](LICENSE). Bundled third-party code: highlight.js (BSD-3-Clause),
markdown-it (MIT).
