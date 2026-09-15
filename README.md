# Margins

Minimal EPUB reader for macOS and iOS with file-based, AI-friendly annotations.

Inspired by zathura's restraint: keyboard-first navigation, no clutter, your library stays on disk in plain formats you can sync, grep, and hand to an agent.

## Features (MVP)

- Import and browse EPUBs from a local library
- Progress feedback while importing EPUBs
- Paginated reader with vim-style keybindings
- Per-chapter markdown notes with YAML frontmatter
- Compiled per-book **notes page** (`N`) with one-click markdown export,
  copy-all, and clear-all (with a confirmation prompt)
- Full-text search across notes (`/` or `:search`)
- Private **book clubs** (one book per club): a four-character invite code,
  CloudKit sharing with an automatic local-only fallback, and a merged view
  of every member's notes — overlapping highlights cluster under one quoted
  passage, with spoiler protection on by default
  ([docs/book-clubs-plan.md](docs/book-clubs-plan.md))
- Choose the library directory with the in-app folder picker or **root** command

## Quick start

```bash
make run         # assemble and open build/Margins.app (needs full Xcode)
```

## Apple apps (macOS + iOS)

Native SwiftUI frontends sharing the same Swift core through one SwiftPM
package (`apple/`; see [docs/architecture.md](docs/architecture.md) for the
module map and [docs/ios-plan.md](docs/ios-plan.md) for the historical iOS
build-out).

Requirements:

- **full Xcode** (26.x): the iOS SDK for the iOS app, and `swift test`
  silently runs nothing under a CLT-only toolchain.

```bash
make test        # run the Swift Testing suite (core + model)
make build       # build the Swift package (macOS)
make app         # assemble build/Margins.app (ad-hoc signed)
make run         # app + open it
make ios-build   # build the iOS app for the simulator (no signing)
```

The iOS app itself builds from `apple/ios/Margins.xcodeproj` (open in Xcode,
or `xcodebuild -project apple/ios/Margins.xcodeproj -scheme Margins -destination
'platform=iOS Simulator,name=iPhone 17 Pro'`). [docs/ios-plan.md](docs/ios-plan.md)
is the historical build-out, kept for reference.

**iOS TestFlight/App Store release**: the app record must exist in App Store
Connect first (bundle ID `io.github.nathanstefanik.margins`, registered with
the iCloud container on developer.apple.com — automatic signing creates the
App ID during the archive if it is missing). Then, per upload:

```bash
make ios-bump    # increment CURRENT_PROJECT_VERSION (TestFlight rejects reused numbers)
make ios-archive # Release archive at build/Margins.xcarchive
```

then in Xcode's Organizer: *Distribute App → App Store Connect → Upload*.
`ITSAppUsesNonExemptEncryption` is already `false` in `Info.plist`, so no
encryption-compliance answer is needed per build.

**macOS App Store/TestFlight release**: the Mac platform of the same App
Store Connect record takes a sandboxed, distribution-signed installer
package. Signing assets (Apple Distribution + Mac Installer Distribution
certificates and a `MAC_APP_STORE` profile for the bundle ID) live outside
the repo; point the packaging script at them:

```bash
MAC_APP_IDENTITY="Apple Distribution: NAME (TEAMID)" \
MAC_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: NAME (TEAMID)" \
MARGINS_PROFILE=/path/to/Margins.provisionprofile \
MARGINS_KEYCHAIN=/path/to/mas.keychain-db \
make mas-pkg   # build/Margins-vX.Y.Z-mas.pkg
```

Then upload with
`xcrun altool --upload-app -f build/Margins-vX.Y.Z-mas.pkg -t osx --apiKey KEYID --apiIssuer ISSUER`.
The App Store build is sandboxed: its library defaults to the app container,
and a custom root picked with the folder picker is remembered with a
security-scoped bookmark (`LibraryRootBookmark`); the DMG build is
unaffected.

**iOS device signing** (never committed): copy
`apple/ios/Signing.local.xcconfig.example` to `Signing.local.xcconfig` and
fill in your Team ID — the project loads it via an optional include. In
Xcode, sign in under *Settings → Accounts* so automatic provisioning can
register devices and create profiles; on the phone, enable *Settings →
Privacy & Security → Developer Mode* (the toggle appears after the device
is paired with Xcode). The library lives in the iCloud Documents container
`iCloud.io.github.nathanstefanik.margins` when an iCloud account is
available — visible in the Files app and pointable at from the Mac via
`MARGINS_LIBRARY_ROOT` — falling back to local `Documents/Library` at
runtime otherwise; sync happens through iCloud, conflict detection surfaces
`NSFileVersion` conflicts rather than discarding them.

macOS keybindings:

