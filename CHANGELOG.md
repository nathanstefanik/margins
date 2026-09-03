# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-03

Initial release.

### Added

- Cross-platform EPUB reader (Linux via Tauri + epub.js, macOS via native
  SwiftUI) over a shared Rust core (`margins-core`)
- Local library: import and browse EPUBs, choose the library directory
- Paginated reader with vim-style keybindings and command mode (`:`)
- Per-chapter markdown notes with YAML frontmatter; annotations stored as
  plain files you can sync, grep, and diff
- Compiled per-book notes page with markdown export, copy-all, and clear-all
- Full-text search across notes
- Library tree export/import for external drives and sync folders
- Universal (arm64 + x86_64) macOS app bundle via `make mac-app-universal`
- Linux `.deb` / `.rpm` / `.AppImage` bundles via Tauri

[Unreleased]: https://github.com/nathanstefanik/margins/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/nathanstefanik/margins/releases/tag/v0.1.0
