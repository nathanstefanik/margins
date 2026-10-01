# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Reader typeface choice on macOS (typography popover and Settings) and a
  new Easy face — bundled Atkinson Hyperlegible Next (SIL OFL 1.1) with
  fixed extra letter/word spacing and a line-height boost for low-vision
  readers

### Changed

- Reader serif is now Charter and sans is now Seravek on both platforms
- macOS text size range moved up one step to 80–210 % with a 120 % default
  (the old 70 % size was too small)

### Fixed

- macOS: ⌘= now enlarges text (previously only ⌘⇧= did); text-size
  controls disable at the ends of the range
- macOS: opening the notes pane focuses the editor
- macOS: opening a search hit selects its book in the sidebar
- macOS: switching the library directory saves and closes the open book
  first, so its note and position land in the old library
- macOS: moving the book selection with j/k while a club is shown switches
  the detail to the book
- macOS: reader-only menu items are disabled with no book open, and each
  error banner keeps its own dismiss timer

## [0.6.2] - 2026-10-01

### Changed

- iOS invite-code and notes export/clear actions are compact icon buttons
  beside the text they act on instead of large labelled buttons
- iOS reader chrome sits higher, clear of the page text
- iOS sheets use the system close button; the club card no longer repeats
  the club name, has more padding, and club rows show member count and date
  on one line

### Fixed

- Bookmarks pin a fixed content spot: a pin counts as on the page whenever
  the visible page range contains its CFI, so reflow no longer orphans
  bookmarks or lets a page collect duplicate pins
- The bookmark key/button toggles: it adds a pin on an unmarked page,
  removes the pin when exactly one is visible, and offers a picker to
  choose which bookmark to remove when several share the page

## [0.6.1] - 2026-09-29

### Changed

- iOS reader controls have larger touch targets and clearer separation;
  native actions use larger system buttons and stack at larger text sizes
- Mark rows group edit and delete in an accessible action menu; mark editing
  supports multiline notes with separate Save and Cancel controls
- Bookmarks, contents, and note links expose full-row touch targets, and
  reader settings include an explicit Close action
- Reader acceptance tests wait for settled navigation and geometry instead
  of observing intermediate layout states

### Fixed

- macOS window resizing preserves the reading passage when layout
  notifications are coalesced and the final page geometry is unchanged

## [0.6.0] - 2026-09-29

### Added

- Commonplace notebooks (iOS): a Notebooks tab of plain-markdown notebooks
  under `notebooks/` where passages from any book sit between your own
  prose; every passage references its mark and opens in its original
  context, and a deleted mark leaves the cached quote marked "source
  removed"
- Full-text library search (iOS): every book's text is indexed on the
  device as plain files outside the library (never synced or backed up)
  and searched with stemming, typo tolerance, partial words, and phrase
  ranking — no network, works in Airplane mode
- "Add to Notebook…" from the reader's selection menu, search results, and
  the marks sheet; "Search Library" from inside the reader; the marks
  sheet shows which notebooks cite each mark
- Hits without a saved location open their chapter and flash the passage,
  and a mark created from such a hit remembers its location afterwards

### Changed

- Notes search on both platforms now finds mark quotes and thoughts,
  matches word forms and accents ("deceive" finds "deceived", "cafe" finds
  "café"), and retries misspelled words; macOS opens a passage hit at its
  exact location

## [0.5.1] - 2026-09-21

### Removed

- Development plan documents (`docs/*-plan.md`) that had served their
  purpose and the `.vscode` editor recommendations; the README links only
  to living docs now

## [0.5.0] - 2026-09-21

### Added

- macOS adaptive reader pagination: single page or spread with layout
  preferences, spread-aware reading progress, and reading position preserved
  across window and layout changes
- Named bookmarks beside the reading position, on macOS and iOS
- Reader sidebar widens and toggles with Command-B; the back button has its
  own icon
- Offline reading on iOS: every opened EPUB keeps an eviction-proof local
  copy, evicted files re-download whenever the app is online, and opening a
  book iCloud has not downloaded fails fast with a clear message
- Book club management: club owner role, rename and display name, admin
  promotion, a management UI, and club snapshots that auto-publish after
  note saves; members can leave a club and joining is locked while a save
  is in flight

### Fixed

- Reader: first-paint reflow can no longer jump to the chapter start,
  concurrent layout loads cannot stall two webviews, and bookmarks survive
  relocation and book switches; the reader shows its page number and uses
  the reading typeface
- Book clubs: note sync, note deletion, and re-entering club creation work
  reliably; club activation stays off the library launch path; club sync
  falls back to local-only without the iCloud entitlement
- iOS: books whose notes have not downloaded yet now open

## [0.2.5] - 2026-09-11

### Fixed

- macOS: clicking a book club in the sidebar now opens it; selection
  previously highlighted the club without loading its detail or notes
- macOS: an already-open reader now follows search hits and sidebar opens
  to the new book or chapter instead of leaving the old page up while the
  title, notes, and position saves moved on
- iOS: the end-of-chapter "Write note" prompt now writes the note to the
  chapter it names; the editor had targeted the next chapter
- Book clubs: when CloudKit is missing the sharing types from its deployed
  schema, the app now says the schema needs deploying instead of "try
  again later", which could never succeed

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

[Unreleased]: https://github.com/nathanstefanik/margins/compare/v0.6.1...HEAD
[0.6.1]: https://github.com/nathanstefanik/margins/releases/tag/v0.6.1
[0.6.0]: https://github.com/nathanstefanik/margins/releases/tag/v0.6.0
[0.5.1]: https://github.com/nathanstefanik/margins/releases/tag/v0.5.1
[0.5.0]: https://github.com/nathanstefanik/margins/releases/tag/v0.5.0
[0.2.5]: https://github.com/nathanstefanik/margins/releases/tag/v0.2.5
[0.2.4]: https://github.com/nathanstefanik/margins/releases/tag/v0.2.4
[0.2.3]: https://github.com/nathanstefanik/margins/releases/tag/v0.2.3
[0.2.2]: https://github.com/nathanstefanik/margins/releases/tag/v0.2.2
[0.2.1]: https://github.com/nathanstefanik/margins/releases/tag/v0.2.1
[0.2.0]: https://github.com/nathanstefanik/margins/releases/tag/v0.2.0
[0.1.0]: https://github.com/nathanstefanik/margins/releases/tag/v0.1.0
