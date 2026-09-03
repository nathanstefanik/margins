# Development plan: compiled Notes page + markdown export

Status: implemented · Owner: TBD · Last updated: 2026-09-02

## Goal

A per-book **Notes page** that compiles every chapter note the user has
written into one organized, readable document, ordered by the book's spine
(chapter 1 → last chapter), plus one-click **export as a `.md` file**.

Today notes are only visible one chapter at a time in the reader's notes
pane. All the data already exists on disk (`notes/chapters/*.md` +
`notes/_index.json`), and `_index.json` is already sorted by
`chapter_index` — this feature is a read/compose layer, no storage change.

## Non-goals (this iteration)

- No new storage format, no database (per `AGENTS.md` conventions)
- No PDF/HTML export (markdown only; PDF can come later via print)
- No editing from the compiled page (jump-to-chapter covers that)

---

## Architecture

Follows the existing pattern: all logic in `margins-core`, thin exposure
through both the Tauri command layer and the UniFFI bridge, two thin UIs.

```
crates/margins-core/src/compile.rs      # NEW: compile + render
        │                    │
src-tauri (2 new commands)   crates/margins-ffi (2 new methods)
        │                    │
src/app.ts notes view        macos/ NotesPageView + export panel
```

### 1. Core: `crates/margins-core/src/compile.rs`

New module (registered in `lib.rs`), with models in `models.rs`:

```rust
pub struct CompiledChapter {
    pub chapter_key: String,
    pub chapter_index: usize,
    pub chapter_title: String,
    pub body: String,            // markdown, no frontmatter
    pub word_count: usize,
    pub updated_at: Option<DateTime<Utc>>,
}

pub struct CompiledNotes {
    pub book_id: String,
    pub book_title: String,
    pub book_author: String,
    pub chapters: Vec<CompiledChapter>,  // sorted by chapter_index
    pub chapters_with_notes: usize,
    pub chapter_count: usize,            // total chapters in the spine
    pub total_words: usize,
    pub first_created_at: Option<DateTime<Utc>>,
    pub last_updated_at: Option<DateTime<Utc>>,
}
```

Functions:

- `compile_book_notes(book_dir: &Path) -> Result<CompiledNotes, NotesError>`
  — reads `meta.json` + `notes/_index.json`, loads each listed note via the
  existing `parse_note_file`, sorts by `chapter_index` (defensive re-sort;
  the index is already sorted on save). Chapters with no note file are
  omitted from `chapters` but counted in `chapter_count`. A missing or
  unparsable individual note must not sink the whole compilation — skip it
  and continue (same forgiving posture as `read_notes_index`).
- `render_markdown(notes: &CompiledNotes, opts: &ExportOptions) -> String`
  — deterministic, snapshot-testable markdown (format below).

`ExportOptions` (all default `true` unless noted):

| Option | Effect |
|--------|--------|
| `include_toc` | Linked table of contents after the header |
| `include_stats` | Coverage/word-count summary line |
| `include_empty_chapters` | default `false`; list note-less chapters as `_No note._` stubs so gaps are visible |
| `demote_headings` | default `true`; shift `#`/`##` inside note bodies down two levels so user headings never collide with the document's `#`/`##` structure |

Export document shape:

```markdown
# Notes — {Book Title}

*{Author}* · {n}/{total} chapters annotated · {total} words · last updated {date}

## Contents
- [1. Introduction](#1-introduction)
- [3. The Market](#3-the-market)

---

## 1. Introduction
*{word_count} words · updated {date}*

{note body}

---

## 3. The Market
...
```

Anchor slugs reuse the existing `slugify` from `notes.rs` (make it
`pub(crate)` or move it to a shared helper).

Also expose `suggested_export_filename(&CompiledNotes) -> String` →
`"{author} — {title} — notes.md"` (slug-sanitized) so both frontends
propose the same default name.

### 2. Tauri commands (`src-tauri/src/lib.rs`)

- `get_compiled_notes(book_id) -> CompiledNotes` — feeds the in-app page.
- `export_notes_markdown(book_id, destination, options) -> String` —
  compiles, renders, writes the file, returns the written path. Writing in
  Rust keeps the frontend free of fs permissions; the save dialog comes
  from the already-present `tauri_plugin_dialog`.

Register both in `generate_handler!` and add typed wrappers in `src/api.ts`.

### 3. FFI (`crates/margins-ffi`)

- `get_compiled_notes(book_id) -> CompiledNotes` (mirror record in
  `types.rs`: RFC3339 date strings, `u32` counts, per existing convention)
- `render_notes_markdown(book_id, options) -> String` — macOS writes the
  file itself after `NSSavePanel`, so the bridge only needs the string.

Run `make core` after — the Swift bindings are generated, not committed.

### 4. Tauri frontend (`src/`)

- New `notes-view` section in `index.html` alongside `library-view` /
  `reader-view`; rendering + navigation in `app.ts`.
- Entry points: an "All notes" button on the book (chapter list) screen,
  and keybinding `N` from book view / `:notes` command (add to
  `keymaps.ts`, the footer keybar in `index.html`, and the README — the
  AGENTS.md keybinding checklist).
- Render: stats header, then one section per chapter. Note bodies are
  user markdown — render as plain text (or run through the same
  escape-then-format path used for search snippets); **never** inject raw
  note HTML (`escapeHtml` exists in `app.ts` for this).
- Clicking a chapter section header opens the reader at that chapter
  (reuses the existing open-chapter path).
- "Export .md" button → save dialog (`@tauri-apps/plugin-dialog` `save()`
  with the suggested filename) → `export_notes_markdown` → toast/status
  line with the written path.
- Empty state: "No notes yet — press `i` in the reader to write one."

