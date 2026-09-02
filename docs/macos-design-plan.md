# macOS UI/UX Design Plan

Goal: make Margins the EPUB reader people *prefer* over Apple Books — simple and
minimal, but visually pleasing and satisfying. The per-chapter notes feature is
the functional hook; this plan closes the design gap so first impressions don't
lose people before they reach it.

This is a work plan for AI agents. Work through the phases in order; each phase
is independently shippable and ends with a verification checklist. Automated
checks are things an agent can run; **"Nathan verifies"** items are visual/feel
judgments — build the app (`make mac-run`), describe what to look at, and stop
for his sign-off before marking the phase done.

## Ground rules for every phase

1. **Load the HIG skills first.** The `apple-hig-skills` plugin is installed
   (source: raintree-technology/hig-doctor). Before designing or reviewing UI,
   invoke the relevant skills via the Skill tool — at minimum `hig-foundations`
   and `hig-platforms` (macOS section), plus the component skill matching the
   work (`hig-components-layout`, `hig-components-content`,
   `hig-components-search`, `hig-components-menus`, `hig-components-status`,
   `hig-inputs`, `hig-patterns`).
2. **Design language.** Native macOS materials and system colors everywhere in
   the chrome (sidebar, toolbars, panes) — never hardcoded hex in SwiftUI.
   The reading surface is the one place with its own palette: a single,
   fixed paper theme (the current cream) — no theme picker for now (see
   Future work). Prefer system typography (`.body`, `.headline`); serif is
   reserved for book content. Restraint is the brand: when in doubt, remove.
3. **Keyboard-first stays sacred.** Every new UI affordance must not steal the
   vim-style keys (see `macos/Sources/Margins/ShellKeyboardController.swift`
   and `MarginsModel/ReaderKeymap.swift`). Any new clickable action should also
   get a key or menu item.
4. **Build & test gate.** Before claiming a phase done, run:
   ```bash
   make core        # only if Rust code changed
   make mac-build
   make mac-test
   ```
   All must pass. Add Swift Testing tests to `macos/Sources/MarginsTests/` for
   any new model/persistence logic (they run via `make mac-test`; see
   `Runner.swift` for the harness).
5. **Don't regress Linux/Tauri.** Rust core changes (`crates/`) must keep
   `cargo test` green and remain additive to the FFI surface.

## Current-state audit (what's wrong today)

- **No typography controls.** No font size or line-width control; epub.js
  renders publisher defaults edge-to-edge in wide windows.
- **No covers anywhere.** The Rust core never extracts cover images; the
  sidebar is bare text rows and the book detail page is a settings-style list.
  Books' bookshelf look is its main emotional draw — we have none of it.
- **No reading continuity.** Position isn't persisted; there's no progress
  indication in the reader or the library. Reopening a book restarts the
  chapter.
- **Notes pane is utilitarian.** Monospaced text in a gray box, a Save button
  that pops in and out (layout shift), no autosave.
- **Rough edges:** the library-root path is overlaid on top of sidebar rows
  (`SidebarView.swift`); errors surface as a generic "Something went wrong"
  alert; the Settings window says "Nothing to configure yet."; the app bundle
  has no icon (`scripts/make-app.sh` writes a bare Info.plist); vim keys are
  invisible to new users (no cheat sheet, sparse menu bar).

---

## Phase 1 — The reading surface (hero feature)

The page people stare at for hours. Highest impact; do this first. The single
paper theme (the current cream) stays as-is and is not user-selectable —
refine within it; theming is future work.

**Tasks**

1. **Typography controls.** Font size (step ⌘+/⌘−/⌘0), a comfortable
   max line length (~65–75ch column centered with generous margins instead of
   edge-to-edge text), and line-height, applied via epub.js
   `rendition.themes` overrides on the one default theme. Expose via a small
   toolbar popover (`textformat` SF Symbol) in `ReaderView.swift` — one
   popover, few controls, Books-style.
