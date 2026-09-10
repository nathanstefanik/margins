# Plan: Apple-only consolidation, CI repair, and chapter outline

Status: proposed · Written 2026-09-10 · Audience: an AI agent implementing it.

Three asks, one plan, ordered so each phase leaves `main` green and the
later phases have less surface to touch:

| Phase | What | Why this order |
|-------|------|----------------|
| 0 | Fix the macOS CI job (Swift tools 6.2 vs runner's 6.0.3) | Nothing else can be verified in CI until this passes. Smallest diff. |
| 1 | Delete the Tauri/Linux frontend | Removes a third UI that every later change would otherwise have to keep in sync. Also removes the Linux job that is failing on artifact quota. |
| 2 | Chapter identification in the Rust core: matter classification, outline levels, multi-entry files | The user-facing bug. Core first, tested against fixtures. |
| 3 | Chapter list UI on macOS and iOS driven by the new metadata | Consumes Phase 2. |
| 4 | Cleanup: test target, stale docs/comments, scripts | Low risk, do after the functional work. |
| 5 | (Optional, gated) Port the core from Rust to Swift | Recommendation below is **not now**. Documented so the decision is explicit. |

Every phase is one PR. Commit-message prefixes per `AGENTS.md`.

---

## Verified facts this plan rests on

- `apple/Package.swift` declares `swift-tools-version:6.2` and
  `.iOS(.v26)` since commit `5c68a36` ("Require iOS 26 for the iOS app").
- CI (`.github/workflows/ci.yml`) and release (`release.yml`) run the macOS
  job on `runs-on: macos-14` with `maxim-lobanov/setup-xcode@v1`
  `xcode-version: latest-stable`. On the macos-14 image the newest Xcode is
  16.2, whose SwiftPM is 6.0.3. Hence:
  `package 'apple' is using Swift tools version 6.2.0 but the installed version is 6.0.3`.
  Every CI run since 2026-09-09 fails at "Build core and run the Swift
  Testing suite" (`make mac-test`). `make ios-core` and the iOS simulator
  build never run.
- GitHub's macos-14 image is deprecated. `macos-26` (arm64, also
  `macos-latest`) ships Xcode 26.0.1 through 26.6 with 26.6 as default; the
  local dev machine runs Xcode 26.6 (17F113), Swift 6.3.3, with
  `xcode-select` pointing at `/Applications/Xcode.app`. `macos-15` defaults
  to Xcode 16.4 but also has 26.0.1–26.3.
- The Linux CI job also fails, independently: "Artifact storage quota has
  been hit" on the upload-artifact step. Phase 1 deletes the job.
- The Rust workspace is `crates/margins-core` (domain, ~5.5k lines with
  tests), `crates/margins-ffi` (UniFFI 0.29 bridge), and `src-tauri`. Only
  `src-tauri` depends on Tauri. The Apple apps never touch `src/` or
  `src-tauri/`; the shared reader page is a separate vendored copy at
  `apple/Sources/MarginsModel/Resources/reader/`.
- The macOS app is SwiftUI (`apple/Sources/Margins`, executable target
  `Margins`). The iOS app is SwiftUI (`apple/ios/Margins`). Both consume
  `MarginsCore` + `MarginsModel` from the same SwiftPM package.
- Chapter model: `ChapterMeta { key, index, title, href, fragment }` in
  `crates/margins-core/src/models.rs`. One chapter per spine item.
  `key` = zero-padded spine position and anchors note filenames,
  `notes/_index.json`, frontmatter and `position.json` (`docs/storage.md`).
  **Keys must not change.** `library.rs` already re-parses `chapters` from
  the retained `source.epub` on scan when `meta.chapters_version <
  CHAPTERS_VERSION` (currently 1), keeping keys.
- Title resolution (`epub_meta.rs::resolve_chapter_titles`): TOC label,
  else first `<h1>`–`<h3>`, else `<title>`, else `Chapter {n}`. The TOC is
  indexed by target file and **only the first TOC entry per file survives**
  (`toc_by_path`).
- Running the parser on `fixtures/dostoyevsky_the_karamazov_brothers.epub`
  (Gutenberg, NCX only, flat navMap) yields 100 chapters including:
  `001 "Cover"` (literal quotes leaked from `<title>"Cover"</title>`),
  `002 The Brothers Karamazov` (Gutenberg header), `003 PART I` (the file
  also holds "Book I. The History Of A Family", which is lost),
  `009 Book II. An Unfortunate Gathering` (the file also holds "Chapter I.
  They Arrive At The Monastery", which is lost; the list then goes straight
  to `010 Chapter II`), and `100 FOOTNOTES`. Every "Chapter I" in the book
  after Book I is missing for the same reason.
