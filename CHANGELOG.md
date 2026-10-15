# Changelog

## 0.6.0 — 2026-10-15

- App packages: previews and Finder thumbnails for `.ipa`, `.apk` and `.xcarchive` (icon, version, identifier, minimum OS, permissions, provisioning profile).
- Finder's context menu shows the file's summary; its icons follow the menu's text colour.
- Archives that hold a single folder open with that folder's contents.
- New app icon.
- The shared code ships once, as a framework used by the app and its extensions: the app is under 4 MB.

## 0.5.0 — 2026-10-15

- File details, a MediaInfo replacement: video and audio, photos and RAW (EXIF, GPS), PDF and Office documents, fonts, text, archives, torrents and apps.
- Details in Finder's context menu and in an ⓘ panel on QuickPeek's previews; `QuickPeek --info` on the command line.

## 0.4.0 — 2026-10-14

- Documents render natively: code in TextKit with highlight.js running in JavaScriptCore, Markdown through Foundation's parser with real tables, CSV in a table view.
- WebKit, markdown-it and the network entitlement are gone.

## 0.3.0 — 2026-10-14

- Archives (ZIP, RAR, 7z, TAR and more, read with the system libarchive) and torrents as native previews.

## 0.2.0 — 2026-10-14

- MKV and WebM: a Matroska demuxer in Swift, Finder thumbnails, and a player using VideoToolbox and AudioToolbox.

## 0.1.0 — 2026-10-14

- First version: code, config, Markdown and table previews.
