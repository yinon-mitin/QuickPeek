# Roadmap

QuickPeek aims to replace QLAppBundle, QLC, QLCodec-mkv, QLMarkdown, QuickLook Video,
Syntax Highlight and similar single-purpose plugins with one native, lightweight app.

Principles: Apple frameworks first (VideoToolbox, AudioToolbox, TextKit, JavaScriptCore);
no bundled ffmpeg or other large codec libraries; every parser covered by `swift test`.
No settings UI: QuickPeek fills gaps in macOS with sensible defaults and stays out of the way;
extensions are switched on and off in System Settings like any other.

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

- **0.6** — app packages: `.ipa`, `.apk` (binary manifest and resource table, checked
  against androguard), `.xcarchive`; icons as Finder thumbnails; shared code in one
  framework (app under 4 MB).

- **Unreleased** — folders preview as a file tree; archive and torrent trees open with their
  folders expanded.

## Next

1. **Peeking inside archives** — preview a file inside an archive without extracting it
   to disk; archive thumbnails.
2. **SQLite databases** — tables, columns, row counts and the first rows, through the
   system libsqlite3.
3. **Jupyter notebooks** — cells, Markdown and outputs instead of the raw JSON shown now.

## Not planned

- **More video containers.** macOS already plays MPEG-TS, M2TS and MTS (H.264, MPEG-2;
  AAC, AC-3, E-AC-3) and Ogg audio. Most AVI files are Xvid/DivX, which VideoToolbox
  cannot decode, so a demuxer would mostly report an unsupported codec; FLV left with
  Flash. A working MPEG-TS demuxer is kept on the `shelved/mpeg-ts` branch
  in case HEVC in TS, the one case macOS misses, turns out to matter.

## Later

- App icon for QuickPeek (the host app still uses the generic icon).
- A MediaExtension format reader (macOS 15+) so apps that opt in, such as QuickTime Player,
  could open MKV/WebM through QuickPeek's demuxer. Needs Developer ID signing.
- RAW photos from cameras newer than the installed macOS: show the JPEG preview embedded
  in the RAW file until Apple adds the camera.
- Subtitles (SRT/ASS tracks in MKV) in the player.
- Developer ID signing, notarization and a Homebrew cask.
