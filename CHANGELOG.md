# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.4] - 2026-09-11

### Fixed

- Book clubs: a new club's share is now saved in the same CloudKit batch
  as its root record. Saving the share alone is rejected with "An added
  share is being saved without its rootRecord", so development never
  created the system `cloudkit.share` type and production club creation
  failed with "Cannot create new type cloudkit.share in production schema"

## [0.2.3] - 2026-09-11

### Fixed

- Book clubs: joining a shared club no longer fails with "SharedDB does
  not support Zone Wide queries" — participant reads are scoped to the
  share's record zone, discovered from the accepted share
- Book clubs: the club's root record is saved before its share, so
  CloudKit creates the schema types one at a time instead of failing a
  first-time atomic batch

## [0.2.2] - 2026-09-11

### Fixed

- Book clubs: when CloudKit cannot create the club's share, the app now
  rolls back the half-created local club and shows a plain "sharing is
  unavailable" message instead of the raw CloudKit transport error

## [0.2.1] - 2026-09-11

### Added

- Reader themes: the reading surface switches between the cream "Light"
  paper and a warm "Dark" theme from the macOS typography popover and the
  iOS reader settings; light remains the default, and the chrome,
  Contents, and Notes sheets follow the system appearance
- Sandboxed Mac App Store package (`make mas-pkg`) with a security-scoped
  library root bookmark, for TestFlight/App Store distribution

### Fixed

- iOS: the Clubs tab's "New Book Club" and "Join with a Code" buttons —
  both the empty-state actions and the toolbar menu — now open their sheets
- Reader: Contents/Marks/chapter-note sheets no longer flash light before
  settling into the system appearance

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

[Unreleased]: https://github.com/nathanstefanik/margins/compare/v0.2.4...HEAD
[0.2.4]: https://github.com/nathanstefanik/margins/releases/tag/v0.2.4
[0.2.3]: https://github.com/nathanstefanik/margins/releases/tag/v0.2.3
[0.2.2]: https://github.com/nathanstefanik/margins/releases/tag/v0.2.2
[0.2.1]: https://github.com/nathanstefanik/margins/releases/tag/v0.2.1
[0.2.0]: https://github.com/nathanstefanik/margins/releases/tag/v0.2.0
[0.1.0]: https://github.com/nathanstefanik/margins/releases/tag/v0.1.0
