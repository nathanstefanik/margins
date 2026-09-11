# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-09-11

### Added

- Native iOS app: `Library`/`Search` shell, structured outline, reader with
  tap zones and hardware keys, note capture from text selection, highlights,
  chapter marks, full-height chapter-note editor, "Open in Margins" from
  Files/Mail, Dynamic Type, and VoiceOver labels
- Private **book clubs** (one book per club): four-character invite code,
  CloudKit sharing with an automatic local-only fallback, and a merged view
  of every member's notes — overlapping highlights cluster under one quoted
  passage, with spoiler protection on by default
- Structured **chapter outline** on macOS and iOS: front/back matter in
  collapsed groups, Part/Book headings, and body chapters numbered from one
- Anchored **marks** in chapter notes (parse/serialize/CRUD in the core,
  rendered in both apps, lossless round-trip)
- iOS library root in the iCloud Documents container with a runtime local
  fallback and `NSFileVersion` conflict surfacing
- Device signing on a physical iPhone (gitignored local xcconfig) and
  simulator-verified import → read → annotate → export flows

### Changed

- Core rewritten in Swift; storage format unchanged. The macOS app, iOS
  app, and core now share one Swift package and one toolchain — no Rust
  cross-compilation or UniFFI bridge. Files written by the Rust core
  (0.1.0) open as-is; a Rust-written sample library is kept as a test
  fixture.
- The version source is now `apple/VERSION` (read by `make-app.sh` and
  the release workflow's tag check).
- iOS redesigned for the iOS 26 content-under-controls model: a
  `Library`/`Search` tab anatomy that adapts from a floating tab bar to a
  sidebar, a dedicated search tab, glass only on the control plane, a
  zoom transition from cover to reader, size-class layout instead of
  orientation, and shared geometry/motion tokens.

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

[Unreleased]: https://github.com/nathanstefanik/margins/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/nathanstefanik/margins/releases/tag/v0.2.0
[0.1.0]: https://github.com/nathanstefanik/margins/releases/tag/v0.1.0
