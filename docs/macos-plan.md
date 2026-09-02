# macOS SwiftUI frontend — implementation plan

Goal: a native macOS SwiftUI app for Margins that imports, inspects, and reads
EPUBs, reusing the existing Rust core. Incremental — the Tauri/Linux app keeps
working at every stop point. No big-bang rewrite.

This plan is written to be executed by an AI agent part by part (each part has
1–2 shippable steps). Read **Ground truth** and **Rules** before starting any
part.

## Status (2026-09-02)

| Part | What | Steps | Status |
|------|------|-------|--------|
| I | Core extraction, bindings, app shell, library UI (was phases 0–4) | 5 | **done** |
| II | WebKit reader (epub.js) + keyboard routing (was phases 5–6) | 2 | **done** |
| III | Notes and search + documentation (was phases 7–8) | 2 | not started |

Next: **Part III, step 1** (notes and search).

---

## Ground truth (re-verified 2026-09-02 after Part I)

- Core lives in `crates/margins-core`. Those modules have **no Tauri
  dependency**. `src-tauri` is a thin `#[tauri::command]` wrapper over
  `margins_core::{...}`.
- Workspace root `Cargo.toml` members: `crates/margins-core`,
  `crates/margins-ffi`, `src-tauri`. `Cargo.lock` is at the repo root;
  `cargo` output is `/target/`. Swift bindings are generated (gitignored)
  by `./scripts/build-core.sh` into the SwiftPM layout:
  `macos/Sources/margins_ffiFFI/include/` (C header + module map) and
  `macos/Sources/MarginsCore/Generated/` (Swift bindings).
- **This machine has Command Line Tools only, no full Xcode.** `xcodebuild`
  does not work. Therefore:
  - The macOS app is a **SwiftPM package** (`macos/Package.swift`), built with
    `swift build`. No `.xcodeproj`, no XcodeGen.
  - Tests use **Swift Testing** (`import Testing`, `@Test`), but as a
    **runnable executable target** (`MarginsTests`), not a `.testTarget`:
    SwiftPM 6.3.2 on this CLT links test bundles but **never invokes the
    runner** — `swift test` silently exits 0 without running anything, and
    `swiftpm-testing-helper` completes without output. The executable calls
    `Testing.__swiftPMEntryPoint()` itself; `make mac-test` runs it with
    `swift run`. Revisit if the toolchain is fixed or full Xcode lands.
    **Do not use XCTest** — it is not present in CLT. No XCUITest UI tests;
    human stop points cover that.
  - The `.app` bundle is assembled by a shell script (Info.plist + binary +
    resources + ad-hoc `codesign -s -`).
- Existing frontend already renders with **epub.js fed whole-book bytes**
  (`src/reader.ts`: `ePub(bytes.buffer)` after `read_epub_bytes`; paginated
  flow, `spread: "none"`; `j`/`k` scroll the iframe by ±80px; chapters are
  shown as `index + 1`). The macOS reader mirrors these semantics exactly.
- `epubjs` `^0.3.93` and its transitive `jszip` (3.10.1) are the renderer
  versions pinned in `package.json`; the reader vendors `epub.min.js` +
  `jszip.min.js` from `node_modules` (`npm install` populates them).
- Real-book checks use whatever `*.epub` files are in `fixtures/` — any one
  book is enough; none of the title, author, or chapter count is hardcoded.
  A Karamazov file may sit there as an example. Do not special-case a book.
- Commit conventions are in `AGENTS.md` (`FEAT`/`BUG`/`CHORE`/`REFACTOR`/`DOCS`
  prefix + imperative summary).

## Deliberate cuts from the original spec (do not re-add)

- **Readium evaluation** — decided: epub.js + WKWebView. It matches the Tauri
  frontend, is known to handle our books, and Readium's macOS support is not
  worth an evaluation detour.
- **Per-resource scheme handler** (`margins-book://<id>/<path>` with path
  validation into the ZIP) — unnecessary. epub.js unzips in JS from whole-book
  bytes, same as the Tauri app. The scheme handler serves only five fixed
  resources (see Part II), so the arbitrary-path attack surface never exists.
- **`extractText` bridge API** — only needed for future in-book full-text
  search. Deferred.
