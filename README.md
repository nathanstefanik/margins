# Margins

Minimal cross-platform EPUB reader (Linux, macOS, iOS) with file-based, AI-friendly annotations.

Inspired by zathura's restraint: keyboard-first navigation, no clutter, your library stays on disk in plain formats you can sync, grep, and hand to an agent.

## Features (MVP)

- Import and browse EPUBs from a local library
- Progress feedback while importing EPUBs
- Paginated reader with vim-style keybindings
- Per-chapter markdown notes with YAML frontmatter
- Compiled per-book **notes page** (`N`) with one-click markdown export,
  copy-all, and clear-all (with a confirmation prompt)
- Full-text search across notes (`/` or `:search`)
- Export/import entire library trees (external drives, cloud sync folders)
- Choose the library directory with the in-app folder picker or **root** command

## Quick start

```bash
cp .env.example .env   # optional overrides
npm install
npm run tauri dev
```

Build a release binary:

```bash
npm run tauri build
```

## Apple apps (macOS + iOS)

Native SwiftUI frontends sharing the same Rust core through one SwiftPM
package (`apple/`) and a per-platform static-library XCFramework (see
[docs/architecture.md](docs/architecture.md) and
[docs/ios-plan.md](docs/ios-plan.md)).

Requirements:

- macOS app: Rust (stable) and Apple Command Line Tools (`xcode-select
  --install`). Full Xcode is not required.
- iOS app: **full Xcode** (the iOS SDK, `xcodebuild`, simulators — the zip
  stack's C dependencies compile against the iOS SDK, so Command Line Tools
  are not enough even for `make ios-core`) plus the Rust iOS targets
  (`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`).

```bash
make core        # build margins-ffi, generate Swift bindings, refresh the
                 # macOS slice of build/MarginsFFI.xcframework
make ios-core    # additionally build the iOS device/simulator xcframework slices
make mac-build   # build the Swift package (macOS)
make mac-test    # run the Swift Testing suite
make mac-app     # assemble build/Margins.app (ad-hoc signed)
make mac-run     # mac-app + open it
```

The iOS app itself builds from `apple/ios/Margins.xcodeproj` (open in Xcode,
or `xcodebuild -project apple/ios/Margins.xcodeproj -scheme Margins -destination
'platform=iOS Simulator,name=iPhone 17 Pro'`). See
[docs/ios-plan.md](docs/ios-plan.md) for the phased status.

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
| `Esc` | Notes editor → reader; reader → close notes pane; notes page → book detail; pane closed → library |
| `l` | Library (from the reader); back to book detail (notes page) |
| `o` | Import EPUB (also ⌘O) |
| `Enter` | Open selected book (library) |
| `/` | Search notes (also ⌘F) |
| `?` | Keyboard shortcuts cheat sheet (also ⌘/) |
| ⌘S | Save note |
| ⌘+ / ⌘− / ⌘0 | Bigger / smaller / reset text size |
| ⌘, | Settings (typography, library directory) |
| Trackpad | Two-finger scroll turns pages |

## Configuration

| Variable | Purpose |
|----------|---------|
| `MARGINS_DATA_DIR` | App data directory (config + default library) |
| `MARGINS_LIBRARY_ROOT` | Use a specific library directory (e.g. synced folder) |

See [docs/storage.md](docs/storage.md) for the on-disk layout.

## Keybindings

| Key | Action |
|-----|--------|
| `j` / `k` | Scroll (reader) or move selection (library) |
| `n` / `p` | Next / previous chapter |
| `N` | Compiled notes page for the current book (reader) |
| `t` | Toggle outline / contents views on the notes page |
| `gg` / `G` | Top / bottom of chapter |
| `i` | Focus notes editor |
| `/` | Search notes (library-wide) |
| `Esc` | Return to reader |
| `l` | Library |
| `o` | Import EPUB |
| `E` | Export library |
| `R` | Choose the library directory |
| `Enter` | Open selected book (library) or search hit |
| `:` | Command mode (`:w` save, `:q` library, `:notes` compiled page, `:search`, `:import`, `:export`, `:root`, `:open 3`) |

## Status

Roadmap detail: [docs/ios-plan.md](docs/ios-plan.md) (phased), [docs/architecture.md](docs/architecture.md) (shape).

**Done**

- Rust core + Tauri 2 frontend (Linux/desktop): library, reader, notes,
  search, markdown export, library sync
- macOS SwiftUI app: library, paginated reader, notes pane, compiled notes
  page, search overlay, keyboard-first control
- Anchored **marks** in chapter notes (parse/serialize/CRUD in the core,
  rendered in both desktop frontends, lossless round-trip)
- Shared Apple SwiftPM package over a per-platform `MarginsFFI.xcframework`
  (macOS + iOS slices, `make core` / `make ios-core`)
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