- The user's Oxford World's Classics edition (not in `fixtures/`) shows the
  same problem in a different shape: an EPUB3 with one spine file per
  front-matter page (Cover, half title, series page, copyright,
  acknowledgements, dedication, contents, introduction, translator's note,
  texts used, bibliography, chronology, principal characters, "From the
  Author", Part One, Book One) each listed as a numbered chapter before
  "1. Fyodor Pavlovich Karamazov".
- Spine parsing ignores `linear="no"`. `is_probably_content` drops any
  href containing the substrings `toc` or `nav` instead of using the
  manifest media type.
- `ReaderModel.bookPercent` divides `chapter.index` (spine position) by
  `book.chapters.count` (filtered list length). Harmless today because the
  filter rarely drops spine items; it matters once Phase 2 filters more.

---

## Recommendations (answers to the framework question)

**Delete Tauri.** Its only remaining purpose was Linux, which is out of
scope. macOS already runs on native SwiftUI; the Tauri app duplicates every
feature and every keymap change has to be made three times. For an
Apple-only product Tauri is the wrong tool regardless: it adds a Node
toolchain, a webview-hosted UI that can never match native chrome, and a
second command layer over the core.

**Keep the Rust core for now.** Starting fresh for iOS + macOS only, a
pure-Swift core would be the natural choice (one toolchain, no UniFFI, no
xcframework assembly, `swift test` directly, native file coordination).
But the core exists, has a good test suite, and its cost is almost entirely
build plumbing that is already written (`scripts/build-core.sh`,
`build-xcframework.sh`, the header-only C target). A port is a
multi-thousand-line rewrite whose main deliverable would be a simpler
Makefile. Do it only when a concrete trigger appears (Phase 5 lists them).
Until then the Rust core is the single source of truth for storage format
and parsing, and Phase 2 lives there.

**Keep epub.js in WKWebView** for rendering. The Readium Swift toolkit is
the native alternative but is far heavier, and the current page plus scheme
handler is small and understood.

**Keep SwiftPM as the macOS build** (no `.xcodeproj` for macOS) and the
committed Xcode project for iOS. No change.

---

## Phase 0 — Unblock CI (Swift 6.2 toolchain)

Goal: `make mac-test`, `make ios-core`, and the iOS simulator build run on
CI with the same Xcode major as local development.

### Changes

1. `.github/workflows/ci.yml`, job `macos`:
   - `runs-on: macos-26`
   - Keep `maxim-lobanov/setup-xcode@v1` but pin `xcode-version: "26.6"`
     so CI and the local machine (26.6, 17F113) match. If the image later
     drops 26.6, fall back to `latest-stable`; never go below 26.0 because
     the iOS target is `.iOS(.v26)`.
   - Rename the step to "Select Xcode 26 (Swift 6.2+ / iOS 26 SDK)".
2. `.github/workflows/release.yml`, job `macos`: same two edits.
3. `docs/architecture.md` "Building and running (macOS)": replace
   "Requirements: Rust (stable) and Apple Command Line Tools" with Rust
   stable + Xcode 26 (full Xcode is now required for iOS anyway).
4. `AGENTS.md`: the note "The macOS app builds with Command Line Tools
   alone" is still true for `make mac-build` but CI no longer relies on it.
   Leave it; Phase 4 revisits when the test runner changes.

### Watch-outs

- `apple/Package.swift` passes `-F /Library/Developer/CommandLineTools/…`
  and an rpath into the CLT's `Testing.framework` for the `MarginsTests`
  executable. On the macos-26 image the CLT is installed alongside Xcode,
  so the path exists; if the CLT's Swift Testing ABI ever disagrees with
  the selected Xcode's compiler, `make mac-test` fails to link. If that
  happens in this phase, pull Phase 4 step 1 (real `.testTarget`) forward
  into this PR rather than patching the flags.
- Do not touch `runs-on` of the Linux job here; Phase 1 deletes it.

### Verify

- Push the branch, open the PR, confirm the macOS job passes all three
  steps (`make mac-test`, `make ios-core`, simulator `xcodebuild`).
- Locally: `make mac-test` still passes with Xcode 26.6 selected.

---

## Phase 1 — Remove the Tauri/Linux frontend

Goal: the repository builds exactly two things, the macOS app and the iOS
app, over one Rust core. No Node, no Vite, no Tauri, no Linux CI.

### Delete

- `src/` (app.ts, reader.ts, keymaps.ts, api.ts, main.ts, styles.css,
  epubjs.d.ts, assets/)
- `src-tauri/` (entire directory: Cargo.toml, src/, build.rs,
  tauri.conf.json, capabilities/, icons/, gen/ if present)
- `index.html`, `vite.config.ts`, `tsconfig.json`, `package.json`,
  `package-lock.json`
- `scripts/test-keymap.mjs`, `scripts/test-reader-keymap.mjs` (they test
  `src/keymaps.ts` and `src/reader.ts`; the Swift equivalents are
  `ReaderKeymapTests.swift` and `BridgeTests.swift`)
- `.github/workflows/ci.yml` job `linux` (whole job, including
  `concurrency` stays)
- `.github/workflows/release.yml` job `linux`; in job `release` change
  `needs: [linux, macos]` to `needs: [macos]` and drop the Linux artifact
  names from the SHA256SUMS step if referenced.

### Edit

- `Cargo.toml`: `members = ["crates/margins-core", "crates/margins-ffi"]`.
  Then `cargo build --workspace` and commit the pruned `Cargo.lock`
  (Tauri's ~400 transitive crates disappear). `cargo clippy --locked
  --workspace --all-targets -- -D warnings` must still pass with `--locked`.
- `.gitignore`: remove `node_modules/`, `dist/`, `src-tauri/WixTools/`,
  `npm-debug.log*`.
- `.vscode/extensions.json`: recommendations become
  `["rust-lang.rust-analyzer", "swiftlang.swift-vscode"]`.
- `scripts/bump-version.sh`: remove everything that touches `package.json`,
  `package-lock.json`, `src-tauri/tauri.conf.json`; keep the Cargo.toml
  workspace version and the iOS `MARKETING_VERSION`. Remove the `node -e`
  block entirely. Update the header comment and the `git add` list.
- `.github/workflows/release.yml` step "Verify tag matches package
  version": read the version from `Cargo.toml` instead of `package.json`:
  ```sh
  version=$(cargo metadata --no-deps --format-version 1 \
    | jq -r '.packages[] | select(.name=="margins-core") | .version')
  ```
  (Rust is set up two steps later; move the "Set up Rust" step above this
  one, or use `grep -m1 '^version = ' Cargo.toml | cut -d'"' -f2`.)
- `Makefile`: no Tauri targets exist; no change. Add a `vendor-reader`
  target (see next bullet).
- epub.js vendoring: `package.json` was the version pin for the vendored
  `epub.min.js` / `jszip.min.js`. Replace it with
  `scripts/vendor-reader.sh` that downloads pinned versions
  (`epubjs@0.3.93` from `https://unpkg.com/epubjs@0.3.93/dist/epub.min.js`,
  `jszip@3.10.1` from `https://unpkg.com/jszip@3.10.1/dist/jszip.min.js`),
  verifies a hard-coded sha256 for each, and copies them into
  `apple/Sources/MarginsModel/Resources/reader/`. Record the versions and
  hashes at the top of the script. Confirm the current vendored files hash
  to the pinned versions before committing the script; if they do not,
  pin whatever version they actually are (compare against unpkg).
- `README.md`: rewrite the intro line ("Minimal EPUB reader for macOS and
  iOS…"), delete the `npm run tauri …` sections and the Tauri keybinding
  table, keep the macOS/iOS sections, update "Status" so the first "Done"
  bullet no longer names Tauri (describe the Rust core alone).
- `AGENTS.md`: "three frontends" becomes two; drop `src-tauri/src/` and
  `src/` from the project map; drop `npm install`, `npm run tauri dev/build`
  from useful commands; `cargo test --workspace` comment "(covers core +
  tauri)" becomes "(core + ffi)"; in "Agent tasks" delete the sentence about
  the footer keybar in `index.html`.
- `docs/architecture.md`: remove the Tauri branch from the diagram and the
  "Linux/Tauri app" paragraph; the "Reader rendering" paragraph no longer
  "mirrors the Tauri frontend's src/reader.ts"; "Requirements" paragraph
  drops "the Tauri app is never broken by Apple-platform work".
- `docs/storage.md` line ~177 ("the notes panes and Tauri editor edit"):
  drop "and Tauri editor".
- `docs/packaging-plan.md`: add a line under the status paragraph that
  Phases 3–4 (Linux .deb/.rpm/AUR) are **dropped** with Tauri, and the
  Linux mentions in Phase 0 are historical.
- `docs/notes-page-plan.md`, `docs/ios-plan.md`: historical plans. Add one
  line at the top of each: "Historical. The Tauri frontend referenced below
  was removed on <date> (docs/apple-only-plan.md Phase 1)." Do not rewrite
  their bodies.
- Comments that mention Tauri in Swift/JS (verified locations):
  `apple/Sources/MarginsModel/Resources/reader/reader.js:3`,
  `apple/Sources/MarginsModel/LibraryModel.swift:364`,
  `apple/Sources/MarginsModel/ReaderKeymap.swift:57` and `:140`. Reword to
  describe the behavior without the comparison.
- `CHANGELOG.md`: "Removed: Tauri/Linux frontend. Margins is now macOS and
  iOS only."
- Rust core: leave `sync.rs`, `config.rs::MARGINS_DATA_DIR`, and every
  `pub fn` alone. They are not Tauri-specific; `sync` is simply not yet
  exposed to Swift (already documented). `dotenvy` disappears with
  `src-tauri`. If `cargo clippy` reports newly dead code in the core after
  the workspace shrinks, that is a signal the function was Tauri-only; keep
  it if `docs/architecture.md` lists it as planned for Swift, otherwise
  delete it in the same PR.

### Verify

- `cargo fmt --all -- --check`, `cargo clippy --locked --workspace
  --all-targets -- -D warnings`, `cargo test --locked --workspace`.
- `make mac-test`, `make ios-core`, and the CI simulator build.
- `git grep -i tauri` returns only the historical-plan notes and
  `CHANGELOG.md`. `git grep -n "npm\|vite\|package.json"` returns nothing
  outside `CHANGELOG.md` and the historical docs.
- CI has exactly one job and it is green.

---

## Phase 2 — Chapter identification in the core

Goal: the core describes a book's structure well enough for a UI to show a
clean outline: front matter grouped, parts/books as headings, body chapters
numbered from one, back matter grouped, and no TOC entries lost when a file
contains several. Keys, note files, and reading positions are untouched.

### Data model (`crates/margins-core/src/models.rs`)

Add to `ChapterMeta`, all with `#[serde(default)]` so old `meta.json`
files still deserialize (the scan then upgrades them):

```rust
/// Where a spine item sits in the book's structure.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum Matter {
    Cover,
    Front,
    #[default]
    Body,
    Back,
}

/// One table-of-contents entry that starts inside a spine item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChapterSection {
    pub title: String,
    /// Anchor id inside the chapter's `href`; `None` = top of file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fragment: Option<String>,
    /// Outline depth: 0 = part/volume, 1 = book (or chapter when the book
    /// has no parts), … Leaves are the deepest level present.
    pub level: u8,
}

pub struct ChapterMeta {
    // existing: key, index, title, href, fragment
    #[serde(default)]
    pub matter: Matter,
    /// Outline depth of `title` (== sections[0].level when sections is
    /// non-empty; 0 otherwise).
    #[serde(default)]
    pub level: u8,
    /// Every TOC entry that targets this file, in reading order. Empty
    /// when the TOC has no entry for the file. When non-empty,
    /// `sections[0].title == title` and `sections[0].fragment == fragment`.
    #[serde(default)]
    pub sections: Vec<ChapterSection>,
}
```

Invariants to document in `docs/storage.md`:

- `key`, `index`, `href` unchanged in meaning. `title`/`fragment` remain
  the first TOC entry for the file (existing behavior), so note frontmatter
  and search hits keep matching.
- `sections` is the new information. A file holding "Book II" and
  "Chapter I" now has two sections; the UI renders both rows, both open
  the same chapter key at different fragments, and the chapter note for
  that key is shared. This is a deliberate trade: sub-file chapters do not
  get their own note file, because that would change the key scheme.
- Bump `library.rs::CHAPTERS_VERSION` to `2`. The existing scan upgrade
  re-parses `source.epub` and rewrites `chapters` without moving keys.
  Extend `scan_upgrades_legacy_chapter_metadata_without_moving_keys` to
  assert `matter`/`sections` are populated after upgrade.

### Spine and content filtering (`epub_meta.rs`)

1. Replace the `parse_spine` regex with quick-xml attribute parsing that
   returns `Vec<SpineItem { idref, linear: bool }>` (`linear` defaults to
   true; `"no"` → false). Skip `linear == false` items when building
   candidates. `index` stays the raw spine position so keys are stable.
2. Replace `is_probably_content(href)` with a manifest-driven check: keep
   an item when `media_type` is `application/xhtml+xml` or `text/html`
   (case-insensitive) and `properties` does not contain `nav`. Fall back
   to the extension check (`.xhtml`, `.html`, `.htm`, `.xml`) only when
   `media_type` is absent. Delete the `toc`/`nav` substring test. Add a
   test with a chapter file named `navarre.xhtml` to prove it is kept.
3. `clean_text`: after collapsing whitespace, strip one pair of surrounding
   straight or curly double quotes (`"Cover"` → `Cover`). Test it.

### TOC parsing keeps nesting and all entries per file

- `TocEntry` gains `level: u8`. `parse_ncx` already tracks a stack; the
  level is `stack.len() - 1` at push time. `parse_nav_document` must track
  `<ol>` depth inside the chosen `<nav>` (`level = ol_depth - 1`); today it
  ignores nesting.
- Replace `toc_by_path` (first entry wins) with
  `toc_sections_by_path: HashMap<String, Vec<TocEntry>>` preserving
  reading order. `ChapterCandidate` carries the whole `Vec`.
- When the TOC is flat (every entry level 0) infer levels from labels so
  Gutenberg-style NCX files still outline. Ladder, case-insensitive on the
  trimmed label:
  - `^(part|volume)\b` → level 0
  - `^book\b` → level 1 if any part/volume label exists in the book, else 0
  - everything else → `max container level seen so far + 1` (so chapters
    under a Book under a Part get level 2; chapters in a book with no
    containers get level 0)
  Apply inference only when the TOC has no nesting at all; a nested TOC is
  authoritative.

### Matter classification

Compute `matter` per candidate from signals in this priority order. The
first signal that decides a file wins; later signals only fill gaps.

1. **Landmarks / guide** (book-level, most reliable):
   - EPUB3 nav document: a `<nav epub:type="landmarks">` whose anchors carry
     `epub:type`. `bodymatter` → that file starts Body; `backmatter` → that
     file starts Back; `cover`, `titlepage`, `frontmatter`, `toc`,
     `copyright-page` → Front (cover → Cover).
   - EPUB2 OPF `<guide><reference type="…" href="…"/>`: `text` starts Body;
     `cover` → Cover; `title-page`, `toc`, `copyright-page`,
     `acknowledgements`, `dedication`, `epigraph`, `foreword`, `preface`,
     `loi`, `lot` → Front; `bibliography`, `glossary`, `index`, `notes`,
     `colophon` → Back.
   - Resolve hrefs the same way TOC targets are resolved (relative to the
     declaring document, percent-decoded, normalized). Reuse `toc_entry`'s
     path logic.
2. **Per-document `epub:type`**: scan the first 8 KB of the file for
   `epub:type="…"` on `<body>` or the first `<section>`. Map: `cover` →
   Cover; `frontmatter`, `titlepage`, `halftitlepage`, `copyright-page`,
   `toc`, `dedication`, `acknowledgments`, `epigraph`, `foreword`,
   `preface`, `introduction`, `landmarks`, `loi`, `lot` → Front;
   `bodymatter`, `part`, `chapter`, `volume`, `prologue`, `epilogue` →
   Body (prologues and epilogues are story); `backmatter`, `afterword`,
   `appendix`, `bibliography`, `colophon`, `endnotes`, `footnotes`,
   `glossary`, `index`, `notes` → Back. Values are space-separated; when
   both a partition value (`frontmatter`/`bodymatter`/`backmatter`) and a
   specific value are present, the partition value decides, except that
   `cover` always yields Cover.
3. **Cover by shape**: file whose visible text after tag stripping is under
   40 characters and contains an `<img>` or `<svg>` → Cover. This catches
   Gutenberg's `wrap0000.html`.
4. **Title heuristics** on the resolved title (TOC label or heading),
   trimmed, case-insensitive, matched as a whole string or a prefix followed
   by a non-letter. Keep the lists as `const` slices with a unit test each.
   - Front: `cover`, `half title`, `halftitle`, `half-title`, `title page`,
     `series page`, `copyright`, `acknowledg(e)ments`, `dedication`,
     `contents`, `table of contents`, `epigraph`, `about the author`,
     `also by`, `by the same author`, `a note on the`, `note on the`,
     `translator's note`, `translators' note`, `texts used`, `select
     bibliography`, `further reading`, `chronology`, `a chronology`,
     `principal characters`, `list of`, `introduction`, `preface`,
     `foreword`, `from the author`, `author's note`, plus any title that
     equals the book title or the publisher series name (e.g. "Oxford
     World's Classics": detect as an all-caps title with ≤ 4 words that
     appears before the first Body file).
   - Back: `notes`, `endnotes`, `footnotes`, `explanatory notes`,
     `glossary`, `index`, `appendix`, `afterword`, `bibliography`,
     `colophon`, `about the publisher`, `other books by`, `also available`.
   - Only apply Front titles to the run of files **before the first Body
     file has been established**, and Back titles to the run **after the
     last Body file**. "Introduction" after chapter 3 stays Body;
     "Prologue" is never Front by title (it is story).
5. **Position fallback**: with no landmark/guide `bodymatter`/`text`
   signal, Body starts at the first file not classified Cover/Front by
   signals 2–4. Back is the maximal suffix classified Back by 2 or 4.
   Everything between is Body.

Sanity rules after classification:

- If the result has zero Body files, everything non-Cover becomes Body
  (never hide a whole book).
- A file with a `sections` entry whose label matches `^(part|book|volume|
  chapter)\b` or starts with a number/Roman numeral is Body regardless of
  title heuristics (guards against "Book One: Introduction" style labels).

### `parse_epub` changes

- Collect `linear`, `sections`, `level`, and the classification inputs
  into `ChapterCandidate`; `resolve_chapter_titles` becomes
  `resolve_chapters` and fills the new fields. Keep the shared-title
  boilerplate logic exactly as is.
- `EpubInfo` unchanged in shape (chapters carry the data).

### FFI (`crates/margins-ffi/src/types.rs`)

- Add `#[derive(uniffi::Enum)] pub enum Matter { Cover, Front, Body, Back }`,
  `#[derive(uniffi::Record)] pub struct ChapterSection { title, fragment,
  level: u8 }`, and the three new fields on `ChapterMeta`. Update the
  `From<models::ChapterMeta>` impl. Run `make core` to regenerate Swift.

### Tests (`epub_meta.rs`, `test_fixtures.rs`, `library.rs`)

Extend `write_sample_epub_full` (or add `write_structured_epub`) so a test
can declare, per spine item: filename, `<title>`, heading, body text,
optional `epub:type`, `linear`, and per-book: NCX or nav TOC with nesting,
optional `<guide>`, optional landmarks nav. Then add:

- `oxford_style_front_matter_is_classified`: 16 front-matter files with
  the exact titles from the user's report, then "Part One", "Book One: The
  Story of a Family" (same file), chapters "1. Fyodor Pavlovich
  Karamazov"…"3. …", then "Explanatory Notes", "Index". Assert matter per
  key, `level`s (Part 0, Book 1, chapters 2), and that the first Body key
  is the Part file.
- `epub3_landmarks_bodymatter_wins_over_title_heuristics`: a file titled
  "Introduction" flagged `bodymatter` in landmarks is Body.
- `epub2_guide_text_reference_starts_body`.
- `linear_no_items_are_skipped_without_moving_keys`.
- `nav_document_nesting_sets_levels` and `ncx_nesting_sets_levels`.
- `flat_ncx_levels_are_inferred_from_labels` (Part/Book/Chapter ladder).
- `every_toc_entry_in_a_file_becomes_a_section` (two entries, one file).
- `cover_wrapper_is_detected_by_shape` and `title_quotes_are_stripped`.
- `manifest_media_type_drives_content_filter` (`navarre.xhtml` kept, an
  `.ncx` in the spine dropped, `properties="nav"` doc dropped).
- Extend `karamazov_fixture_titles_come_from_the_ncx` (rename to
  `karamazov_fixture_outline`) to assert: key `001` is `Matter::Cover` with
  title `Cover`; `002` is Front; `003` has sections `["PART I" (0),
  "Book I. The History Of A Family" (1)]` and is Body; `009` has sections
  `["Book II. An Unfortunate Gathering" (1), "Chapter I. They Arrive At The
  Monastery" (2)]`; `100 FOOTNOTES` is Back; the number of Body sections
  whose title starts with `Chapter ` is 96 (the fixture's `toc.ncx` has
  120 navPoints, 96 of them `Chapter …` labels; today only 84 survive
  because same-file entries are dropped); no title starts with "The
  Project Gutenberg eBook".
- `library.rs`: bump the legacy-upgrade test to check `chapters_version ==
  2` and that `matter` is populated; note files untouched.

### Verify

- `cargo test --locked --workspace`, clippy, fmt.
- `make core` regenerates bindings; `make mac-test` still passes with the
  new record fields (Swift code compiles because the fields are additive).
- Import the fixture in the macOS app (`make mac-run`) and inspect
  `books/<id>/meta.json`: `chapters_version: 2`, `sections` present.

---

## Phase 3 — Outline UI on macOS and iOS

Goal: replace the flat numbered spine list in three places with one shared
outline: `apple/Sources/Margins/BookDetailView.swift` (`chaptersList`),
`apple/ios/Margins/BookDetailView.swift` (`ContentsList`), and
`apple/ios/Margins/Reader/ReaderScene.swift` (`TOCSheet`).

### Shared model (`apple/Sources/MarginsModel/ContentsOutline.swift`, new)

Pure, testable, no SwiftUI:

```swift
public struct OutlineRow: Identifiable, Equatable {
    public enum Kind: Equatable { case heading(level: Int), chapter(number: Int), matter }
    public let id: String            // "\(chapter.key)#\(sectionIndex)"
    public let chapter: ChapterMeta
    public let section: ChapterSection?  // nil when the chapter has no TOC entries
    public let title: String
    public let kind: Kind
    public var jumpFragment: String? { section?.fragment ?? chapter.fragment }
}

public struct ContentsOutline: Equatable {
    public let front: [OutlineRow]   // Cover + Front, in spine order
    public let body: [OutlineRow]    // headings and numbered chapters
    public let back: [OutlineRow]
    public static func build(from chapters: [ChapterMeta]) -> ContentsOutline
}
```

Rules in `build`:

- Every `ChapterSection` becomes a row; a chapter with no sections becomes
  one row using its own title. Body rows are `.heading(level:)` when a
  later row in the same chapter or the next body row has a greater level,
  else `.chapter(number:)` with numbers counting from 1 across the whole
  body in reading order. Front/back rows are `.matter`.
- If every body row would be a heading (degenerate), fall back to numbering
  all body rows.
- Tests in `apple/Sources/MarginsTests/ContentsOutlineTests.swift`:
  Gutenberg-shaped input (Part/Book/Chapter from flat-inferred levels),
  Oxford-shaped input, a book with no TOC (every row numbered), a book with
  only Body (front/back empty), and the degenerate all-headings case.

### Views

- macOS `BookDetailView.chaptersList`: render `outline.front` inside a
  `DisclosureGroup("Front matter (n)")` collapsed by default; `outline.body`
  rows with headings styled as small-caps secondary text without a number,
  chapters with their `number`; `outline.back` in a collapsed "Back matter
  (n)" group. Clicking any row calls `openReader(chapter)` then jumps to
  `jumpFragment` (the reader already supports `href#fragment` via
  `readerDisplay`; check `ReaderController` for how the initial jump is
  issued and pass the fragment through).
- iOS `ContentsList`: same structure with `Section` headers and collapsed
  disclosure groups; the pencil/bookmark markers stay on the row whose
  chapter key matches. Accessibility label: "Chapter \(number), \(title)"
  for numbered rows, "\(title), heading" for headings.
- iOS `TOCSheet`: same outline, `List` with sections; current-position
  bookmark logic unchanged (`chapter.key == reader.chapter?.key`).
- The "chapters" count string in both detail headers ("N chapters ·")
  should count numbered body rows, not `meta.chapters.count`.
- `ReaderModel.bookPercent`: replace `chapter.index / chapters.count` with
  the chapter's position in `book.chapters` divided by `chapters.count`
  (`firstIndex(where: key)`), so filtered spines cannot exceed 100%.
  Adjust `ReaderModelTests` accordingly.
- The end-of-chapter note prompt (`finishedChapter`) is unchanged.

### Verify

- `make mac-test` (outline tests + existing).
- Simulator run with `MARGINS_IMPORT_FIXTURE` pointing at the Karamazov
  fixture: Contents tab shows "Front matter (2)", then PART I / Book I
  headings, chapter rows numbered 1… with "Chapter I. They Arrive At The
  Monastery" present under Book II, "Back matter (1)" at the end. Tapping
  a sub-file row lands at the right anchor.
- macOS: same walk in `make mac-run`.

---

## Phase 4 — Cleanup

1. **Real test target.** Both CI (Phase 0) and the local machine run full
   Xcode 26.6, so the reason for the `MarginsTests` runner executable is
   gone. Convert it to `.testTarget(name: "MarginsTests", dependencies:
   ["MarginsCore", "MarginsModel"])`, delete `Runner.swift` and the CLT
   `-F`/rpath `unsafeFlags` and the `cltDeveloperFrameworks` constants from
   `Package.swift`. `Makefile` `mac-test` becomes `swift test
   --package-path apple`. Verify locally that tests actually execute
   (`swift test … 2>&1 | grep -E "Test run with [0-9]+ tests"`); update
   `AGENTS.md` and `docs/architecture.md` to say full Xcode is required
   and drop the "swift test silently runs nothing" warnings.
2. `Package.swift` comment "MarginsIOS the iOS app (Phase 4 wires the real
   scenes…)": stale; the iOS app lives in `apple/ios`. Rewrite the header
   comment.
