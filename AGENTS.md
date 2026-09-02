# Margins — agent guide

EPUB reader with two frontends over one Rust core: Tauri 2 + TypeScript (Linux/desktop) and a native SwiftUI app (macOS, `macos/`). Annotations live on disk as markdown + JSON — see `docs/storage.md`. Frontend architecture: `docs/architecture.md`; macOS implementation plan: `docs/macos-plan.md`.

## Commit messages

Prefix every commit with a type tag and a short imperative summary:

| Prefix | Use for |
|--------|---------|
| `FEAT` | New user-facing capability |
| `BUG` | Bug fix |
| `CHORE` | Tooling, deps, formatting, config |
| `DOCS` | Documentation only |
| `REFACTOR` | Behavior-preserving code change |

Examples:

```
FEAT Add chapter note autosave on :w
BUG Fix OPF spine parsing for nested paths
CHORE Reformatted Rust with rustfmt
DOCS Document library sync workflow
```

## Project map

```
crates/margins-core/   # the domain core (no Tauri, no UI)
  config.rs            # data dir / library root from env
  library.rs           # import EPUB, book catalog
  notes.rs             # markdown + YAML frontmatter CRUD
  sync.rs              # export/import library trees
  epub_meta.rs         # EPUB spine/metadata parsing
crates/margins-ffi/    # UniFFI bridge for Swift (thin)
src-tauri/src/         # Tauri command layer over the core
src/                   # Tauri frontend
  app.ts               # UI orchestration
  reader.ts            # epub.js wrapper
  keymaps.ts           # vim-style bindings
  api.ts               # Tauri invoke wrappers
macos/                 # macOS SwiftUI app (SwiftPM package)
  Package.swift        # targets: margins_ffiFFI, MarginsCore, MarginsModel, Margins, MarginsTests
  Sources/MarginsCore/ # generated bindings + CoreStore actor
  Sources/MarginsModel/# LibraryModel, ReaderModel, ReaderResource, ReaderKeymap
  Sources/Margins/     # SwiftUI views, reader webview glue, key routing
  Sources/MarginsTests/# Swift Testing suite (runner executable)
scripts/               # build-core.sh, make-app.sh
```

## Conventions

- Keep annotation storage plain-text; do not introduce a database without strong reason
- Sensitive paths belong in `.env`, never committed
- Match existing minimal/zathura-like UI patterns (dark, keyboard-first)
- GPL-3.0-or-later — preserve license on distribution

## Useful commands

```bash
npm install
npm run tauri dev
npm run tauri build
cargo test --workspace        # from the repo root (covers core + tauri)

make core        # rebuild margins-ffi + regenerate Swift bindings
make mac-build   # build the macOS Swift package
make mac-test    # run the macOS Swift Testing suite
make mac-run     # assemble + open build/Margins.app
```

macOS tests use Swift Testing (`import Testing`) via the `MarginsTests`
runner executable — `swift test` silently runs nothing on a CLT-only
toolchain, so always verify with `make mac-test`.

## Agent tasks

When modifying notes storage, update `docs/storage.md` and ensure `_index.json` stays consistent. When adding keybindings, update the README (both frontends) and the footer keybar in `index.html` for the Tauri app. When changing the FFI surface, run `make core` so the Swift bindings regenerate.
