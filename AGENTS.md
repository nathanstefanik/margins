# Marginalia — agent guide

EPUB reader (Tauri 2 + Rust + TypeScript). Annotations live on disk as markdown + JSON — see `docs/storage.md`.

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
src-tauri/src/
  config.rs      # data dir / library root from env
  library.rs     # import EPUB, book catalog
  notes.rs       # markdown + YAML frontmatter CRUD
  sync.rs        # export/import library trees
  epub_meta.rs   # EPUB spine/metadata parsing
src/
  app.ts         # UI orchestration
  reader.ts      # epub.js wrapper
  keymaps.ts     # vim-style bindings
  api.ts         # Tauri invoke wrappers
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
cd src-tauri && cargo test
```

## Agent tasks

When modifying notes storage, update `docs/storage.md` and ensure `_index.json` stays consistent. When adding keybindings, update README and the footer keybar in `index.html`.
