# QuickPeek

A free, open-source alternative to a drawer full of small Quick Look utilities.
One native app previews the files macOS leaves blank: source code, configs,
Markdown, tables, archives, torrents — and MKV/WebM video, played and
thumbnailed without ffmpeg.

QuickPeek uses Apple's own frameworks wherever they exist. Video is decoded by
VideoToolbox and AudioToolbox (hardware-accelerated where the Mac supports it);
QuickPeek only adds what macOS lacks, such as a Matroska/WebM demuxer written in
Swift. The result is a few megabytes instead of the 50–150 MB that bundled-codec
plugins weigh.

## What it previews

| Kind | Formats | Rendering |
|------|---------|-----------|
| Code and config | YAML, JSON, TOML, INI, XML, Swift, Python, Shell, Ruby, JS, Go, Rust, C/C++, Java, Kotlin, C#, PHP, Lua, SQL, CSS/SCSS, Dockerfile, Makefile, Protobuf, Terraform, GraphQL, diffs and more | Native text view (TextKit 2) with [highlight.js](https://highlightjs.org) running in JavaScriptCore — no WebKit. Text appears instantly; colours follow |
| Markdown | `.md`, `.markdown` | GitHub-flavoured Markdown parsed by Foundation, laid out natively: real tables, lists, task lists, highlighted code blocks |
| Tables | CSV, TSV, semicolon- and pipe-separated | Native table with row numbers and a sticky header; delimiter is detected automatically |
| Text | `.log` and other text macOS does not preview | Monospaced, wrapped |
| Archives | ZIP, TAR (gzip, bzip2, xz), RAR, RAR5, 7-Zip, ISO, CPIO, XAR, CAB, LHA, single `.gz`/`.bz2`/`.xz` | File tree with sizes and dates, read with the libarchive built into macOS — nothing is extracted. Encrypted archives are labelled |
| Torrents | `.torrent` (BitTorrent v1, v2, hybrid) | Files, size, info hash, pieces, trackers; one click copies the magnet link (private trackers' passkeys are left out of it) |
| Video | `.mkv`, `.webm`, `.mka` | Native player and Finder thumbnails. Video: H.264, HEVC, VP9, AV1 (Macs with an AV1 decoder, M3 and later). Audio: AAC, Opus, FLAC, AC-3, E-AC-3, MP3 |

macOS already previews Word/Excel/PowerPoint, RAW photos (ARW, CR3, NEF…),
WebP, HEIC, ICO and PDF by itself, so QuickPeek leaves those to the system.

Previews follow the system light/dark appearance. Files larger than 2 MB are
shown up to the limit, tables up to 5,000 rows. Codecs macOS cannot decode
(for example Vorbis, Theora, WMV) are reported instead of played — QuickPeek
does not ship ffmpeg. See the [roadmap](docs/ROADMAP.md) for what comes next.

## Install

Requires macOS 26 or newer.

```sh
brew install xcodegen
script/build.sh      # runs the tests, builds build/QuickPeek.app
script/install.sh    # copies it to /Applications and enables the extension
```

If another Quick Look extension handles the same files (for example Syntax
Highlight, PreviewYaml, QLC, QLCodec-mkv or Webm Quicklook), macOS picks one of
them. Turn the others off in **System Settings → General → Login Items &
Extensions → Quick Look**.

## Privacy and security

Previews render untrusted files, so the extensions are built defensively:

- They run in the App Sandbox with read-only access to the file being previewed and no
  network access. Nothing referenced by a file (remote images, links) is ever fetched.
- No web views: Markdown is laid out natively and raw HTML in it is shown as text.
- The only bundled code is highlight.js, pinned by SHA-256 checksums (`Vendor/`); builds
  never touch the network. It runs in JavaScriptCore inside the sandbox (the preview
  extension may JIT-compile it, which roughly halves highlighting time).

## Development

```
Sources/QuickPeekCore    file classification, text decoding, CSV parsing
Sources/QuickPeekText    highlight.js in JavaScriptCore, Markdown renderer, native document views
Sources/QuickPeekMedia   Matroska/WebM demuxer, CoreMedia bridge, frame extraction, player
Sources/QuickPeekFormats torrents (bencode), archive listings (system libarchive), file trees
Sources/CArchive         declarations for the system libarchive (the SDK has no header)
Tests/                   swift test (media tests use tiny fixtures from script/make_fixtures.sh)
PreviewExtension         Quick Look preview: player, archive/torrent lists, document views
ThumbnailExtension       Finder thumbnails for video
App                      host app; also a CLI for debugging previews
Vendor                  pinned highlight.js and markdown-it
project.yml             XcodeGen spec for the app and extension
```

Rendering logic lives in `QuickPeekCore` and is covered by `swift test`. To see a
preview exactly as the extension draws it, without Quick Look:

```sh
QP=build/QuickPeek.app/Contents/MacOS/QuickPeek
$QP --snapshot file.yaml out.png [--dark]   # any document, archive or torrent preview as a PNG
$QP --play movie.mkv                        # the Quick Look player in a window
$QP --play-snapshot movie.mkv out.png       # play briefly, save the player as a PNG
$QP --thumbnail movie.mkv out.png [size]    # the Finder thumbnail frame
$QP --probe movie.mkv                       # tracks and frame counts, like ffprobe
```

The demuxer is checked against the official Matroska conformance files
([ietf-wg-cellar/matroska-test-files](https://github.com/ietf-wg-cellar/matroska-test-files)):
frame counts match ffprobe on all eight, including the damaged and live-stream ones.

To bump highlight.js, edit the version in `script/fetch_vendor.sh`
and run `script/fetch_vendor.sh --update-checksums`.

## License

MIT, see [LICENSE](LICENSE). Bundled third-party code: highlight.js (BSD-3-Clause). Archives are read with the libarchive that ships with macOS
(BSD-2-Clause); some test archives come from libarchive's test suite.