3. `docs/architecture.md`: replace the three-frontend framing with two,
   add a short "Chapter outline" subsection pointing at Phase 2's model
   and the `Matter`/`sections` invariants (or put those in `docs/storage.md`
   next to the existing `chapters` description and link).
4. `docs/storage.md`: document `matter`, `level`, `sections`, and
   `chapters_version: 2`.
5. `README.md` "Status": add the outline work; remove the "Roadmap detail"
   pointer to `docs/ios-plan.md` if that doc is marked historical.
6. `apple/Sources/MarginsModel/KeyHelp.swift` and README: any "both
   frontends" wording now means macOS + iOS.
7. Delete `docs/packaging-plan.md` Phases 3–4 bodies (Linux) outright,
   leaving the status line from Phase 1; keep Phases 1–2 (Homebrew,
   notarization) as deferred.
8. `.env.example`: it only documents `MARGINS_DATA_DIR` and
   `MARGINS_LIBRARY_ROOT`, which the core still reads. Drop the "on
   Linux" default-path remark from the comment; nothing else changes.

---

## Phase 5 — Optional: Swift-native core (decision gate, not scheduled)

Do **not** start this unless one of these becomes true:

- A feature needs the core to run inside Apple-only APIs (e.g.
  `NSFileCoordinator`/iCloud-aware writes from inside `notes.rs`, background
  processing on iOS) and the FFI boundary forces duplicate logic in Swift.