| Key | Action |
|-----|--------|
| `j` / `k` | Next / previous page (reader) or move selection (library) |
| Space / arrows / PgDn / PgUp | Turn pages (reader) |
| `gg` / `G` | First / last page of chapter |
| `n` / `p` | Next / previous chapter |
| `N` | Compiled notes page for the selected book (book view; also ⇧⌘N) |
| `t` | Toggle outline / contents views on the notes page |
| `i` / `Enter` | Open and focus the notes pane (reader) |
| `b` | Bookmark this page (reader) |
| `B` | Bookmarks list (reader) |
| `Esc` | Notes editor → reader; reader → close notes pane; notes page → book detail; pane closed → library |
| `l` | Library (from the reader); back to book detail (notes page) |
| `o` | Import EPUB (also ⌘O) |
| `Enter` | Open selected book (library) |
| `/` | Search notes (also ⌘F) |
| `?` | Keyboard shortcuts cheat sheet (also ⌘/) |
| ⌘S | Save note |
| ⌘+ / ⌘− / ⌘0 | Bigger / smaller / reset text size |
| ⌘B | Toggle the library sidebar |
| ⌘, | Settings (typography, library directory) |
| Trackpad | Two-finger scroll turns pages |

macOS reader layout: the typography popover (textformat button) offers
**Automatic**, **One Page**, and **Two Pages**. Automatic uses a single
centered column or a two-page spread based on the actual window width and
text size; One Page always keeps one column; Two Pages falls back to one
when the minimum readable measure cannot fit (the popover says so). The
choice persists locally under `reader.pageLayout.macos` and is separate
from Reset Typography. Footer page numbers are chapter-local and describe
what is visible — "Pages 4–5 of 20" for a spread, "Page 20 of 20" for a
single page. The iOS reader keeps its full-width single column.

## Configuration

| Variable | Purpose |
|----------|---------|
| `MARGINS_DATA_DIR` | App data directory (config + default library) |
| `MARGINS_LIBRARY_ROOT` | Use a specific library directory (e.g. synced folder) |

See [docs/storage.md](docs/storage.md) for the on-disk layout.

## Status

Roadmap detail: [docs/architecture.md](docs/architecture.md) (shape);
[docs/apple-only-plan.md](docs/apple-only-plan.md) records the migration
that produced it.

**Done**

- Swift core: library, EPUB parsing, notes, marks, search, markdown export,
  chapter classification (`matter`, outline `level`, per-file `sections`)
- macOS SwiftUI app: library, paginated reader, notes pane, compiled notes
  page, search overlay, keyboard-first control
- Structured **chapter outline** on macOS and iOS: front/back matter in
  collapsed groups, Part/Book headings, body chapters numbered from one;
  every TOC entry in a multi-chapter file is its own row
- Anchored **marks** in chapter notes (parse/serialize/CRUD in the core,
  rendered in both apps, lossless round-trip)
- Shared Apple SwiftPM package over one Swift core (macOS + iOS)
- iOS app skeleton + **Library scene**: cover grid, document-picker import,
  delete with confirmation, notes search; iCloud Documents library root with
  runtime local fallback; simulator-verified (light/dark, iPhone/iPad)
- iOS **book detail** (Contents / Notes tabs, compiled marks, ShareLink
  export) and the **Reader**: shared epub.js bundle, tap zones + hardware
  keys, immersive chrome, typography, CFI position persistence — and a
  latent macOS chapter-jump bug fixed along the way
- iOS **note capture while reading**: text selection → *Note* / *Highlight*
  in the native edit menu, a page-anchored capture affordance with draft
  autosave, highlight-without-note (epub.js overlays), chapter marks sheet,
  full-height chapter-note editor, and a silenceable end-of-chapter prompt
- iOS "Open in Margins" from Files/Mail (`onOpenURL`), VoiceOver labels
  with no gesture-only actions, Dynamic Type throughout
- **Device signing + real iCloud**: team ID in a gitignored local xcconfig,
  app installs to a paired iPhone via
  `xcodebuild -allowProvisioningUpdates`, and the library resolves the real
  ubiquity container on device (Files-visible, Mac-pointable)
- **Private book clubs** end to end: club/roster/invite-code core with
  spoiler gating and CFI passage clustering; CloudKit share transport
  (`CKShare`, public invite-code records, participant removal) with an
  automatic local-only fallback for unsigned builds; club model + UI on
  macOS (sidebar section, merged document, export/copy) and iOS (Clubs tab);
  simulator-verified on iOS with a DEBUG club fixture

**In progress**

- Definition-of-done pass on real hardware: walk import → read → five
  marks + one chapter note → compiled notes → export by hand, including
  the gesture-only paths (native edit menu, tap zones, swipes) and the
  highlight overlay's visual paint — the data paths are verified
  end-to-end on the simulator via DEBUG launch seams

**Next**

- Mark-text search

## License

GPL-3.0-or-later — fork freely; derivatives must remain open source under the same license.