- **SwiftUI `WebView`/`WebPage` (macOS 26 API)** — one code path only:
  `WKWebView` in an `NSViewRepresentable`. Less risk, works everywhere.
- **XCUITest UI tests** — impossible without Xcode. Replaced by pure-logic
  Swift Testing tests + human verification at part boundaries.
- **Export/import/sync UI on macOS** — core keeps the capability; UI deferred
  past this plan.
- **No database** — storage stays plain-text markdown/JSON, unchanged.

## Rules for the executing agent

1. **One step at a time, in order, within a part.** Finish a step's
   verification before touching the next step. An agent run may complete a
   whole part, but never leave a step half-done.
2. **Verify, then commit.** Every step ends with verification commands. All
   must pass before the step's commit. If verification fails, fix it — never
   commit a red step, never skip ahead.
3. **Commit granularity:** at minimum one commit per shipped step (messages
   given below). Additional intermediate commits are fine if a sub-step is
   green.
4. **Never break Tauri.** `cargo test --workspace` and
   `cargo check -p margins` must pass at every stop point. Do not delete or
   modify the existing frontend (`src/`, `index.html`) except where the plan
   explicitly says so.
5. **STOP POINT** means: commit, then stop and report what works, how the
   human can verify it, and any deviations. Human checks happen at part
   boundaries; an agent may be told to continue through intermediate steps in
   the same run (record that the intermediate human check was skipped).
6. If a tool is missing or an approach in this plan turns out wrong, say so at
   the stop point instead of silently substituting something else.
7. Named books in this plan (Karamazov, etc.) are **examples for humans**,
   not values to bake into tests or code. Fixture tests read `fixtures/*.epub`
   and check parser/import agreement (non-empty metadata, spine item present).

## Target architecture

```
Linux/Tauri app ── src-tauri (thin command layer)
                          │
macOS SwiftUI app ── crates/margins-ffi (UniFFI, thin)
   macos/                 │
                  crates/margins-core
        EPUB parsing · library · notes · search · sync
             (plain-text storage, no Tauri, no UI)
```

SwiftPM targets: `margins_ffiFFI` (C header) → `MarginsCore` (generated
bindings + `CoreStore` actor) → `MarginsModel` (UI-agnostic model layer:
`LibraryModel`, `ReaderModel`, `ReaderResource`, `ReaderKeymap`) → `Margins`
executable (SwiftUI + WKWebView glue) → `MarginsTests` (Swift Testing runner
executable).

---

## Part I — Core extraction, bindings, app shell, library UI — DONE

### Step 1 — Extract `margins-core` (workspace split)

Shipped in `728ab6c` (`REFACTOR Extract margins-core into Cargo workspace
crate`). Root `Cargo.toml` workspace with `crates/margins-core`, `crates/
margins-ffi`, `src-tauri`; `src-tauri` became a thin `#[tauri::command]`
wrapper; CI cargo steps run from the repo root.

### Step 2 — Fixture + core-level import tests

`fixtures/*.epub` example books; `crates/margins-core/tests/import_real_epub.rs`
imports every fixture into a `tempfile` library dir and checks title/author/
chapter-count agreement with `parse_epub` (no hardcoded book).

### Step 3 — `margins-ffi`: UniFFI bindings for Swift

`crates/margins-ffi` (UniFFI 0.29 proc-macro mode): `MarginsCore` object with
`data_dir`, `library_root`, `set_library_root`, `list_books`, `import_epub`,
`get_book`, `remove_book`, `read_epub_bytes`, `get_chapter_note`,
`save_chapter_note`, `search_notes`; records mirror `models.rs` with RFC3339
strings and `u32` counts; flat `CoreError`. `scripts/build-core.sh` builds the
staticlib/dylib and generates Swift into the SwiftPM layout.

### Step 4 — SwiftPM app skeleton, end-to-end bridge proof