- The UniFFI toolchain blocks a Swift language upgrade (the generated code
  already needs `swiftLanguageMode(.v5)`).
- CI time for the four Rust targets plus xcframework assembly becomes the
  dominant cost.

If triggered, the shape is:

1. New SwiftPM target `MarginsKernel` (name avoids clashing with
   `MarginsCore`, which holds generated bindings) with `ZIPFoundation` for
   the archive, Foundation `XMLParser` for OPF/NCX/nav (works on iOS;
   `XMLDocument` is macOS-only), `Yams` for note frontmatter, `Codable`
   for every JSON file in `docs/storage.md`.
2. Port module by module in the order `epub_meta` → `library` → `notes` →
   `marks` → `compile` → `search` → `sync`, translating each Rust test to
   Swift Testing as the spec. Keep the Rust crate alive throughout.
3. A parity harness: `scripts/parity.sh` imports every EPUB in `fixtures/`
   through both cores into temp libraries and diffs the resulting trees
   byte-for-byte (`meta.json`, `notes/`, `_index.json`). Ship the Swift
   core only when the diff is empty across fixtures and a saved sample
   library.
4. Then delete `crates/`, `scripts/build-core.sh`, `build-xcframework.sh`,
   the `MarginsFFI` binary target, `margins_ffiFFI`, and the Rust steps in
   CI. `make core` / `make ios-core` go away; Rust leaves the toolchain.

Estimated size: the Rust core is ~5.5k lines including tests; expect a
similar Swift line count. Treat as its own multi-PR plan when the time
comes; this section exists only so the choice is recorded.

---

## Definition of done for the whole plan

- CI: one macOS job on `macos-26`, green, running Rust tests, Swift tests,
  the xcframework build, and the iOS simulator build.
- `git grep -i tauri` finds only `CHANGELOG.md` and historical-plan
  banners. No `package.json`, no `src/`, no `src-tauri/`.
- Importing the Karamazov fixture on macOS and iOS shows Cover and the
  Gutenberg header under a collapsed front-matter group, Parts and Books as
  headings, every "Chapter I" present, chapters numbered from 1, and
  FOOTNOTES under back matter. Existing notes and reading positions for
  previously imported books still open (keys unchanged,
  `chapters_version` upgraded to 2 on scan).
- `docs/storage.md` and `docs/architecture.md` describe the two-frontend
  system and the chapter outline fields.
