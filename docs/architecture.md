# Margins architecture

Margins is one Rust core with two thin frontends: the original Tauri
(Linux/desktop) app and a native macOS SwiftUI app. Both render EPUBs with
epub.js and write annotations as plain files — no database anywhere.

```
Linux/Tauri app ── src-tauri (thin #[tauri::command] layer)
                          │
macOS SwiftUI app ── crates/margins-ffi (UniFFI, thin)
   macos/                 │
                  crates/margins-core
        EPUB parsing · library · notes · search · sync
             (plain-text storage, no Tauri, no UI)
```

## The core (`crates/margins-core`)

All domain logic lives here and has **no Tauri dependency**:

- `config.rs` — data dir / library root, from `MARGINS_DATA_DIR` /
  `MARGINS_LIBRARY_ROOT` or platform defaults.
- `library.rs` — importing EPUBs into the library tree, the book catalog
  (`_index.json`), reading book bytes, removing books.
- `epub_meta.rs` — OPF/spine/metadata parsing.
- `notes.rs` — per-chapter markdown notes with YAML frontmatter and a
  `_index.json` per book.
- `compile.rs` — compiles a book's notes into one spine-ordered document
  (the per-book notes page) and renders it as markdown for the `.md`
  export / copy-all; exports are derived artifacts (see `docs/storage.md`).
- `sync.rs` — export/import of whole library trees.
- `models.rs` — shared record types.

Storage stays human-readable on disk; see `docs/storage.md` for the layout.
Both frontends write notes through the same `notes.rs` code path, so the
files are byte-identical regardless of which app wrote them.

## The bridge (`crates/margins-ffi`)

A thin UniFFI 0.29 (proc-macro mode) wrapper over the core. One exported
object, `MarginsCore`, with `list_books`, `import_epub`, `get_book`,
`remove_book`, `read_epub_bytes`, `get_chapter_note`, `save_chapter_note`,
`get_compiled_notes`, `render_notes_markdown`, `search_notes` — records
mirror `models.rs` with RFC3339 date strings and `u32` counts (UniFFI has
no `chrono`/`usize`); errors are a flat `CoreError`. Sync export/import is
not exposed (no UI for it yet on either platform).

`scripts/build-core.sh` release-builds the staticlib and generates the Swift
bindings into the SwiftPM layout (`macos/Sources/margins_ffiFFI/include/`
for the C header + module map, `macos/Sources/MarginsCore/Generated/` for
the Swift). Those paths are gitignored; run the script after changing the
FFI surface.

## The macOS app (`macos/`)

A SwiftPM package (no `.xcodeproj`; builds with Command Line Tools alone —
note that `swift test` never invokes test bundles on a CLT-only toolchain,
so tests run through the `MarginsTests` runner executable). Targets:

- `margins_ffiFFI` — C target carrying the generated FFI header/module map.
- `MarginsCore` — generated bindings plus `CoreStore`, an actor wrapper that
  keeps synchronous Rust calls off the main actor.
- `MarginsModel` — UI-agnostic model layer: `LibraryModel` (catalog,
  selection, import/remove), `ReaderModel` (open book/chapter, notes pane
  state), `ReaderResource` (scheme-handler routing), `ReaderKeymap`
  (vim-style key state machine). Unit-tested via `MarginsTests`.
- `Margins` — SwiftUI app: library browser, reader (WKWebView + epub.js),
  notes pane, search overlay, keyboard/trackpad routing.
- `MarginsTests` — a Swift Testing **runner executable** (SwiftPM's test
  runner never invokes test bundles on the CLT toolchain; see the plan doc).

### Reader rendering

The reader vendors `epub.min.js` + `jszip.min.js` (versions pinned in the
root `package.json`) plus a hand-written `reader.html`/`reader.js` that
mirrors the Tauri frontend's `src/reader.ts`: whole-book bytes in, paginated
flow, `spread: "none"`. Swift drives the page through the `window.reader*`
functions via `evaluateJavaScript`.

### `margins-reader://` scheme — security model

The reader webview loads `margins-reader://app/reader.html?book=<id>`; a
`WKURLSchemeHandler` serves **exactly five** resources: `reader.html`,
`reader.js`, `epub.min.js`, `jszip.min.js`, and `book.epub` (bytes from
`read_epub_bytes`). Anything else — traversal, nested paths, unknown names —
is rejected by the pure `ReaderResource` resolution before any I/O, so there
is no arbitrary-path or filesystem exposure. EPUB content itself is unzipped
in JS from the whole-book bytes (same as Tauri), never from disk paths.

Two response-type rules are load-bearing (both bit us once): `fetch()` needs
HTTP semantics, so `book.epub` is served as an `HTTPURLResponse` — a plain
`URLResponse` makes WebKit reject the fetch with status 0. Frame/subresource
loads need the plain `URLResponse` — serving HTTP for the main document
breaks the load.

Navigation policy sends any `http(s)` navigation (and `target=_blank`) to
the system browser; only `margins-reader://` loads in the webview.

### Keyboard routing

One local `NSEvent` monitor (`ShellKeyboardController`) sees every keyDown
before dispatch — including keys headed into the webview — and feeds them
through `ReaderKeymap`. Reader actions execute via `evaluateJavaScript`
(page turns are `rendition.next()/prev()`; paginated content has no vertical
overflow). A scroll-wheel monitor turns pages from trackpad input while
reading. ⌘-combos and text-field typing pass through to menus and inputs.

### Notes and search

The notes pane edits the chapter note from `get_chapter_note`; ⌘S / `i`-pane
Save go through `save_chapter_note`, writing the same markdown+frontmatter
files as the Tauri app. `/` (or ⌘F) opens the search overlay over
`search_notes`; opening a hit jumps straight to that book/chapter. The
overlay is non-modal (no sheet window) and `LibraryModel.searchOpen` is the
single source of truth: the shell key monitor closes it on Esc and clicks
outside the panel dismiss it.

The **compiled notes page** (`NotesPageView`, reached via the book detail's
"All Notes" button, `N`, or ⇧⌘N / View → Book Notes) shows every chapter
note in spine order through `get_compiled_notes`; `LibraryModel.detailMode`
switches the detail area between the book card and the page. "Export
Notes…" (button or File menu) renders with `render_notes_markdown` and
writes the file after an `NSSavePanel`; note bodies render as plain `Text`
(never as markdown/HTML).

## Building and running (macOS)

```bash
make core        # build margins-ffi + generate Swift bindings
make mac-build   # build the Swift package
make mac-test    # run the Swift Testing suite
make mac-app     # assemble build/Margins.app (ad-hoc signed)
make mac-run     # mac-app + open it
```

Requirements: Rust (stable) and Apple Command Line Tools. `cargo test
--workspace` must keep passing at all times — the Tauri app is never broken
by macOS work.