### 5. macOS app (`macos/`)

- **Model** (`MarginsModel`): extend `LibraryModel` (or a small
  `NotesPageModel`) with `loadCompiledNotes(bookId:)` via `CoreStore`,
  plus a `detailMode: .book | .notes` (or a pushed value) that `DetailArea`
  switches on. Pure presentation helpers (stats line, section ordering)
  live in `MarginsModel` so `MarginsTests` can cover them without UI.
- **View** (`Margins/NotesPageView.swift`): scrollable compiled page
  matching `BookDetailView`'s visual language (serif title, 720pt max
  width). Sections list chapter number + title, word count, updated date,
  and the note body as `Text` (monospaced-adjacent body text is fine; real
  markdown rendering is a stretch goal via `AttributedString(markdown:)`).
  Section header click → `reader.open(book:chapter:)`.
- **Entry points**: "All Notes" button in `BookDetailView`'s header, a
  `View → Book Notes` menu item in `MarginsCommands` (suggest ⇧⌘N), and a
  `ReaderKeymap`/shell-keymap binding consistent with the Tauri `N`.
  Update `KeyHelp` and the help overlay.
- **Export**: "Export Notes…" button on the page + `File → Export Notes…`
  menu command → `NSSavePanel` (default name from
  `suggested_export_filename`) → `render_notes_markdown` → write with
  `String.write(to:)` off the main actor; errors surface in the existing
  error-banner style.

---

## Brainstormed features (add to implementation list)

Included in v1 (cheap, high value):

1. **Stats header** — "12/34 chapters annotated · 1,240 words · last
   updated Sep 1" on both the page and the export.
2. **Linked table of contents** in the export (and in-page jump list).
3. **Jump to chapter** — click any section to open the reader there.
4. **Gap visibility** — optional stubs for chapters without notes, so the
   compiled page doubles as a "what's left to annotate" checklist.
5. **Copy all** — copy the rendered markdown to the clipboard without
   saving a file (clipboard API on both platforms; trivial once
   `render_markdown` exists).
6. **Smart export filename** — `Author — Title — notes.md`, shared by both
   frontends.
7. **Heading demotion** — user `#` headings inside notes are demoted in
   the export so the document outline stays coherent.

Later / stretch (tracked, not in v1):

8. **Library-wide export** — one markdown per book into a chosen folder,
   or a single combined "all my reading notes" file (core loop over
   `list_books` + `compile_book_notes`; natural follow-up since `sync.rs`
   already exports trees).
9. **Export options UI** — checkboxes for TOC/stats/empty-chapter stubs
   (core supports `ExportOptions` from day one; UI can start with
   defaults only).
10. **Obsidian-friendly mode** — YAML frontmatter on the export
    (`title`, `author`, `book_id`, `tags: [reading-notes]`) for vault
    users.
11. **In-page filter** — reuse the note search matcher to filter sections
    on the compiled page.
12. **Rendered markdown bodies** on macOS via
    `AttributedString(markdown:)`; Tauri could add a vetted renderer later
    (escape-first constraint stands).
13. **Print / PDF** — the compiled page is the natural print target
    (`window.print()` / `NSPrintOperation`).
14. **Auto-refresh** — recompile when a note is saved while the page is
    open (both models already know when saves happen).

---

## Milestones

**M1 — Core** (`compile.rs`, models, tests): compile + render + filename
helper. Exit: `cargo test --workspace` green with new unit tests.

**M2 — Tauri**: commands, api.ts, notes view, keybindings, export dialog.
Exit: manual run via `npm run tauri dev` with the Karamazov fixture;
keymap script (`scripts/test-keymap.mjs`) updated if bindings change.

**M3 — macOS**: FFI methods + `make core`, model changes, NotesPageView,
menu commands, NSSavePanel export. Exit: `make mac-test` + `make mac-build`
green; manual check via `make mac-run`.

**M4 — Polish + docs**: copy-all, empty-chapter stubs toggle default,
README keybinding tables (both frontends), `docs/storage.md` note that
exports are derived artifacts (nothing new is stored in the library tree),
`docs/architecture.md` module list update.

Suggested commit slicing: `FEAT Compile book notes in core`,
`FEAT Add notes page and md export (Tauri)`, `FEAT Add notes page and md
export (macOS)`, `DOCS Update keybindings and architecture docs`.

## Testing

- **Core** (`compile.rs` tests, mirroring `notes.rs` fixtures):
  - ordering follows `chapter_index` even if `_index.json` order is shuffled
  - chapters without notes omitted from sections, counted in stats
  - a corrupt single note file is skipped, compilation still succeeds
  - `render_markdown` snapshot: header, TOC anchors, separators, demoted
    headings, empty-book output ("no notes" document, not an error)
  - filename helper strips path-hostile characters (`/`, `:`)
- **macOS** (`MarginsTests`): stats-line formatting, detail-mode
  switching, keymap addition (`ReaderKeymapTests` pattern).
- **Tauri**: keymap regression via `scripts/test-keymap.mjs`; command
  round-trip covered by core tests (the command layer is a thin wrapper).

## Risks / open questions

- **Note bodies are user markdown** — in-page rendering must escape first
  (XSS in the webview otherwise); the exported file is raw text, so no
  risk there.
- **Anchor collisions** in the TOC when two chapters slugify identically —
  suffix `-2`, `-3` like common markdown renderers.
- **Very long books** — hundreds of file reads per compile; fine for a
  local SSD, but compile off the main thread on macOS (`CoreStore` actor
  already guarantees this) and show the page skeleton while loading.
- **Chapter titles that are markdown/`#`-prefixed** — escape titles when
  interpolating into headings.
