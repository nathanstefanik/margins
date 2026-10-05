# Margins

Minimal EPUB reader for macOS and iOS with file-based, AI-friendly annotations.

Inspired by zathura's restraint: keyboard-first navigation, no clutter, your library stays on disk in plain formats you can sync, grep, and hand to an agent.

## Features

- Import and browse EPUBs from a local library
- Progress feedback while importing EPUBs
- Library shelves — Reading / Up next / Finished — plus a continue-reading
  card (iOS) and resume (macOS)
- Paginated reader with vim-style keybindings
- Reading papers: Light, Sepia, Dark, Night, or follow the system —
  matching the reading surface on both apps
- Justified text and chapter ornaments (drop cap + small caps) on both apps
- Chapter-scoped page scrubber: hover the footer on macOS, chrome rail on iOS
- Page indicator modes — page count, learned "~N min left" reading pace,
  or none
- Chapter-end page: pausing past a chapter's last page shows its marked
  quotes and note, with Write a thought / Continue
- `f` focus mode on macOS: sidebar and toolbar hide, footer fades when idle
- ⌘K command palette on macOS: fuzzy go-to for books, chapters, and commands
- Typeset placeholder covers: paper + ink per title, drawn in both apps
- Per-chapter markdown notes with YAML frontmatter
- Compiled per-book **notes page** (`N`) with one-click markdown export,
  copy-all, and clear-all (with a confirmation prompt)
- Full-text search across notes and passages (`/` or `:search` — hits
  include marks, chapter titles, and notebook prose)
- Commonplace **notebooks** (iOS): gather passages from any book with your
  own thoughts between them; every passage opens in its original context
- Forgiving full-text **library search** (iOS) over every book's text and
  your passages — stems, typos, and partial words — from a per-device
  plain-file index; nothing leaves the device
- Private **book clubs** (one book per club): a four-character invite code,
  CloudKit sharing with an automatic local-only fallback, and a merged view
  of every member's notes — overlapping highlights cluster under one quoted
  passage, with spoiler protection on by default. Saving a note publishes
  the club snapshot after a one-second debounce.
- Choose the library directory with the in-app folder picker or **root** command

## Quick start

```bash
make run         # assemble and open build/Margins.app (needs full Xcode)
```

## Apple apps (macOS + iOS)

Native SwiftUI frontends sharing the same Swift core through one SwiftPM
package (`apple/`; see [docs/architecture.md](docs/architecture.md)).

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
'platform=iOS Simulator,name=iPhone 17 Pro'`).

The canonical Apple release workflow — live preflight against App Store
Connect (build numbers must be checked there, including expired builds),
signed IPA export, validation, upload, and distribution to all live
TestFlight groups — lives in
[`.agents/skills/margins-release/SKILL.md`](.agents/skills/margins-release/SKILL.md).
Agents with skill support can invoke `margins-release`; any agent can
read the file directly. Private configuration and release evidence stay outside Git.
TestFlight distribution is not a public App Store release.

**iOS TestFlight/App Store release**: the app record must exist in App Store
Connect first (bundle ID `io.github.nathanstefanik.margins`, registered with
the iCloud container on developer.apple.com — automatic signing creates the
App ID during the archive if it is missing). `make ios-archive` writes
`build/Margins.xcarchive`; export, validation, and upload follow the release
skill. `ITSAppUsesNonExemptEncryption` is already `false` in `Info.plist`, so
no encryption-compliance answer is needed per build.

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
MARGINS_BUILD_NUMBER="$BUILD_NUMBER" \
make mas-pkg   # build/Margins-vX.Y.Z-mas.pkg
```

`BUILD_NUMBER` is the next build number chosen from a live App Store
Connect preflight — see
[the release skill](.agents/skills/margins-release/SKILL.md); without it
the package defaults to build 1. Then validate and upload with
`sh scripts/apple-upload.sh upload --confirm build build/Margins-vX.Y.Z-mas.pkg`
— the script runs `altool --validate-app` on every artifact before any
upload and keeps numbered logs in the output directory.
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
`NSFileVersion` conflicts rather than discarding them. Books you have
opened or imported on this iPhone stay readable offline even if iCloud
later evicts the library copy.

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
| `f` | Focus mode — sidebar and toolbar hide, footer fades when idle (reader) |
| `b` | Toggle bookmark (reader) |
| `B` | Bookmarks list (reader) |
| `Esc` | Notes editor → reader; reader → close notes pane; focus mode → reader; notes page → book detail; pane closed → library |
| `l` | Library (from the reader); back to book detail (notes page) |
| `o` | Import EPUB (also ⌘O) |
| `Enter` | Open selected book (library) |
| `/` | Search notes (also ⌘F) |
| `?` | Keyboard shortcuts cheat sheet (also ⌘/) |
| ⌘S | Save note |
| ⌘+ (or ⌘=) / ⌘− / ⌘0 | Bigger / smaller / reset text size |
| ⌘K | Go To… command palette (books, chapters, commands) |
| ⌘B | Toggle the library sidebar |
| ⌘, | Settings (typography, library directory) |
| Trackpad | Two-finger scroll turns pages |

macOS reader layout: the typography popover (textformat button) offers
text size, the reader face, **Automatic** / **One Page** / **Two Pages**
page layout, line width and height, justified text, chapter ornaments,
and the page indicator. Automatic uses a single centered column or a
two-page spread based on the actual window width and text size; One Page
always keeps one column; Two Pages falls back to one when the minimum
readable measure cannot fit (the popover says so). The layout choice
persists locally under `reader.pageLayout.macos` and is separate from
Reset Typography. Footer page numbers are chapter-local and describe
what is visible — "Pages 4–5 of 20" for a spread, "Page 20 of 20" for a
single page. The iOS reader keeps its full-width single column.

## Configuration

| Variable | Purpose |
|----------|---------|
| `MARGINS_DATA_DIR` | App data directory (config + default library) |
| `MARGINS_LIBRARY_ROOT` | Use a specific library directory (e.g. synced folder) |

See [docs/storage.md](docs/storage.md) for the on-disk layout.

## Status

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
- Commonplace **notebooks** and full-text **library search** (iOS), with
  mark quotes and thoughts searchable on both platforms
- **Reader calm pass** on both apps: continue-reading cards, library
  shelves (Reading / Up next / Finished), reading papers with
  follow-system, justify + chapter ornaments, page scrubber and
  page-indicator modes, the chapter-end page, a ⌘K command palette and
  `f` focus mode (macOS), and typeset paper covers for books without one

**In progress**

- Definition-of-done pass on real hardware: walk import → read → five
  marks + one chapter note → compiled notes → export by hand, including
  the gesture-only paths (native edit menu, tap zones, swipes) and the
  highlight overlay's visual paint — the data paths are verified
  end-to-end on the simulator via DEBUG launch seams

## License

GPL-3.0-or-later — fork freely; derivatives must remain open source under the same license.

The bundled reader font Atkinson Hyperlegible Next is licensed under the
SIL Open Font License 1.1 (`apple/Sources/MarginsModel/Resources/reader/AtkinsonHyperlegibleNext-OFL.txt`).