Shipped in `078504c`. `macos/Package.swift` (Swift 6 tools, `.macOS(.v14)`);
targets `margins_ffiFFI` (C target — named for the FFI module the generated
Swift `canImport`s), `MarginsCore` (generated Swift + `CoreStore` actor;
Swift 5 language mode for UniFFI output; statically linked against
`target/release/libmargins_ffi.a` by path, plus `-llzma -lbz2`), `Margins`
executable, `MarginsTests` executable. `make-app.sh` + root `Makefile`
(`core`, `mac-build`, `mac-test`, `mac-app`, `mac-run`). Toolchain workarounds
documented in `Package.swift` (`-F` for the CLT Testing framework; rpaths for
`lib_TestingInterop.dylib`; `swift test` never invokes its runner on this
CLT — see ground truth).

### Step 5 — Library UI and import

Shipped in `ebd1668`. `MarginsModel` target with UI-agnostic `LibraryModel`
(`@MainActor @Observable`): book list, selection, import, remove, single
`errorMessage` channel. `NavigationSplitView` library browser (sidebar +
detail with metadata and `index + 1` chapter list), `NSOpenPanel` import
(`UTType.epub`, ⌘O via `Commands`), remove with confirmation dialog,
`Identifiable` conformance on the bridge records. Model-layer tests:
activate, import → selection → chapters, remove, failure surfaces an error.
Human checks (stop points 4 and 5) passed.

---

## Part II — Reader: WebKit (epub.js) + keyboard routing — DONE

### Step 1 — WebKit reader (epub.js) — DONE

Shipped in `3791401`.

1. Vendor the renderer into `macos/Sources/Margins/Resources/reader/`:
   `epub.min.js` + `jszip.min.js` (copy from `node_modules` at the versions
   pinned in `package.json`), plus hand-written `reader.html` and `reader.js`
   modeled directly on `src/reader.ts` (paginated flow, `spread: "none"`,
   paper-toned pane like `.reader-pane`).
2. `WKWebView` in an `NSViewRepresentable`. Configuration:
   - non-persistent `WKWebsiteDataStore`;
   - custom `WKURLSchemeHandler` for `margins-reader://` serving **exactly**:
     `reader.html`, `reader.js`, `epub.min.js`, `jszip.min.js`, and
     `book.epub` (bytes from `read_epub_bytes` via a thread-safe
     `CoreStore` nonisolated passthrough). Any other path → error. The
     path→resource resolution lives in a pure `ReaderResource` enum in
     `MarginsModel` so it is unit-testable without a webview;
   - navigation policy: any `http(s)` navigation → cancel and
     `NSWorkspace.shared.open` (same for `createWebViewWith`, i.e.
     `target=_blank`); only `margins-reader://` loads internally;
   - JS stays enabled (epub.js needs it); the EPUB's own scripts get no
     native message handlers in this step (the `readerKeys` handler arrives
     in step 2).
3. Clicking a chapter in the detail view opens the reader:
   `ReaderModel` (`@MainActor @Observable`, in `MarginsModel`) holds the open
   book/chapter; the webview loads
   `margins-reader://app/reader.html?book=<id>&chapter=<href>`; `reader.js`
   fetches `book.epub`, opens it with epub.js, displays that chapter;
   chapter jumps go through `evaluateJavaScript`
   (`readerDisplay(<json-quoted href>)`).
4. `make-app.sh` copies the SwiftPM resource bundle into `Contents/Resources`
   so `Bundle.module` resolves inside the `.app`.
5. Tests: `ReaderResource` resolution — the five valid paths resolve, and
   traversal / unknown / absolute-path requests are rejected.

**Verify:** `make mac-build && make mac-test && cargo test --workspace`

**Commit:** `FEAT Render EPUB chapters in WebKit via epub.js`

**Human check (may be deferred to the end of the part):** open a real EPUB
(e.g. one from `fixtures/`) → the chapter renders with correct CSS/images/
fonts; chapter clicks navigate; an external link opens in the system browser,
not in the reader.

### Step 2 — Keyboard routing — DONE

1. Keyboard routing is **native end to end**: a single local `NSEvent`
   monitor (`ShellKeyboardController`) sees every keyDown before dispatch —
   including keys headed for the reader webview — and feeds them through the
   shared `ReaderKeymap`; reader actions are injected into the page via
   `evaluateJavaScript` (`window.reader*` API in `reader.js`). An earlier
   attempt forwarded keys from `reader.js` via
   `webkit.messageHandlers.readerKeys`, but keys typed inside the epub.js
   iframe never surfaced reliably (the relay depends on epub.js internals),
   so the JS path was removed in `91dbb9e`.
