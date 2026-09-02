# macOS SwiftUI frontend — implementation plan

Goal: a native macOS SwiftUI app for Margins that imports, inspects, and reads
EPUBs, reusing the existing Rust core. Incremental — the Tauri/Linux app keeps
working at every stop point. No big-bang rewrite.

This plan is written to be executed by an AI agent phase by phase. Read
**Ground truth** and **Rules** before starting any phase.

## Status (2026-09-02)

| Phase | What | Status |
|-------|------|--------|
| 0 | Extract `margins-core` workspace crate | **done** — `728ab6c` |
| 1 | Real EPUB fixture + core import tests | **done** |
| 2 | `margins-ffi` UniFFI bindings | **done** |
| 3 | SwiftPM app skeleton / bridge proof | **done** |
| 4 | Library UI and import | not started |
| 5 | WebKit reader (epub.js) | not started |
| 6 | Keyboard routing | not started |
| 7 | Notes and search | not started |
| 8 | Documentation | not started |

Next: **Phase 4**.

---

## Ground truth (re-verified 2026-09-02 after Phase 0)

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
  (`src/reader.ts`: `ePub(bytes.buffer)` after `read_epub_bytes`). The macOS
  reader mirrors this exactly.
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
  resources (see Phase 5), so the arbitrary-path attack surface never exists.
- **`extractText` bridge API** — only needed for future in-book full-text
  search. Deferred.
- **SwiftUI `WebView`/`WebPage` (macOS 26 API)** — one code path only:
  `WKWebView` in an `NSViewRepresentable`. Less risk, works everywhere.
- **XCUITest UI tests** — impossible without Xcode. Replaced by pure-logic
  Swift Testing tests + human verification at stop points.
- **Export/import/sync UI on macOS** — core keeps the capability; UI deferred
  past this plan.
- **No database** — storage stays plain-text markdown/JSON, unchanged.

## Rules for the executing agent

1. **One phase at a time, in order.** Finish the phase's verification before
   touching the next phase.
2. **Verify, then commit.** Every phase ends with verification commands. All
   must pass before the phase's commit. If verification fails, fix it —
   never commit a red phase, never skip ahead.
3. **Commit granularity:** at minimum one commit per phase (message given
   below). Additional intermediate commits are fine if a sub-step is green.
4. **Never break Tauri.** `cargo test --workspace` and
   `cargo check -p margins` must pass at every stop point. Do not delete or
   modify the existing frontend (`src/`, `index.html`) except where a phase
   explicitly says so.
5. **STOP POINT** means: commit, then stop and report what works, how the
   human can verify it, and any deviations. Do not continue into the next
   phase in the same run unless explicitly told to keep going.
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

---

## Phase 0 — Extract `margins-core` (workspace split) — DONE

Shipped in `728ab6c` (`REFACTOR Extract margins-core into Cargo workspace crate`).

1. Root `Cargo.toml` workspace with members `crates/margins-core` and
   `src-tauri`. `src-tauri/Cargo.lock` moved to the workspace root.
2. Moved `config.rs`, `epub_meta.rs`, `library.rs`, `models.rs`, `notes.rs`,
   `sync.rs`, `test_fixtures.rs` into `crates/margins-core`. Core deps moved
   with them; `dotenvy` stayed in `src-tauri` (only the Tauri `run()` entry
   used it).
3. `src-tauri/src/lib.rs` is a thin wrapper: `use margins_core::{...}` + the
   existing `#[tauri::command]` functions. No logic changes.
4. Extra (required by the workspace move): CI cargo steps run from the repo
   root (`--workspace`); Linux bundle artifact path is `target/release/bundle/`;
   root `.gitignore` ignores `/target/`.

**Verify:**
```bash
cargo test --workspace
cargo check -p margins        # the tauri crate still compiles
npm run build                 # frontend TS still builds
```

**Commit:** `REFACTOR Extract Tauri-free margins-core crate into a workspace`

**STOP POINT 1** — human may additionally run `npm run tauri dev` to confirm
the Linux/desktop Tauri app still functions.

---

## Phase 1 — Fixture + core-level import tests — DONE

1. `fixtures/*.epub` holds example real books (optional Karamazov file is
   one such example, not a required identity).
2. Integration test `crates/margins-core/tests/import_real_epub.rs` imports
   every `fixtures/*.epub` into a `tempfile` library dir and checks, per file:
   - title and author are non-empty and match `parse_epub` on the same file;
   - chapter count matches `parse_epub` (not a hardcoded number);
   - first spine href exists in the imported `source.epub` ZIP.
3. `bdbbfcd` only changed the sample fixture + XML parser — there was no
   named test. Added `parse_manifest_attributes_in_either_order` and mixed
   `href`/`id` order on the two sample manifest items.

**Verify:** `cargo test --workspace`

**Commit:** `CHORE Add Karamazov fixture and core import integration tests`

**STOP POINT 2** (cheap — fine to bundle with Stop 1 in one session).

---

## Phase 2 — `margins-ffi`: UniFFI bindings for Swift — DONE

