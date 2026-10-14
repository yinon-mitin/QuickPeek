# Roadmap

QuickPeek aims to replace QLAppBundle, QLC, QLCodec-mkv, QLMarkdown, QuickLook Video,
Syntax Highlight and similar single-purpose plugins with one native, lightweight app.

Principles: Apple frameworks first (VideoToolbox, AudioToolbox, TextKit, JavaScriptCore);
no bundled ffmpeg or other large codec libraries; every parser covered by `swift test`.

## Done

- **0.1** — code, config, Markdown and tables (WKWebView renderer, highlight.js, markdown-it).
- **0.2** — MKV/WebM: Swift demuxer (resyncs on damaged files; matches ffprobe on the
  official conformance suite), Finder thumbnails, native player with hardware decoding,
  A/V sync and keyframe seeking.

## Next

1. **Native text rendering** — replace the WKWebView renderer with TextKit 2:
   highlight.js running in JavaScriptCore (no WebKit process), Markdown parsed with
   cmark-gfm into attributed text with real tables. Faster to open, less memory.
2. **App bundles** — `.app`, `.ipa`, `.xcarchive`, `.apk`: icon, identifiers, version,
   entitlements and provisioning profile; icons as Finder thumbnails.
3. **More containers** — AVI, FLV, MPEG-TS and Ogg demuxers on the same pipeline
   (codecs macOS can decode only).
4. **Jupyter notebooks and archives** (ZIP/TAR tree without extracting).

## Later

- A MediaExtension format reader (macOS 15+) so apps that opt in, such as QuickTime Player,
  could open MKV/WebM through QuickPeek's demuxer. Needs Developer ID signing.
- Settings window: themes, font size, line numbers, autoplay and volume.
- Subtitles (SRT/ASS tracks in MKV) in the player.
- Developer ID signing, notarization and a Homebrew cask.
