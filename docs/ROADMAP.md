# Roadmap

## 0.1 — code, config, Markdown, tables (done)

- Syntax-highlighted previews for code and config files, theme follows light/dark mode.
- Markdown rendering with highlighted code blocks.
- CSV/TSV as tables with delimiter detection.
- Size limits, encoding detection, binary detection.
- `--render` / `--snapshot` debugging modes in the host app.

## 0.2 — notebooks and archives

- Jupyter notebooks: Markdown and code cells, text/image outputs (`image/png` as data URIs).
- Archives: ZIP, TAR, TAR.GZ as a file tree with sizes and dates, without extracting to disk.

## 0.3 — media and thumbnails

- Images macOS does not preview well (for example large SVGs) and WebM video through WebKit.
- Thumbnail extension: Finder icons for code, Markdown and tables, drawn from the same renderer.
- MKV/AVI need ffmpeg; decide whether that belongs in QuickPeek or stays with QLVideo.

## Later

- Settings window: theme choice, font size, line numbers, word wrap, size limits.
- Extension-less files (`Dockerfile` variants, dotfiles) through `public.data`, with content sniffing.
- Mermaid diagrams and KaTeX math in Markdown.
- Developer ID signing, notarization and a Homebrew cask.
