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
- **0.3** — archives (system libarchive: ZIP, TAR, RAR, RAR5, 7-Zip, ISO…) and torrents
  as native SwiftUI previews. Office documents, RAW photos, WebP, HEIC and ICO are left to
  macOS, which previews them itself.

- **0.4** — no more WebKit: code in TextKit 2 with highlight.js in JavaScriptCore,
  Markdown through Foundation's parser with native tables, CSV in an NSTableView.

- **0.5** — file details (MediaInfo replacement): video/audio, photos/RAW with EXIF and
  GPS, PDF/Office/fonts/text, archives, torrents and apps, in Finder's context menu and an
  ⓘ panel in previews.

## Next

1. **App bundles** — `.app`, `.ipa`, `.xcarchive`, `.apk`: icon, identifiers, version,
   entitlements and provisioning profile; icons as Finder thumbnails.
2. **More containers** — AVI, FLV, MPEG-TS and Ogg demuxers on the same pipeline
   (codecs macOS can decode only).
3. **Jupyter notebooks.**
4. **Archive thumbnails and peeking inside** — preview a file inside an archive without
   extracting it to disk.

## Later

- A MediaExtension format reader (macOS 15+) so apps that opt in, such as QuickTime Player,
  could open MKV/WebM through QuickPeek's demuxer. Needs Developer ID signing.
- Settings window: themes, font size, line numbers, autoplay and volume.
- RAW photos from cameras newer than the installed macOS: show the JPEG preview embedded
  in the RAW file until Apple adds the camera.
- Subtitles (SRT/ASS tracks in MKV) in the player.
- Developer ID signing, notarization and a Homebrew cask.