1. `crates/margins-ffi` is a workspace member. `crate-type` is
   `["lib", "staticlib", "cdylib"]` — `lib` extra so `cargo test --workspace`
   can compile it. Depends on `margins-core` and `uniffi` 0.29 proc-macro
   mode (no UDL). `uniffi` 0.32 exists; 0.29 matches the docs used here.
2. `MarginsCore` object: `new(data_dir: Option<String>)` uses
   `AppConfig::load_with_data_dir` (added on core; `None` still honors
   `MARGINS_DATA_DIR` / `MARGINS_LIBRARY_ROOT`). Methods: `data_dir`,
   `library_root`, `set_library_root`, `list_books`, `import_epub`,
   `get_book`, `remove_book`, `read_epub_bytes`, `get_chapter_note`,
   `save_chapter_note`, `search_notes`. Records mirror `models.rs` with
   RFC3339 date strings and `u32` counts (UniFFI has no `chrono`/`usize`).
   Errors are a flat `CoreError`. Sync export/import is not on this surface
   (UI deferred).
3. `crates/margins-ffi/src/bin/uniffi-bindgen.rs` calls
   `uniffi::uniffi_bindgen_main()`.
4. `scripts/build-core.sh` release-builds the crate and generates Swift into
   `macos/Sources/MarginsCoreFFI/Generated/` (`.swift`, header, modulemap).
   That directory is gitignored. Phase 3 Package.swift will split C vs Swift
   targets; generated files stay together until then.

**Verify:**
```bash
./scripts/build-core.sh
ls target/release/libmargins_ffi.a macos/Sources/MarginsCoreFFI/Generated/*.swift
cargo test --workspace
```

**Commit:** `FEAT Add margins-ffi UniFFI crate and Swift binding generation`

**STOP POINT 3**

---

## Phase 3 — SwiftPM app skeleton, end-to-end bridge proof — DONE

1. `macos/Package.swift` — Swift 6 tools, platform `.macOS(.v14)`, targets:
   - `margins_ffiFFI` (C target: generated header + module map). Named after
     the FFI module, not `MarginsCoreFFI`: the generated bindings do
     `#if canImport(margins_ffiFFI)` and SwiftPM requires a custom module
     map's module name to match its target name.
   - `MarginsCore` (generated Swift in `Generated/` + hand-written
     `CoreStore` actor wrapper). Compiled in Swift 5 language mode (UniFFI
     0.29 output is not strict-concurrency clean); the app targets use
     Swift 6 mode. Linking: the static archive
     `target/release/libmargins_ffi.a` is passed **by path** (ld prefers a
     dylib when both exist, which would make binaries depend on
     `target/release/deps/`), plus `-llzma -lbz2` for zip's xz2/bzip2 deps
     (both ship in the macOS SDK; zstd is vendored into the archive).
   - `Margins` executable (SwiftUI `@main`, `@Observable LibraryModel`,
     `ContentView`; bridge calls go through the `CoreStore` actor so they
     run off the main actor).
   - `MarginsTests` executable (Swift Testing, see ground truth).
2. Minimal SwiftUI app: one window shows the library root path and book
   titles/authors from `list_books()` — proves Swift→Rust end to end.
3. `scripts/make-app.sh`: assembles `build/Margins.app` (Contents/MacOS
   binary, Info.plist with bundle id `app.margins.Margins` +
   `NSPrincipalClass NSApplication`), ad-hoc signs with `codesign -s -`.
   The binary statically links the Rust core — self-contained.
4. Root `Makefile`: `core`, `mac-build`, `mac-test`, `mac-app`, `mac-run`.
5. Swift Testing tests (`MarginsTests`): for every `fixtures/*.epub`, import
   through the bridge into an explicit temp data dir (passed to the
   constructor — parallel-safe, instead of the `MARGINS_DATA_DIR` env var);
   assert non-empty title/author, non-empty chapters, and that re-reading
   via `get_book`/`list_books` agrees with the import-time parse (same
   contract as Phase 1 — no hardcoded book). Plus a data-dir round-trip
   test.
6. Toolchain workarounds baked into `Package.swift` (documented there): the
   CLT's Swift Testing framework must be added via `-F` (SwiftPM only passes
   `-I`, which cannot resolve framework modules) and linked with rpaths to
   `Library/Developer/Frameworks` and `Library/Developer/usr/lib` (home of
   `lib_TestingInterop.dylib`).

**Verify:**
```bash
make mac-build
make mac-test
make mac-app && ls build/Margins.app/Contents/MacOS
cargo test --workspace
```

All four pass. Note: `swift test` remains intentionally unused (silently
runs nothing on this toolchain — see ground truth).

**Commit:** `FEAT Add SwiftPM macOS app shell wired to Rust core`

**STOP POINT 4** — human: `make mac-run`, confirm a window appears listing the
library (or an empty library) with the correct root path.

---

## Phase 4 — Library UI and import

1. `NavigationSplitView`: sidebar = books (title, author), detail = book
   metadata + chapter list from the bridge. Selection state in an
   `@Observable` `LibraryModel`.
2. Import: `NSOpenPanel` (epub only) → `import_epub` → refresh list. Surface
   import errors in an alert.