2. **Persist reader preferences** (font size) in a new `ReaderPreferences`
   type stored via `UserDefaults` (chrome preference, not library data —
   doesn't belong in the synced library tree).
3. **Progress footer.** A thin, unobtrusive footer under the page: chapter
   title (secondary style) and "page n of m" within the chapter, fed from
   epub.js `relocated` events through the existing script message bridge.
   Style it to sit on the paper background so page and footer read as one
   surface.
4. Keep all existing keybindings working (⌘+/⌘−/⌘0 must not collide with
   the shell keymap); update the README key table.

**Automated verification**

- `make mac-build && make mac-test` pass.
- New tests: `ReaderPreferences` round-trips through its store (inject a
  `UserDefaults(suiteName:)`); font-size stepping clamps at its min/max;
  existing `ReaderKeymapTests.swift` still passes unchanged.

**Nathan verifies**

- [x] Text column is comfortable at full-screen width (no 40cm-long lines).
- [x] Typography popover feels native and minimal.
- [x] Font size survives quit/relaunch.
- [x] Progress footer is legible but ignorable.

---

## Phase 2 — Cover extraction (core plumbing)

Backend-only phase enabling the library redesign.

**Tasks**

1. In the Rust core (`crates/`), extract the EPUB cover image at import time
   (EPUB2 `<meta name="cover">` and EPUB3 `properties="cover-image"`; fall
   back to the first spine image; tolerate absence). Write it as
   `books/{book_id}/cover.{ext}` and record the filename in `meta.json` and
   the catalog `index.json`. Document in `docs/storage.md`.
2. Add a one-shot migration/backfill: on library scan, extract covers for
   already-imported books that lack one (source.epub is retained, so this is
   cheap).
3. Expose `cover_path` through the FFI into `BookSummary`/`BookMeta`
   (`make core` regenerates bindings; update `MarginsCore`/`Conformances`).

**Automated verification**

- `cargo test` green, including new tests: import a fixture EPUB with a cover
  → file exists and is referenced; fixture without a cover → import still
  succeeds with `cover_path: null`. Use/extend `fixtures/`.
- `make core && make mac-build && make mac-test` pass; `BridgeTests.swift`
  extended to assert the field crosses the FFI.

**Nathan verifies** — nothing visual yet; sign-off is the green test run.

---

## Phase 3 — Library & book detail redesign

Turn the text list into something that feels like a shelf.

**Tasks**

1. **Sidebar rows** (`BookRowView.swift`): small cover thumbnail (fixed ~2:3
   frame, `clipShape` rounded rect, subtle border), title + author, and a thin
   reading-progress bar or percent caption once Phase 4 lands. Graceful
   placeholder (letterpress-style initials on a tinted rect derived from the
   title hash) when no cover exists.
2. **Fix the library-root overlay**: replace the floating text in
   `SidebarView.swift` with a proper pinned bottom bar (divider + secondary
   caption + folder button that opens the root picker), outside the scroll
   content.
3. **Book detail** (`BookDetailView.swift`): hero header — large cover,
   title (`.largeTitle` serif ok here), author, metadata line (language,
   added date, chapter count) — with a prominent **Read** button (continue
   location once Phase 4 lands, else first chapter). Below it the chapter
   list: number, title, and a note indicator (dot or `note.text` symbol +
   word count) for chapters that have notes, sourced from the notes index the
   core already maintains (`notes/_index.json`).
4. **Empty states**: keep `ContentUnavailableView`s but add a direct "Import
   EPUB…" button to the no-books state.

**Automated verification**

- `make mac-build && make mac-test` pass.
- Model tests: placeholder-color/initials function is deterministic; the
  chapter→note-metadata join returns correct word counts for a fixture
  library (extend `LibraryModelTests.swift` / `NotesTests.swift`).

**Nathan verifies**

- [ ] Sidebar reads as a bookshelf at a glance; placeholder covers look
      intentional, not broken.
- [ ] Book detail's Read button is the obvious next action.
- [ ] Note indicators make annotated chapters visible without clutter.
- [ ] Nothing overlaps the last sidebar row anymore.

---

## Phase 4 — Reading continuity

The single biggest "prefer this over Books" retention feature.

**Tasks**

1. Persist last location per book — chapter key + epub.js CFI + computed
   percent — debounced on `relocated` events. Store in the library tree (e.g.
   `books/{book_id}/position.json`, documented in `docs/storage.md`) so it
   syncs with the library like everything else.
2. Opening a book from the sidebar (Enter / double-click / Read button)
   resumes at the saved location; chapter list still allows explicit jumps.
3. Surface percent-complete in sidebar rows and book detail (Phase 3 hooks).

**Automated verification**

- Tests: position round-trip (write → read → equals), corrupt/missing
  position file falls back to chapter 1 cleanly, percent math clamps to
  0–100. `cargo test` if stored via the core; Swift tests for model behavior.
- `make mac-build && make mac-test` pass.

**Nathan verifies**

- [ ] Quit mid-chapter, relaunch, open the book — same page.
- [ ] Sidebar progress matches reality.

---

## Phase 5 — Notes pane polish

The differentiator should feel like the best-crafted part of the app.

**Tasks**

1. **Autosave** with ~1s debounce after typing stops (plus save on pane
   close/chapter change/app quit). Remove the pop-in Save button; replace
   with a fixed-position subtle status ("Edited" → "Saved" fade, or a small
   dot). Keep ⌘S as an explicit save.
2. **Chapter-contextual header**: replace the static "Notes" label in
   `NotesPane.swift` with the current chapter as the headline — e.g.
   "Ch. 3 · The Market" (chapter number + title from `reader.chapter`), with
   "Notes" demoted to a secondary caption or dropped entirely. The header
   must update when `n`/`p` switches chapters. Truncate long chapter titles
   with a tooltip carrying the full title. (The default markdown body from
   the core already includes the chapter — `# {chapter_title} — Summary`,
   `crates/margins-core/src/notes.rs` — leave that as-is.)
3. **Editor comfort**: readable proportional body font by default (the notes
   are prose summaries, not code), comfortable padding, placeholder text for
   empty notes ("Summarize this chapter in ~100 words…"), and a word-count
   display that gently signals the ~100-word target (e.g. secondary → primary
   style as you approach it).
4. **Pane transition**: animate show/hide (`i` / toolbar button) instead of
   the current instant HSplitView pop.
5. Inline, quiet error display stays, but style it as a banner rather than
   bare red caption.

**Automated verification**

- Tests: debounce logic (typing bursts produce one save), save-on-close and
  save-on-chapter-switch paths, dirty-state transitions — extend
  `NotesTests.swift` against `ReaderModel`.
- Header-title formatting is a pure function (chapter index + title →
  "Ch. 3 · The Market") with tests covering missing/long titles.
- `make mac-build && make mac-test` pass.

**Nathan verifies**

- [ ] Notes header always names the chapter you're annotating; press `n` a
      few times and watch it follow.
- [ ] Type, wait, quit without ⌘S — note survived.
- [ ] Pane open/close feels smooth; nothing jumps when the dirty state
      changes.

---

## Phase 6 — Search: real engine + command palette

Search is currently both under-engineered and under-designed, so this phase
rebuilds it in three parts (land them as separate PRs in order):

**Where it stands.** The presentation shell was already rebuilt (PR #11):
`SearchOverlay.swift` is a non-modal Spotlight-style palette inside the main
window — material panel, click-away scrim, animated presentation, Esc
routed through the shell key monitor with `LibraryModel.searchOpen` as the
single source of truth, and a modal keymap mode that blocks reader/library
keys while it's up. **Build on that overlay; do not reintroduce a sheet or
a separate window.** Everything behind and inside it still needs the
rebuild:

- Every query re-reads and re-parses **every note file of every book from
  disk** (`crates/margins-core/src/notes.rs` `search_notes`), and the
  overlay still fires a query on **every keystroke** with no debounce
  (`.task(id: query)`) — O(library) filesystem work per character typed.
- Matching is ASCII-lowercase substring AND: "Café" doesn't match "café",
  and any non-ASCII language is broken.
- "Ranking" is chapter-title-matches-first, then alphabetical by book —
  no relevance at all.
- The core returns a plain snippet string with no match positions, so the
  UI can't highlight matches without re-implementing the matcher.
- In the overlay: Enter can only open the *first* hit, there is no ↑/↓
  virtual selection, no match highlighting, no sections, no recents — the
  empty and no-result states are single hint lines.

The target paradigm is the 2026-standard **⌘K command palette** (Linear,
Raycast, VS Code, Slack): a floating combobox where the text field keeps
focus the entire time while ↑/↓ move a *virtual* selection in the results
list, results appear as-you-type, matches are highlighted, and the empty
state offers recent searches instead of a blank pane. References for the
implementing agent: the [VS Code command palette UX
guidelines](https://github.com/microsoft/vscode-docs/blob/main/api/ux-guidelines/command-palette.md),
[uxpatterns.dev on command
palettes](https://uxpatterns.dev/patterns/advanced/command-palette), and
[SaaS search/palette pattern survey](https://www.saasui.design/blog/saas-search-command-palette-ux-patterns).
Also load `hig-components-search` and `hig-components-dialogs` before UI
work.

### 6a — Search engine (Rust core)

1. **In-memory index** owned by the store: built lazily on first search from
   the existing per-book `notes/_index.json` + note files, then kept warm.
   Documents: note bodies, chapter titles, book titles, authors — tokenized
   with Unicode case folding (`str::to_lowercase`, not ASCII-only), keeping
   each token's source range for highlighting.
2. **Invalidation**: note saves through the core update the index in place;
   because notes are plain files that agents/external tools also edit,
   re-validate per book via `_index.json`/note-file mtimes on query (cheap
   stat calls, re-parse only what changed).
3. **Matching**: AND across whitespace-separated terms; completed terms match
   token-prefix, and the final term always matches as prefix so results
   appear while a word is being typed.
4. **Ranking**: deterministic score — field weight (chapter title > book
   title/author > body) × term frequency, with a phrase/proximity bonus when
   terms appear adjacent in order; tie-break by book title then chapter
   index so output is stable.
5. **Structured hits**: extend `NoteSearchHit` with a `kind` (note-content
   vs chapter-title vs book target), a score, and **match ranges** — snippet
   text plus the character ranges of matched terms within the snippet and
   within the displayed titles. The UI must never re-run matching.
6. **Scale posture**: this is a hand-rolled index because the corpus is small
   (a personal library; thousands of short notes). Document the assumption
   in code. If it's ever exceeded, swap the internals for
   [tantivy](https://github.com/quickwit-oss/tantivy) behind the same
   `search_notes` API — do **not** adopt it now.

*Verify:* `cargo test` with new cases — Unicode case-insensitivity
("Café"/"café", "STRAßE"/"straße"), prefix matching mid-word ("mark" finds
"market"), ranking fixtures (title hit outranks body hit; two-term proximity
outranks scattered), snippet ranges are valid indices into the snippet,
external file edit is picked up on the next query, empty/whitespace query
returns nothing, index gives identical results to a cold scan.

### 6b — Bridge & query lifecycle (FFI + Swift model)

1. Regenerate bindings for the extended hit type (`make core`); update
   `Conformances.swift` and `BridgeTests.swift` to round-trip ranges/kind.
2. Replace the overlay's `.task(id: query)` re-query with a small
   `SearchController` in `MarginsModel`: **~150ms debounce**, latest-wins
   cancellation, results capped (e.g. 50) with the cap surfaced to the UI.
3. **Recent searches**: persist the last ~5 submitted queries in
   `UserDefaults` (chrome state, not library data).

*Verify:* Swift tests — a burst of keystrokes yields one core query; stale
results never overwrite newer ones; recents dedupe, cap at 5, and
round-trip persistence.

### 6c — Palette UI

Extend the existing `SearchOverlay.swift` — its panel chrome (material,
scrim, Esc/click-away dismissal, `searchOpen` plumbing, modal keymap mode)
is the foundation; don't replace it.

1. **Combobox interaction**: field keeps keyboard focus for the palette's
   whole lifetime; ↑/↓ (plus ⌃N/⌃P for vim hands) move a highlighted
   virtual selection that wraps; Enter opens the selection (today it can
   only open the first hit); Esc keeps its existing dismissal path; hover
   moves the selection too but never steals focus.
2. **Result rows**: `book › chapter` breadcrumb line plus a snippet line
   with matched ranges bolded/tinted via `AttributedString`, built directly
   from the core's match ranges. Sectioned by `kind`: Chapters (navigation
   targets) above Notes (content hits). Show "n more matches" when the cap
   truncates.
3. **Empty & no-result states**: an empty query shows recent searches
   (Enter re-runs one) and a one-line hint of what's searchable; no matches
   shows the query, a plain explanation, and keeps the field active — never
   a dead-end pane.
4. **Accessibility**: the field/list pair exposes combobox semantics
   (`accessibilityRepresentation`/rotor-friendly rows); selection changes
   are announced; all colors from system styles so the palette is correct
   in both appearances.

*Verify:* Swift tests — selection navigation wraps/clamps across sections;
`AttributedString` builder applies exactly the core-provided ranges (incl.
multi-term rows); section partitioning by `kind`. `make mac-build &&
make mac-test` pass.

**Nathan verifies**

- [ ] `/` → type a half-word → results appear while typing, matches bolded.
- [ ] ↑/↓ + Enter lands on the right chapter without touching the mouse;
      typing never loses field focus.
- [ ] Search feels instant on your real library (no per-keystroke disk
      churn).
- [ ] Empty palette shows recent searches; a nonsense query explains itself.
- [ ] The palette looks at home next to Spotlight/Raycast in both light and
      dark appearance.

---

## Phase 7 — Discoverability & finish

The last mile that makes it feel like a real product.

**Tasks**

1. **Shortcut cheat sheet**: `?` (and Help menu item) shows a dismissible
   overlay listing the vim keys, grouped by context — generated from the
   keymap definitions, not hand-duplicated. Reuse the search overlay's
   presentation pattern (in-window overlay + scrim + the modal keymap mode
   from `ShellKeyboardController`/`ReaderKeymap`, PR #11) rather than
   inventing a second dismissal mechanism.
2. **Complete the menu bar** (`MarginsCommands.swift`): Go menu (Next/Previous
   Chapter, Back to Library), View menu (Toggle Notes `i`, text size), so
   every key action is discoverable and shows its shortcut.
3. **Import feedback**: progress indication during import (the Tauri frontend
   has this; the Swift shell doesn't) — indeterminate bar or staged status in
   the sidebar/toolbar area, plus graceful multi-file import
   (`allowsMultipleSelection = true` in `ImportPanel.swift`).
4. **Error presentation**: replace the generic "Something went wrong" alert
   with specific titles and recovery hints; non-fatal errors as a transient
   banner instead of a modal.
5. **Settings window**: real content — reader typography defaults and the
   library-root picker (replaces the placeholder text).
6. **App icon**: design a minimal icon (a book page with a margin note),
   generate the `.icns`, wire it into `scripts/make-app.sh`/Info.plist.
7. Update `README.md` key tables and screenshots.

**Automated verification**

- Cheat-sheet content derives from `ReaderKeymap`/shell keymap (test: every
  bound key appears in the generated sheet model).
- `make mac-build && make mac-test` pass; `scripts/make-app.sh` output bundle
  contains the icon (`test -f build/Margins.app/Contents/Resources/*.icns`).

**Nathan verifies**

- [ ] A newcomer could learn the keys from `?` and the menus alone.
- [ ] Importing 3 EPUBs at once feels safe (feedback, no freeze).
- [ ] Icon looks right in the Dock at small sizes.

---

## Tracking

Mark phases here as they complete (agents: update this table in the same PR
that finishes a phase, after Nathan's sign-off on the visual items).

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | Reader typography + progress footer | Done (3d0fb29) |
| 2 | Cover extraction (Rust core + FFI) | Not started |
| 3 | Library & book detail redesign | Not started |
| 4 | Reading-position persistence | Not started |
| 5 | Notes pane polish | Not started |
| 6 | Search engine rebuild + command palette (6a/6b/6c) | Not started |
| 7 | Discoverability, menus, settings, icon | Not started |

## Future work (explicitly out of scope for now)

Deferred by decision — do not implement these while working the phases above:

- **Reader themes.** Sepia/dark variants, a theme picker, and following the
  system appearance (today `reader.html` hardcodes the cream page, so the
  reader stays light even in dark-mode windows). Deferred to keep the current
  surface simple; revisit after Phases 1–7 land. When picked up: epub.js
  `rendition.themes` + matching body styles, live system-appearance updates
  piped from `ReaderWebView`, and a theme default in Settings.
