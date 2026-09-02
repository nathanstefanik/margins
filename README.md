# Margins

Minimal cross-platform EPUB reader (Linux + macOS) with file-based, AI-friendly annotations.

Inspired by zathura's restraint: keyboard-first navigation, no clutter, your library stays on disk in plain formats you can sync, grep, and hand to an agent.

## Features (MVP)

- Import and browse EPUBs from a local library
- Progress feedback while importing EPUBs
- Paginated reader with vim-style keybindings
- Per-chapter markdown notes with YAML frontmatter (~100-word summaries)
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

## macOS app

A native SwiftUI frontend sharing the same Rust core (see
[docs/architecture.md](docs/architecture.md)).

Requirements: Rust (stable) and Apple Command Line Tools (`xcode-select
--install`). Full Xcode is not required.

```bash
make core        # build margins-ffi + generate Swift bindings
make mac-build   # build the Swift package
make mac-test    # run the Swift Testing suite
make mac-app     # assemble build/Margins.app (ad-hoc signed)
make mac-run     # mac-app + open it
```

macOS keybindings:

| Key | Action |
|-----|--------|
| `j` / `k` | Next / previous page (reader) or move selection (library) |
| Space / arrows / PgDn / PgUp | Turn pages (reader) |
| `gg` / `G` | First / last page of chapter |
| `n` / `p` | Next / previous chapter |
| `i` / `Enter` | Open and focus the notes pane (reader) |
| `Esc` | Notes editor → reader; reader → close notes pane; pane closed → library |
| `l` | Library |
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
| `gg` / `G` | Top / bottom of chapter |
| `i` | Focus notes editor |
| `/` | Search notes (library-wide) |
| `Esc` | Return to reader |
| `l` | Library |
| `o` | Import EPUB |
| `E` | Export library |
| `R` | Choose the library directory |
| `Enter` | Open selected book (library) or search hit |
| `:` | Command mode (`:w` save, `:q` library, `:search`, `:import`, `:export`, `:root`, `:open 3`) |

## License

GPL-3.0-or-later — fork freely; derivatives must remain open source under the same license.