3. Remove book with confirmation.
4. SwiftUI `Commands`: File ▸ Import EPUB… (⌘O), standard Close/Quit.
5. Unit tests for the model layer (import → selection → chapters) via the
   bridge against a temp data dir.

**Verify:** `make mac-build && make mac-test && cargo test --workspace`

**Commit:** `FEAT Add macOS library browser with EPUB import`

**STOP POINT 5** — human: import any EPUB via ⌘O (e.g. a file from
`fixtures/`); metadata and the full chapter list appear, sourced from Rust.

---

## Phase 5 — WebKit reader (epub.js) — *the vertical slice*

1. Vendor the renderer into
   `macos/Sources/Margins/Resources/reader/`:
   `epub.min.js` + `jszip.min.js` (copy from `node_modules` at the versions
   pinned in `package.json`), plus hand-written `reader.html` and `reader.js`
   modeled directly on `src/reader.ts` (paginated flow, `spread: "none"`).
2. `WKWebView` in an `NSViewRepresentable`. Configuration:
   - non-persistent `WKWebsiteDataStore`
   - custom `WKURLSchemeHandler` for `margins-reader://` serving **exactly**:
     `reader.html`, `reader.js`, `epub.min.js`, `jszip.min.js`, and
     `book.epub` (bytes from `read_epub_bytes`). Any other path → error.
     Factor the path→resource resolution into a pure `ReaderResource` enum so
     it is unit-testable without a webview.
   - navigation policy: any `http(s)` navigation → cancel and
     `NSWorkspace.shared.open`; only `margins-reader://` loads internally.
   - JS stays enabled (epub.js needs it); the EPUB's own scripts are not
     given any native message handlers besides the ones defined in Phase 6.
3. Reader loads `margins-reader://app/reader.html?book=<id>`; `reader.js`
   fetches `book.epub`, opens with epub.js, displays the chapter chosen in
   the sidebar (`evaluateJavaScript` for chapter jumps).
4. Tests: `ReaderResource` resolution — the five valid paths resolve, and
   traversal / unknown / absolute-path requests are rejected.

**Verify:** `make mac-build && make mac-test && cargo test --workspace`

**Commit:** `FEAT Render EPUB chapters in WebKit via epub.js`

**STOP POINT 6 — acceptance check for the vertical slice.** Human:
open a real EPUB (e.g. one from `fixtures/`) → first chapter renders with
correct CSS/images/fonts; chapter clicks navigate; an external link opens
in the system browser, not in the reader.

---

## Phase 6 — Keyboard routing

1. In `reader.js`, hook epub.js's rendition `keydown` (fires for keys inside
   EPUB iframes — same hook `src/reader.ts` uses) **and** document-level
   keydown; forward `{key, ctrl, meta, shift}` to Swift via
   `webkit.messageHandlers.readerKeys`.
2. Swift `ReaderKeymap` — a small state machine mirroring `src/keymaps.ts`
   semantics: `j`/`k` scroll, `n`/`p` chapter, `gg`/`G` top/bottom (with the
   pending-`g` chord + timeout), `i` focus notes, `/` search, `Esc` back.
   Actions dispatch to the reader model; scrolling/paging goes back into the
   webview via `evaluateJavaScript`.
3. Native side: the same keymap handles key events when focus is in the
   SwiftUI shell (library list: `j`/`k`/`Enter`, `o` import, `l` library),
   via `onKeyPress` or a local `NSEvent` monitor — whichever proves reliable;
   note the choice at the stop point.
4. App-level `Commands` stay in menus: Import (⌘O), Find (⌘F → `/`),
   Settings (⌘,) placeholder.
5. Swift Testing tests for `ReaderKeymap`: chord handling (`g` then `g`,
   `g` then timeout, `G`), and that each key maps to the intended action.

**Verify:** `make mac-build && make mac-test && cargo test --workspace`

**Commit:** `FEAT Add vim-style reader keybindings on macOS`

**STOP POINT 7** — human: with click focus *inside* the rendered EPUB
content, `j`/`k`/`n`/`p`/`gg`/`G` all work; menus still work.

---

## Phase 7 — Notes and search

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

**STOP POINT 8**

---

## Phase 8 — Documentation

1. `docs/architecture.md`: core vs frontend responsibilities, the UniFFI
   bridge, the `margins-reader://` scheme and its security model (fixed
   resource set, no filesystem exposure, external links out), and how Tauri
   and SwiftUI share `margins-core`.
2. Update `README.md` (macOS build/run: `make mac-run`; requirements: CLT +
   Rust) and `AGENTS.md` (new project map, macOS commands, Swift Testing
   note).

**Verify:** links/commands in the docs actually work as written.

**Commit:** `DOCS Describe macOS frontend architecture and build workflow`

**Done.** Acceptance criteria (all verified across stop points 6–8): a real
EPUB opens; metadata/chapters come from Rust; first chapter renders in WebKit
with CSS/images/fonts; keybindings work with WebKit focused; notes remain
markdown/JSON on disk; Tauri tests/builds pass; no Tauri dependency in
`margins-core`; existing frontend untouched.