2. Swift `ReaderKeymap` (in `MarginsModel`) — a small state machine mirroring
   `src/keymaps.ts` semantics: `j`/`k` scroll (±80px) in reader, move library
   selection in shell; `n`/`p` chapter; `gg`/`G` top/bottom (pending-`g`
   chord with a 1s timeout — the Tauri version has no timeout and a chord
   bug; the Swift version implements the intended behavior); `i` focus notes
   and `/` search are dispatched but wired up in Part III; `Esc`/`l` back;
   `o` import; `Enter` opens the selected book. Actions dispatch to
   `ReaderModel`/`LibraryModel`; scrolling/paging goes back into the webview
   via `evaluateJavaScript`.
3. Native side: the same keymap handles key events in **both** modes via the
   monitor — with the reader open, `j`/`k`, arrows/space/PgUp/PgDn turn
   pages and `gg`/`G` jump first/last page (paginated flow has no vertical
   overflow, so page turns are `rendition.next()/prev()` through the
   injected calls); in the shell, `j`/`k` move the library selection,
   `Enter` opens, `o` imports, `l`/`Esc` close the reader. Trackpad
   two-finger scrolling also turns pages while reading (scroll-wheel
   monitor; momentum ignored; 50pt threshold). ⌘/⌃/⌥ combos and text-field
   typing pass through to menus/inputs.
4. App-level `Commands` stay in menus: Import (⌘O), Find (⌘F → `/`),
   Settings (⌘,) placeholder.
5. Swift Testing tests for `ReaderKeymap`: chord handling (`g` then `g`,
   `g` then timeout, `G`), and that each key maps to the intended action.

**Verify:** `make mac-build && make mac-test && cargo test --workspace`

All pass (16 Swift Testing tests, 9 Rust result blocks). `reader.js` is
syntax-checked with `node --check` before every reader commit.

**Commit:** `FEAT Add vim-style reader keybindings on macOS`

**STOP POINT (Part II)** — human: with click focus *inside* the rendered EPUB
content, `j`/`k`/`n`/`p`/`gg`/`G` all work; menus still work; `Esc` returns
to the library. The intermediate human check after step 1 was skipped this
run (reader renders were to be verified here instead).

---

## Part III — Notes and search + documentation

### Step 1 — Notes and search

1. Notes pane in the reader (split or inspector): Markdown editor bound to
   `get_chapter_note`/`save_chapter_note`. `i` focuses it, `Esc` returns to
   the reader, ⌘S saves. Storage stays exactly the existing
   markdown+frontmatter files (verify by diffing a note written from the
   Tauri app's format).
2. `/` opens search over notes (`search_notes`); Enter on a hit opens that
   book/chapter.
3. Model tests: save through the bridge, reload, assert round-trip and that
   the on-disk file is markdown with YAML frontmatter.

**Verify:** `make mac-build && make mac-test && cargo test --workspace`

**Commit:** `FEAT Add chapter notes and note search to macOS app`

### Step 2 — Documentation

1. `docs/architecture.md`: core vs frontend responsibilities, the UniFFI
   bridge, the `margins-reader://` scheme and its security model (fixed
   resource set, no filesystem exposure, external links out), and how Tauri
   and SwiftUI share `margins-core`.
2. Update `README.md` (macOS build/run: `make mac-run`; requirements: CLT +
   Rust) and `AGENTS.md` (new project map, macOS commands, Swift Testing
   note).

**Verify:** links/commands in the docs actually work as written.

**Commit:** `DOCS Describe macOS frontend architecture and build workflow`

**STOP POINT (Part III)** — final acceptance review.

**Done.** Acceptance criteria (all verified across the part-boundary checks):
a real EPUB opens; metadata/chapters come from Rust; the chapter renders in
WebKit with CSS/images/fonts; keybindings work with WebKit focused; notes
remain markdown/JSON on disk; Tauri tests/builds pass; no Tauri dependency in
`margins-core`; existing frontend untouched.
