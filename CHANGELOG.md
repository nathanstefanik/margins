# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Core rewritten in Swift; storage format unchanged. The macOS app, iOS
  app, and core now share one Swift package and one toolchain — no Rust
  cross-compilation or UniFFI bridge. Files written by the Rust core
  (0.1.0) open as-is; a Rust-written sample library is kept as a test
  fixture.
- The version source is now `apple/VERSION` (read by `make-app.sh` and
  the release workflow's tag check).

### Removed

- Tauri/Linux frontend. Margins is macOS and iOS only.
- Rust core, UniFFI bridge, and the xcframework build plumbing
  (`make core`, `make ios-core`); the library sync export/import feature
  was not carried over.

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
