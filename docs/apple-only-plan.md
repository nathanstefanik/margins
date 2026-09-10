# Plan: Apple-only consolidation, Swift core, and chapter outline

Status: Phases 0–5 implemented (2026-09-10) · Phase 6 proposed ·
Audience: an AI agent implementing it.

End state: a macOS app and an iOS app, both SwiftUI, over one pure-Swift
core in a single SwiftPM package. No Rust, no UniFFI, no xcframework, no
Node, no Linux. `swift test` runs every test. The chapter list shows a
clean outline instead of the raw spine. Both apps read as native iOS 26 /
macOS 26 software: content under a lightweight, adaptive control layer.

| Phase | What | Why this position |
|-------|------|-------------------|
| 0 | Fix the macOS CI job (Swift tools 6.2 vs runner's 6.0.3) | Nothing can be verified in CI until this passes. Tiny diff. |
| 1 | Delete the Tauri/Linux frontend | Removes a third UI and the failing Linux job before anything else moves. |
| 2 | Port the core to Swift, delete the Rust crates, FFI plumbing, and Rust tests; simplify Makefile and CI | Done before the chapter work so the outline logic is written once, in Swift. |
| 3 | Chapter identification in the Swift core: matter classification, outline levels, multi-entry files | The user-facing bug. |
| 4 | Outline UI on macOS and iOS | Consumes Phase 3. |
| 5 | Docs and cleanup | Low risk, last. |
| 6 | iOS 26/27 design-system pass: content-under-controls layering, native navigation/tab structures, modern search placement, adaptive sizing, glass discipline | The apps were built with iOS 17 mental models; ship the design update once the domain shape has settled. |

Every phase is one PR (Phase 2 may be several, see its steps).
Commit-message prefixes per `AGENTS.md`.

If the chapter outline must ship before the port is finished, Phases 3–4
can be implemented on the Rust core first and then ported. That is double
work; this plan does not recommend it.

---

## Verified facts this plan rests on

- `apple/Package.swift` declares `swift-tools-version:6.2` and
  `.iOS(.v26)` since commit `5c68a36`. CI and release run the macOS job on
  `runs-on: macos-14` with `setup-xcode` `latest-stable`; that image tops
  out at Xcode 16.2 (SwiftPM 6.0.3). Every CI run since 2026-09-09 fails at
  `make mac-test` with the tools-version error. The Linux job fails
  separately on "Artifact storage quota has been hit".
- GitHub's macos-14 image is deprecated. `macos-26` (arm64, also
  `macos-latest`) ships Xcode 26.0.1–26.6, default 26.6. The local machine
  runs Xcode 26.6 (17F113), Swift 6.3.3, `xcode-select` on
  `/Applications/Xcode.app`.
- Rust workspace: `crates/margins-core` (config, library, epub_meta,
  notes, marks, compile, search, sync, models; 86 `#[test]`s plus one
  integration test on the Karamazov fixture), `crates/margins-ffi` (UniFFI
  0.29, one exported object `MarginsCore` with 21 methods, 15 records, 2
  enums), and `src-tauri`. External crates the core uses: `zip`,
  `quick-xml`, `regex`, `serde`/`serde_json`/`serde_yaml`, `chrono`,
  `uuid`, `sha2`, `hex`, `walkdir`, `dirs`, `thiserror`.
- Swift consumes the core only through `apple/Sources/MarginsCore/`
  (generated `Generated/margins_ffi.swift` plus the hand-written
  `CoreStore` actor). Every other Swift file imports `MarginsCore` for its
  record types and calls `CoreStore`. `apple/Sources/MarginsModel/
  Conformances.swift` adds `Identifiable` and `jumpTarget` to the records.
  The iOS Xcode project links only the `MarginsCore` and `MarginsModel`
  package products, never the xcframework directly.
- Build plumbing that exists solely for the FFI: `scripts/build-core.sh`,
  `scripts/build-xcframework.sh`, the `MarginsFFI` binaryTarget, the
  header-only `margins_ffiFFI` C target (`placeholder.c`), the
  `.gitignore` entries for generated bindings, `make core`/`make
  ios-core`, `UNIVERSAL=1` lipo in `build-core.sh`, and the Rust
  toolchain/cache steps in both workflows. `MarginsTests` is an executable
  target with CLT-specific `unsafeFlags` because `swift test` did not run
  on a CLT-only toolchain; both CI (after Phase 0) and local now have full
  Xcode.
- Chapter model: `ChapterMeta { key, index, title, href, fragment }`. One
  chapter per spine item. `key` = zero-padded spine position and anchors
  note filenames, `notes/_index.json`, frontmatter and `position.json`
  (`docs/storage.md`). **Keys must never change.** `library.rs` re-parses
  `chapters` from the retained `source.epub` on scan when
  `meta.chapters_version < CHAPTERS_VERSION` (currently 1), keeping keys.
- The TOC is indexed by target file and only the first entry per file
  survives (`epub_meta.rs::toc_by_path`). On
  `fixtures/dostoyevsky_the_karamazov_brothers.epub` (Gutenberg, NCX only,
  flat navMap, 120 navPoints of which 96 are `Chapter …`) the parser
  yields 100 chapters: `001 "Cover"` (literal quotes leaked from
  `<title>"Cover"</title>`), `002 The Brothers Karamazov` (Gutenberg
  header), `003 PART I` (the file also holds "Book I. The History Of A
  Family", lost), `009 Book II. An Unfortunate Gathering` (the file also
  holds "Chapter I. They Arrive At The Monastery", lost), `100 FOOTNOTES`.
  Only 84 of the 96 chapter labels survive.
- The user's Oxford World's Classics edition (not in `fixtures/`) is an
  EPUB3 with one spine file per front-matter page (Cover, half title,
  series page, copyright, acknowledgements, dedication, contents,
  introduction, translator's note, texts used, bibliography, chronology,
  principal characters, "From the Author", Part One, Book One), each
  listed as a numbered chapter before "1. Fyodor Pavlovich Karamazov".
- Spine parsing ignores `linear="no"`; `is_probably_content` drops any
  href containing `toc` or `nav` instead of using the manifest media type.
- `ReaderModel.bookPercent` divides `chapter.index` (spine position) by
  `book.chapters.count` (filtered list length).

---

## Decisions

- **Delete Tauri.** Its only purpose was Linux, which is out of scope. The
  macOS app is already native SwiftUI.
- **Port the core to Swift and delete the Rust crates.** One toolchain,
  no bindgen, no xcframework, `swift test` directly, strict concurrency
  without the `swiftLanguageMode(.v5)` escape hatch, and the ability to do
  coordinated file I/O for the iCloud library root inside the core rather
  than around it.
- **Storage format is frozen.** `docs/storage.md` is the contract. The
  Swift core must read every file the Rust core wrote and write files the
  Rust core would have read. A parity harness (Phase 2, step 6) proves it
  before the Rust code is deleted.
- **Drop `sync.rs`** (export/import of library trees). It is not exposed
  to Swift, has no UI, and the library is plain files that Finder, iCloud,
  or `rsync` copy already. Record in `CHANGELOG.md`.
- **Keep epub.js in WKWebView** for rendering and **SwiftPM** for the
  macOS build; keep the committed Xcode project for iOS.
- **Dependencies for the Swift core:** `ZIPFoundation` (reading EPUB
  archives and writing test fixtures) is the only third-party package.
  XML via Foundation `XMLParser` (SAX, works on iOS; `XMLDocument` is
  macOS-only). Hashing via `CryptoKit`. Regex via Swift `Regex`. YAML
  frontmatter via a small hand-written codec (the field set is fixed; a
  general YAML library would change formatting and add a dependency for
  nothing).

---

## Phase 0 — Unblock CI (Swift 6.2 toolchain)

Goal: the existing pipeline passes on a runner whose Xcode matches local.

1. `.github/workflows/ci.yml` job `macos` and `.github/workflows/
   release.yml` job `macos`: `runs-on: macos-26`; keep
   `maxim-lobanov/setup-xcode@v1` with `xcode-version: "26.6"` (matches
   local; never below 26.0 because of `.iOS(.v26)`). Rename the step
   "Select Xcode 26".
2. Do not touch the Linux job (Phase 1 deletes it) or the Rust steps
   (Phase 2 deletes them).

Watch-out: `Package.swift` links `MarginsTests` against the Command Line
Tools' `Testing.framework` via absolute `-F`/rpath flags. If that fails to
link on the new image, convert `MarginsTests` to a `.testTarget` in this
PR (Phase 2 step 1 describes it) instead of patching flags.

Verify: PR CI green through `make mac-test`, `make ios-core`, and the iOS
simulator `xcodebuild`. Locally `make mac-test` passes on Xcode 26.6.

---

## Phase 1 — Remove the Tauri/Linux frontend

Goal: two apps over one Rust core (for now). No Node, Vite, Tauri, Linux.

### Delete

- `src/`, `src-tauri/`, `index.html`, `vite.config.ts`, `tsconfig.json`,
  `package.json`, `package-lock.json`
- `scripts/test-keymap.mjs`, `scripts/test-reader-keymap.mjs` (Swift
  equivalents: `ReaderKeymapTests.swift`, `BridgeTests.swift`)
- `.github/workflows/ci.yml` job `linux`
- `.github/workflows/release.yml` job `linux`; in job `release`,
  `needs: [macos]`

### Edit

- `Cargo.toml`: `members = ["crates/margins-core", "crates/margins-ffi"]`;
  `cargo build --workspace` and commit the pruned `Cargo.lock`.
- `.gitignore`: drop `node_modules/`, `dist/`, `src-tauri/WixTools/`,
  `npm-debug.log*`.
- `.vscode/extensions.json`: `["rust-lang.rust-analyzer",
  "swiftlang.swift-vscode"]` (Phase 2 drops rust-analyzer).
- `scripts/bump-version.sh`: remove the `node -e` block and every
  reference to `package.json`, `package-lock.json`,
  `src-tauri/tauri.conf.json`; keep Cargo.toml (until Phase 2) and iOS
  `MARKETING_VERSION`.
- `release.yml` "Verify tag matches package version": read the version
  from `Cargo.toml` (`grep -m1 '^version = ' Cargo.toml | cut -d'"' -f2`).
  Phase 2 switches this to the iOS project's `MARKETING_VERSION`.
- epub.js vendoring: `package.json` was the version pin for the vendored
  `epub.min.js`/`jszip.min.js`. Add `scripts/vendor-reader.sh` that
  downloads pinned versions (`epubjs@0.3.93` from
  `https://unpkg.com/epubjs@0.3.93/dist/epub.min.js`, `jszip@3.10.1` from
  `https://unpkg.com/jszip@3.10.1/dist/jszip.min.js`), verifies hard-coded
  sha256 sums, and copies into `apple/Sources/MarginsModel/Resources/
  reader/`. Before committing, hash the currently vendored files and
  confirm they match those versions; if not, pin the versions they
  actually are. Add `make vendor-reader`.
- `README.md`: intro becomes "EPUB reader for macOS and iOS…"; delete
  `npm run tauri …` sections and the Tauri keybinding table; rewrite the
  first "Done" bullet under Status without Tauri.
- `AGENTS.md`: two frontends; drop `src-tauri/src/`, `src/`, `npm …`
  lines; "(covers core + tauri)" → "(core + ffi)"; delete the sentence
  about the footer keybar in `index.html`.
- `docs/architecture.md`: remove the Tauri branch of the diagram and the
  "Linux/Tauri app" paragraph; "mirrors the Tauri frontend's
  src/reader.ts" and "the Tauri app is never broken by Apple-platform
  work" go.
- `docs/storage.md` ~line 177: drop "and Tauri editor".
- `docs/packaging-plan.md`: under the status paragraph, state that
  Phases 3–4 (Linux .deb/.rpm/AUR) are dropped with Tauri.
- `docs/notes-page-plan.md`, `docs/ios-plan.md`: add a one-line
  "Historical" banner at the top pointing here. Do not rewrite bodies.
- Comments mentioning Tauri: `apple/Sources/MarginsModel/Resources/
  reader/reader.js:3`, `apple/Sources/MarginsModel/LibraryModel.swift:364`,
  `apple/Sources/MarginsModel/ReaderKeymap.swift:57` and `:140`. Reword.
- `CHANGELOG.md`: "Removed: Tauri/Linux frontend. Margins is macOS and
  iOS only."
- Rust core: leave it alone in this phase. `dotenvy` disappears with
  `src-tauri`. If clippy reports dead code in the core after the
  workspace shrinks, delete it (Phase 2 rewrites the core anyway).

### Verify

`cargo fmt --all -- --check`, `cargo clippy --locked --workspace
--all-targets -- -D warnings`, `cargo test --locked --workspace`,
`make mac-test`, `make ios-core`, CI simulator build. `git grep -i tauri`
returns only `CHANGELOG.md` and the historical banners. CI has one job.

---

## Phase 2 — Pure-Swift core; delete Rust and its plumbing

Goal: `apple/Sources/MarginsCore` is hand-written Swift with the same
module name, type names, and `CoreStore` API the apps already use, so
`MarginsModel`, `Margins`, `apple/ios`, and the existing Swift tests
compile with minimal edits. Rust, UniFFI, the xcframework, and the Rust
test suite are deleted at the end of the phase. The Rust core is the
reference implementation until step 6 passes; do not delete it earlier.

### Step 1 — Package layout and real test targets

Rewrite `apple/Package.swift`:

```swift
// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Margins",
    platforms: [.macOS(.v14), .iOS(.v26)],
    products: [
        .library(name: "MarginsCore", targets: ["MarginsCore"]),
        .library(name: "MarginsModel", targets: ["MarginsModel"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(name: "MarginsCore", dependencies: [
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ]),
        .target(name: "MarginsModel", dependencies: ["MarginsCore"],
                resources: [.copy("Resources/reader")]),
        .executableTarget(name: "Margins", dependencies: ["MarginsCore", "MarginsModel"]),
        .testTarget(name: "MarginsCoreTests", dependencies: ["MarginsCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "MarginsModelTests", dependencies: ["MarginsCore", "MarginsModel"]),
    ]
)
```

(0.9.20 is the current release as of 2026-09-10; `exact:`
keeps `Package.resolved` stable and lets CI use `--disable-automatic-
resolution`.)

- Move `apple/Sources/MarginsTests/*` to `apple/Tests/MarginsModelTests/`
  (SwiftPM's default test path), delete `Runner.swift`, drop the
  `Testing.__swiftPMEntryPoint()` call and every CLT `unsafeFlags`.
  Swift 6 language mode for all targets; no `.v5`.
- `Makefile` `mac-test` becomes `swift test --package-path apple`. Verify
  tests execute: `swift test --package-path apple 2>&1 | grep -E "Test run
  with [0-9]+ tests"` must show the count, not zero.
- The old `MarginsFFI` binaryTarget and `margins_ffiFFI` C target stay in
  place only until step 7; during steps 2–5 the package temporarily has
  both the generated bindings and the new Swift core. To avoid the type
  clash, develop the new core under `apple/Sources/MarginsCore/Swift/`
  behind a new module name `MarginsKernel` during the port, and rename it
  to `MarginsCore` in step 7 when the generated code is deleted. (Naming
  it `MarginsKernel` temporarily is simpler than juggling two modules
  named the same.)

### Step 2 — Models and errors (`Sources/MarginsKernel/Models.swift`)

Hand-write the types with the exact names the apps use:
`BookSummary`, `ChapterMeta`, `BookMeta`, `ReadingPosition`, `ChapterRef`,
`NoteFrontmatter`, `Mark`, `ChapterNote`, `NoteIndexEntry`,
`SearchHitKind`, `MatchRange`, `NoteSearchHit`, `ExportOptions`,
`CompiledChapter`, `CompiledNotes`, `CoreError`. Plus the on-disk-only
types from `models.rs`: `LibraryIndex`, `NotesIndex`, `NotesIndexEntry`.

Rules:

- `Codable`, `Sendable`, `Equatable`, `Hashable` where the Rust type
  derived them. Use `Int` where the FFI used `UInt32` (`ChapterMeta.index`,
  `chapter_count`, `clearNotes` return); fix the handful of call sites.
- Dates are `Date`, not RFC3339 strings (the FFI stringified them because
  UniFFI has no chrono). `Conformances.swift`'s date-parsing helpers, if
  any, go away. Check `MarkDisplay.swift`, `NotesPageView.swift`,
  `SearchResults.swift` for string-date handling and simplify.
- JSON coding keys are snake_case (`book_id`, `chapter_key`,
  `added_at`, …) exactly as in `docs/storage.md`; use explicit
  `CodingKeys`, not `keyDecodingStrategy`, so key names are visible.
- Every field the Rust side marked `#[serde(default)]` gets a
  hand-written `init(from:)` using `decodeIfPresent` with the same
  default. Every `skip_serializing_if = "Option::is_none"` field is
  `encodeIfPresent`. List them by reading `models.rs` top to bottom.
- Date encoding: encode RFC3339 UTC with fractional seconds (`ISO8601Date
  Formatter` with `.withInternetDateTime, .withFractionalSeconds`);
  decode both with and without fractions (chrono trims trailing zeros, so
  existing files contain 0, 3, 6, or 9 fractional digits). Marks use
  second precision in the `at=` attribute (`docs/storage.md`).
- `CoreError`: an `enum` with the same cases as the flat UniFFI error
  (`Config`, `Library`, `Notes`, `Epub`, `Io`, `Other`, each carrying a
  message) and `LocalizedError` so existing `error.localizedDescription`
  call sites keep working.
- Move `Conformances.swift`'s extensions (`Identifiable`, `jumpTarget`)
  into `Models.swift`; delete `Conformances.swift`.

### Step 3 — Port modules, one file each, tests first

Order and mapping (Rust → Swift file in `Sources/MarginsKernel/`):

| Rust | Swift | Notes |
|------|-------|-------|
| `config.rs` | `AppConfig.swift` | `MARGINS_DATA_DIR`/`MARGINS_LIBRARY_ROOT` env, `config.json` with `library_root`, platform default via `FileManager.urls(for: .applicationSupportDirectory)` + `margins`. |
| `epub_meta.rs` | `EpubParser.swift` | ZIPFoundation `Archive` reads; `XMLParser` delegates for OPF, NCX, nav; keep the regex-based fallbacks (`find_opf_path`, `parse_spine`) as `Regex` literals; `clean_text`, `decode_entities`, `percent_decode`, `resolve_relative`, `normalize_path` ported verbatim. Cover extraction included. |
| `marks.rs` | `Marks.swift` | Sentinel, `split_body`, `parse_section`, `serialize_items`, `canonical_block`, Crockford-base32 time-ordered ids. Byte-identical output is required. |
| `notes.rs` | `Notes.swift` + `Frontmatter.swift` | The YAML codec: emit keys in `NoteFrontmatter` field order; quote `chapter_key` (and any string that YAML would otherwise read as a number/bool/null) with single quotes exactly as serde_yaml does; omit `None` fields that Rust skipped; `null` where Rust wrote it. Capture three real note files written by the Rust core (plain, with marks, with `epub_cfi`) into `Tests/MarginsCoreTests/Fixtures/notes/` before deletion and use them as golden tests for both parse and re-emit. `slugify`, `count_words`, `upsert_index_entry`, rename-on-retitle behavior ported verbatim. |
| `library.rs` | `Library.swift` | Book id = `hash_file_with_progress` (read that function for the exact digest/truncation and replicate with `CryptoKit.SHA256`); staging dir `.{id}.importing-{uuid}` and commit-by-rename; `README.md` per book (`write_book_readme`); `list_books` scan with cover backfill and the `chapters_version` upgrade; `read_position`/`write_position`; `remove_book`; `read_epub_bytes`. Progress callback signature kept (`(UInt8, String)`), the apps use it for the import progress bar. |
| `compile.rs` | `Compile.swift` | `compile_book_notes`, `render_markdown`, `suggested_export_filename`. Markdown output byte-identical. |
| `search.rs` | `Search.swift` | The hand-rolled index: tokens, weights, phrase bonus, UTF-16 match ranges, mtime-based revalidation. Port as is; `SearchEngine` becomes a `final class` owned by `CoreStore`. |
| `sync.rs` | — | Dropped (see Decisions). |

For each module: first translate its `#[cfg(test)]` tests to Swift
Testing in `Tests/MarginsCoreTests/<Module>Tests.swift`, then port the
implementation until they pass. `test_fixtures.rs` becomes
`Tests/MarginsCoreTests/EpubFixtureBuilder.swift` (ZIPFoundation writer;
same `SampleToc`/`SampleCover` variants and `write_epub_with_titles`).
`tests/import_real_epub.rs` becomes a test over the Karamazov fixture
copied into `Tests/MarginsCoreTests/Fixtures/` (keep `fixtures/` at the
repo root too; the iOS `MARGINS_IMPORT_FIXTURE` flow reads it from there).

### Step 4 — `CoreStore` over the Swift core

Keep `public actor CoreStore` with its current method list and labels
(`listBooks`, `importEpub(atPath:)`, `getBook(id:)`, `removeBook(id:)`,
`clearNotes(bookId:)`, `readingPosition(bookId:)`,
`saveReadingPosition(bookId:position:)`, `readEpubBytesSync(id:)`,
`setLibraryRoot(path:)`, `getChapterNote(bookId:chapterKey:)`,
`notesIndex(bookId:)`, `compiledNotes(bookId:)`,
`renderNotesMarkdown(bookId:options:)`,
`saveChapterNote(bookId:chapter:body:kind:)`,
`appendMark(…)`, `updateMark(…)`, `deleteMark(…)`, `searchNotes(query:)`,
`dataDir()`, `libraryRoot()`). It now owns `AppConfig`, `Library`, and
`SearchEngine` directly. `readEpubBytesSync` stays `nonisolated` (a
stateless file read from the book dir; compute the path from an
immutable root captured at init, or make the root a `Mutex`-guarded
value).

Add an `importEpub(atPath:progress:)` overload if the iOS import UI
currently gets progress through the FFI; otherwise leave it.

### Step 5 — Coordinated file I/O (the native-integration payoff)

Introduce `FileStore` inside the core: every read/write of `meta.json`,
`position.json`, `notes/**`, and `_index.json` goes through it. On
iOS, when the library root is inside the ubiquity container,
`FileStore` wraps writes in `NSFileCoordinator.coordinate(writingItemAt:)`
and reads in `coordinate(readingItemAt:)`; elsewhere it is a plain
`FileManager` passthrough. `LibraryLocation.swift` keeps placeholder
materialization and conflict detection; the core stops needing the
"materialize before calling the core" dance for its own files. Scope
this step to writes only if reads prove slow; measure on the simulator
with an iCloud-signed-in account before widening.

### Step 6 — Parity harness (the deletion gate)

`scripts/parity.sh` (kept until the Rust code is deleted, then removed):

1. For each EPUB in `fixtures/` and a saved sample library at
   `fixtures/parity-library/` (create one by importing the Karamazov
   fixture with the Rust core and saving two notes with marks through it;
   commit it), run the same scripted sequence through both cores: import,
   list, get book, save note, append mark, update mark, delete mark,
   compile, render markdown with default and non-default options, search
   for three queries, clear notes, remove book. The Rust side runs through
   a tiny `cargo run --example parity` binary in `crates/margins-core/
   examples/`; the Swift side through a `swift run parity` executable
   target added temporarily to the package.
2. Normalize both output trees: replace RFC3339 timestamps with `<TS>`
   and mark ids with `<ID>` (both are time-derived), then:
   - Markdown (`notes/**/*.md`, rendered exports, per-book `README.md`):
     byte-identical after normalization.
   - JSON (`meta.json`, `_index.json`, `index.json`, `position.json`):
     parse both and compare values (formatting may differ between
     `serde_json` pretty output and `JSONEncoder`; set
     `.prettyPrinted, .withoutEscapingSlashes` on the encoder anyway so
     files stay diff-friendly for humans and agents).
   - Search hits: identical ordering, kinds, scores (to 1e-9), and ranges.
3. The Swift core must also open the Rust-written `parity-library` as-is
   and produce identical results to the Rust core on it (read-path
   compatibility with real files, not just self-written ones).

The phase does not proceed to step 7 until the harness is clean on the
fixture, the sample library, and at least one additional real EPUB3 (an
Oxford-style or Standard Ebooks title with a nav document and landmarks;
add it to `fixtures/` if its license permits, otherwise keep it local and
record the title in the PR).

### Step 7 — Delete Rust and plumbing; rename; simplify

- Delete `crates/`, `Cargo.toml`, `Cargo.lock`, `scripts/build-core.sh`,
  `scripts/build-xcframework.sh`, `apple/Sources/margins_ffiFFI/`,
  `apple/Sources/MarginsCore/Generated/` and the old `CoreStore.swift`,
  the `MarginsFFI` binaryTarget, `build/MarginsFFI.xcframework` handling
  in `.gitignore` (`apple/Sources/margins_ffiFFI/include/`,
  `apple/Sources/MarginsCore/Generated/`), `scripts/parity.sh` and both
  parity executables, `fixtures/parity-library/` (or keep it as a
  read-compatibility test fixture under `Tests/MarginsCoreTests/
  Fixtures/legacy-library/`; recommended: keep).
- Rename `MarginsKernel` → `MarginsCore` (module, directory, product).
- `Makefile` becomes:

  ```make
  .PHONY: test build app app-universal run ios-build ios-archive ios-bump bump vendor-reader

  test:            ; swift test --package-path apple
  build:           ; swift build --package-path apple
  app:             ; ./scripts/make-app.sh
  app-universal:   ; UNIVERSAL=1 ./scripts/make-app.sh
  run: app         ; open build/Margins.app
  ios-build:       ; xcodebuild -project apple/ios/Margins.xcodeproj -scheme Margins \
                       -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
  ios-archive:     ; xcodebuild -project apple/ios/Margins.xcodeproj -scheme Margins \
                       -configuration Release -destination 'generic/platform=iOS' \
                       -archivePath build/Margins.xcarchive -allowProvisioningUpdates archive
  ios-bump:        ; ./scripts/bump-build.sh
  bump:            ; ./scripts/bump-version.sh $(VERSION)
  vendor-reader:   ; ./scripts/vendor-reader.sh
  ```

  Drop `core`, `ios-core`, `mac-*` prefixes. `scripts/make-app.sh`
  already builds with `swift build -c release --package-path apple` and
  passes `--arch arm64 --arch x86_64` under `UNIVERSAL=1`; it only needs
  its version lookup moved off `Cargo.toml` (line 47) and any xcframework
  assumptions removed. The iOS simulator build no longer
  needs `ARCHS=arm64` (that pin existed because Rust had no
  `x86_64-apple-ios-sim`); remove it from CI and confirm the generic
  simulator destination builds both slices.
- `scripts/bump-version.sh`: the single version source becomes the iOS
  project's `MARKETING_VERSION`; `scripts/make-app.sh` reads the macOS
  bundle version from the same place (or from a one-line
  `apple/VERSION` file that both read; pick the file, it is simpler to
  grep). `release.yml`'s tag check reads it.
- `.github/workflows/ci.yml`, single job on `macos-26`:
  checkout → select Xcode 26.6 → `swift test --package-path apple` →
  `make ios-build`. No Rust setup, no cache action for cargo (add
  `actions/cache` for `apple/.build` keyed on `Package.resolved` if the
  job is slow). `release.yml` macOS job: `make app-universal`, DMG, upload.
- `.vscode/extensions.json`: `["swiftlang.swift-vscode"]`.
- `.gitignore`: remove `target/`; keep `apple/.build/`, `/build/`.
- `AGENTS.md`, `docs/architecture.md`: rewrite the project map and
  commands (Phase 5 owns the prose; do the minimum here so the docs are
  not wrong on `main`).
- `CHANGELOG.md`: "Changed: core rewritten in Swift; storage format
  unchanged. Removed: Rust core, UniFFI bridge, library sync
  export/import."

### Verify

- `swift test --package-path apple` runs every core and model test
  (expect roughly 90 core tests translated plus the existing ~80 model
  tests; the count is printed).
- `make app`, `make run`: import the Karamazov fixture, write a note, add a
  mark, open the compiled notes page, search, export markdown. Open the
  resulting `books/<id>/notes/chapters/*.md` and confirm it matches the
  format in `docs/storage.md`.
- Point the app at a library the Rust core wrote (`MARGINS_LIBRARY_ROOT`
  to a copy of the old data dir): every book lists, notes open, positions
  resume.
- iOS simulator: `MARGINS_IMPORT_FIXTURE` flow, note capture, marks,
  search. iCloud root: create a note on the simulator, confirm the file
  appears in the container without a conflict copy.
- CI: one job, green, no Rust.

---

## Phase 3 — Chapter identification in the Swift core

Goal: the core describes a book's structure well enough for a UI to show a
clean outline: front matter grouped, parts/books as headings, body
chapters numbered from one, back matter grouped, and no TOC entries lost
when a file contains several. Keys, note files, and reading positions are
untouched.

### Data model (`Sources/MarginsCore/Models.swift`)

```swift
/// Where a spine item sits in the book's structure.
public enum Matter: String, Codable, Sendable { case cover, front, body, back }

/// One table-of-contents entry that starts inside a spine item.
public struct ChapterSection: Codable, Sendable, Equatable, Hashable {
    public var title: String
    /// Anchor id inside the chapter's `href`; nil = top of file.
    public var fragment: String?
    /// Outline depth: 0 = part/volume, 1 = book (or chapter when the book
    /// has no parts), … Leaves are the deepest level present.
    public var level: Int
}

public struct ChapterMeta {
    // existing: key, index, title, href, fragment
    public var matter: Matter            // decoded default .body
    /// Outline depth of `title` (== sections[0].level when non-empty; else 0).
    public var level: Int                // decoded default 0
    /// Every TOC entry that targets this file, in reading order. Empty when
    /// the TOC has no entry for the file. When non-empty,
    /// sections[0].title == title and sections[0].fragment == fragment.
    public var sections: [ChapterSection] // decoded default []
}
```

Decode with `decodeIfPresent` defaults so `meta.json` files from older
versions load; encode `fragment` only when present (existing rule).
Bump `Library.chaptersVersion` to `2`; the scan upgrade re-parses
`source.epub` and rewrites `chapters` without moving keys. Extend the
translated `scan_upgrades_legacy_chapter_metadata_without_moving_keys`
test to assert `matter`/`sections` are populated after upgrade. Document
the invariants in `docs/storage.md`:

- `key`, `index`, `href` unchanged in meaning. `title`/`fragment` remain
  the first TOC entry for the file, so note frontmatter and search hits
  keep matching.
- A file holding "Book II" and "Chapter I" has two sections; the UI shows
  both rows, both open the same chapter key at different fragments, and
  the chapter note for that key is shared. Sub-file chapters do not get
  their own note file because that would change the key scheme.

### Spine and content filtering (`EpubParser.swift`)

1. Parse `<itemref idref linear>` with `XMLParser` (not regex); skip
   `linear="no"` items when building candidates. `index` stays the raw
   spine position so keys are stable.
2. Replace the href-substring content filter with a manifest-driven
   check: keep an item when `media-type` is `application/xhtml+xml` or
   `text/html` (case-insensitive) and `properties` does not contain
   `nav`; fall back to the extension (`.xhtml`, `.html`, `.htm`, `.xml`)
   only when `media-type` is absent. Test: a chapter named
   `navarre.xhtml` is kept; an `.ncx` in the spine and a
   `properties="nav"` document are dropped.
3. `cleanText`: after collapsing whitespace, strip one pair of surrounding
   straight or curly double quotes (`"Cover"` → `Cover`). Test it.

### TOC parsing keeps nesting and all entries per file

- `TocEntry` gains `level`. NCX: `stack.count - 1` at `navPoint` open.
  Nav document: track `<ol>` depth inside the chosen `<nav>`; today's
  parser ignores nesting.
- Replace first-entry-per-file with `[path: [TocEntry]]` in reading order.
  `ChapterCandidate` carries the whole array.
- When the TOC is flat (every entry level 0) infer levels from labels,
  case-insensitive on the trimmed label:
  - `^(part|volume)\b` → 0
  - `^book\b` → 1 if any part/volume label exists in the book, else 0
  - everything else → `max container level seen so far + 1`
  Apply inference only when the TOC has no nesting at all; a nested TOC is
  authoritative.

### Matter classification

Signals in priority order; the first that decides a file wins.

1. **Landmarks / guide** (book-level):
   - EPUB3 `<nav epub:type="landmarks">` anchors: `bodymatter` → that file
     starts Body; `backmatter` → starts Back; `cover` → Cover;
     `titlepage`, `frontmatter`, `toc`, `copyright-page` → Front.
   - EPUB2 OPF `<guide><reference type= href=>`: `text` starts Body;
     `cover` → Cover; `title-page`, `toc`, `copyright-page`,
     `acknowledgements`, `dedication`, `epigraph`, `foreword`, `preface`,
     `loi`, `lot` → Front; `bibliography`, `glossary`, `index`, `notes`,
     `colophon` → Back.
   - Resolve hrefs like TOC targets (relative to the declaring document,
     percent-decoded, normalized).
2. **Per-document `epub:type`**: scan the first 8 KB for `epub:type="…"`
   on `<body>` or the first `<section>`. `cover` → Cover; `frontmatter`,
   `titlepage`, `halftitlepage`, `copyright-page`, `toc`, `dedication`,
   `acknowledgments`, `epigraph`, `foreword`, `preface`, `introduction`,
   `landmarks`, `loi`, `lot` → Front; `bodymatter`, `part`, `chapter`,
   `volume`, `prologue`, `epilogue` → Body; `backmatter`, `afterword`,
   `appendix`, `bibliography`, `colophon`, `endnotes`, `footnotes`,
   `glossary`, `index`, `notes` → Back. Values are space-separated; a
   partition value (`frontmatter`/`bodymatter`/`backmatter`) decides over
   a specific value, except `cover` always yields Cover.
3. **Cover by shape**: visible text under 40 characters and an `<img>` or
   `<svg>` present → Cover (catches Gutenberg's `wrap0000.html`).
4. **Title heuristics** on the resolved title, trimmed, case-insensitive,
   whole string or prefix followed by a non-letter. Keep the lists as
   `static let` arrays with a unit test each.
   - Front: `cover`, `half title`, `halftitle`, `half-title`, `title
     page`, `series page`, `copyright`, `acknowledgments`,
     `acknowledgements`, `dedication`, `contents`, `table of contents`,
     `epigraph`, `about the author`, `also by`, `by the same author`, `a
     note on the`, `note on the`, `translator's note`, `translators'
     note`, `texts used`, `select bibliography`, `further reading`,
     `chronology`, `a chronology`, `principal characters`, `list of`,
     `introduction`, `preface`, `foreword`, `from the author`, `author's
     note`; plus a title equal to the book title, and an all-caps title of
     ≤ 4 words appearing before the first Body file (series names such as
     "OXFORD WORLD'S CLASSICS").
   - Back: `notes`, `endnotes`, `footnotes`, `explanatory notes`,
     `glossary`, `index`, `appendix`, `afterword`, `bibliography`,
     `colophon`, `about the publisher`, `other books by`, `also
     available`.
   - Front titles apply only to the run of files before the first Body
     file is established; Back titles only to the run after the last Body
     file. "Introduction" after chapter 3 stays Body. "Prologue" is never
     Front by title.
5. **Position fallback**: with no `bodymatter`/`text` signal, Body starts
   at the first file not classified Cover/Front by 2–4; Back is the
   maximal suffix classified Back by 2 or 4; the rest is Body.

Sanity rules: zero Body files → everything non-Cover becomes Body. A file
with a section label matching `^(part|book|volume|chapter)\b` or starting
with a number or Roman numeral is Body regardless of title heuristics.

### Tests (`Tests/MarginsCoreTests/EpubParserTests.swift`)

Extend `EpubFixtureBuilder` so a test can declare per spine item:
filename, `<title>`, heading, body text, optional `epub:type`, `linear`;
per book: NCX or nav TOC with nesting, optional `<guide>`, optional
landmarks nav. Then:

- `oxfordStyleFrontMatterIsClassified`: the 16 front-matter titles from
  the user's report, then "Part One" and "Book One: The Story of a
  Family" (same file), chapters "1. Fyodor Pavlovich Karamazov"…"3. …",
  then "Explanatory Notes", "Index". Assert matter per key, levels (Part
  0, Book 1, chapters 2), first Body key is the Part file.
- `landmarksBodymatterWinsOverTitleHeuristics`: a file titled
  "Introduction" flagged `bodymatter` is Body.
- `guideTextReferenceStartsBody`.
- `linearNoItemsAreSkippedWithoutMovingKeys`.
- `navNestingSetsLevels`, `ncxNestingSetsLevels`,
  `flatNcxLevelsAreInferredFromLabels`.
- `everyTocEntryInAFileBecomesASection`.
- `coverWrapperIsDetectedByShape`, `titleQuotesAreStripped`.
- `manifestMediaTypeDrivesContentFilter`.
- `karamazovFixtureOutline`: key `001` is `.cover` titled `Cover`; `002`
  is `.front`; `003` has sections `["PART I" (0), "Book I. The History Of
  A Family" (1)]` and is `.body`; `009` has sections `["Book II. An
  Unfortunate Gathering" (1), "Chapter I. They Arrive At The Monastery"
  (2)]`; `100 FOOTNOTES` is `.back`; the number of Body sections whose
  title starts with `Chapter ` is 96; no title starts with "The Project
  Gutenberg eBook".
- Library upgrade test: `chapters_version == 2` after scan, `matter`
  populated, note files untouched.

### Verify

`swift test`; `make run`, import the fixture, inspect `meta.json`
(`chapters_version: 2`, `sections` present).

---

## Phase 4 — Outline UI on macOS and iOS

Goal: replace the flat numbered spine list in
`apple/Sources/Margins/BookDetailView.swift` (`chaptersList`),
`apple/ios/Margins/BookDetailView.swift` (`ContentsList`), and
`apple/ios/Margins/Reader/ReaderScene.swift` (`TOCSheet`) with one shared
outline.

### Shared model (`Sources/MarginsModel/ContentsOutline.swift`, new)

```swift
public struct OutlineRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case heading(level: Int), chapter(number: Int), matter }
    public let id: String            // "\(chapter.key)#\(sectionIndex)"
    public let chapter: ChapterMeta
    public let section: ChapterSection?
    public let title: String
    public let kind: Kind
    public var jumpFragment: String? { section?.fragment ?? chapter.fragment }
}

public struct ContentsOutline: Equatable, Sendable {
    public let front: [OutlineRow]   // Cover + Front, spine order
    public let body: [OutlineRow]    // headings and numbered chapters
    public let back: [OutlineRow]
    public static func build(from chapters: [ChapterMeta]) -> ContentsOutline
}
```

Rules: every `ChapterSection` becomes a row; a chapter with no sections
becomes one row with its own title. Body rows are `.heading(level:)` when
a later row in the same chapter or the next body row has a greater level,
else `.chapter(number:)` numbered from 1 across the body in reading
order. Front/back rows are `.matter`. If every body row would be a
heading, number all body rows instead.

Tests (`Tests/MarginsModelTests/ContentsOutlineTests.swift`):
Gutenberg-shaped input, Oxford-shaped input, no TOC (every row numbered),
body only, degenerate all-headings.

### Views

- macOS `chaptersList`: `outline.front` inside a collapsed
  `DisclosureGroup("Front matter (n)")`; body headings as small-caps
  secondary text without a number, chapters with `number`; `outline.back`
  in a collapsed "Back matter (n)". Clicking a row opens the reader at the
  chapter and jumps to `jumpFragment` (`ReaderController` already issues
  `href#fragment` via `readerDisplay`; pass the fragment through).
- iOS `ContentsList`: same structure with `Section` headers and collapsed
  groups; pencil/bookmark markers stay on the row whose key matches.
  Accessibility: "Chapter \(number), \(title)" for numbered rows,
  "\(title), heading" for headings.
- iOS `TOCSheet`: same outline in a sectioned `List`; current-position
  bookmark unchanged.
- The "N chapters ·" strings in both detail headers count numbered body
  rows, not `chapters.count`.
- `ReaderModel.bookPercent`: use the chapter's position in
  `book.chapters` (`firstIndex(where:)`) over `chapters.count` instead of
  `chapter.index`, so filtered spines cannot exceed 100. Adjust
  `ReaderModelTests`.

### Verify

`swift test`; simulator run with `MARGINS_IMPORT_FIXTURE` on the
Karamazov fixture: "Front matter (2)", PART I / Book I headings, chapters
numbered from 1, "Chapter I. They Arrive At The Monastery" present under
Book II, "Back matter (1)"; tapping a sub-file row lands at its anchor.
Same walk on macOS via `make run`.

---

## Phase 5 — Docs and cleanup

1. `docs/architecture.md`: rewrite for the two-app, Swift-core shape:
   diagram, module list (`AppConfig`, `EpubParser`, `Library`, `Notes`,
   `Marks`, `Compile`, `Search`, `FileStore`, `CoreStore`), reader
   rendering and scheme-handler sections unchanged, a "Chapter outline"
   subsection linking to `docs/storage.md`.
2. `docs/storage.md`: document `matter`, `level`, `sections`,
   `chapters_version: 2`; the "Titles resolve from…" paragraph gains the
   classification summary; remove the Rust-specific wording
   (`serde`, crate names) where it leaks in.
3. `AGENTS.md`: project map (`apple/Sources/MarginsCore` is the domain
   core; `Tests/`), commands (`make test`, `make build`, `make app`, `make
   run`, `make ios-build`, `make ios-archive`, `make ios-bump`, `make
   bump`, `make vendor-reader`), remove every Rust/CLT/`swift test runs
   nothing` note, "When changing the FFI surface, run make core" goes.
4. `README.md`: intro, build section, Status ("Done" bullets for the
   Swift core and the outline), remove the roadmap pointer to the
   historical `docs/ios-plan.md` or label it historical.
5. `docs/packaging-plan.md`: delete the Linux phases; keep Homebrew and
   notarization as deferred.
6. `apple/Sources/MarginsModel/KeyHelp.swift` and README: "both
   frontends" means macOS + iOS.
7. `.env.example`: drop the "on Linux" default-path remark; the two
   variables stay.
8. `git grep -n -i "rust\|cargo\|uniffi\|xcframework\|tauri"` outside
   `CHANGELOG.md` and the historical banners must return nothing.

---

## Phase 6 — iOS 26/27 design-system pass

Goal: the iOS app stops reading like "screens containing controls" and
starts reading like iOS 26/27: **immersive content under a lightweight,
adaptive control layer**. No new features, no storage change — this is a
UI refactor and a set of rules the later work inherits. The app already
targets `.iOS(.v26)` and is SwiftUI, so the Liquid Glass APIs are
available; the macOS app keeps its zathura-style minimalism and does not
adopt iOS glass.

Concrete references are to today's files; re-grep before acting, they
move. API names below are the intended ones (WWDC25-era SwiftUI) —
confirm exact spelling against the installed iOS 26 SDK before use.

The five highest-leverage items, in order: **content-vs-control layering,
edge-to-edge, native navigation/tab structures, adaptive sizing instead of
orientation, and search placement.** Glass effects come last, not first.

### Step 1 — Fix the content/control two-layer model

Apple's current framing is a content layer underneath a UI/navigation
layer, and glass belongs to the upper layer only.

- Inventory every material/background in `apple/ios/Margins/`:
  `git grep -n "thinMaterial\|regularMaterial\|ultraThin\|Color\.\|\.background(" apple/ios`
- `LibraryScene.swift` download overlay: the full-screen
  `Color.black.opacity(0.2)` scrim plus a `.thinMaterial` box is the
  iOS 17 "modal card" pattern. Replace it with a single glass control
  (`ProgressView` in a `.glassEffect(..., in: .capsule)` over a
  content-dimming layer) — the content behind stays content, not glass.
- `ReaderScene.swift` flash badge and end-of-chapter prompt
  (`.thinMaterial` + `.rect(cornerRadius: 12)`) become glass capsules;
  the reader's custom header buttons (`chromeButton`) sit in a
  `GlassEffectContainer` so related controls can merge and morph.
- Rule to encode in `docs/architecture.md` and `AGENTS.md`: **glass on
  controls and navigation only; content uses plain fills, materials are
  reserved for the paper.** Do not glass cards, list rows, or sheets, and
  never nest glass inside glass.

### Step 2 — Edge-to-edge content and floating bars

- Content must scroll under the navigation bar and tab bar rather than
  below opaque boxes. Audit the library grid (`LibraryScene.bookGrid`) and
  book detail (`BookDetailView.detail`): both are `ScrollView`s inside
  `NavigationStack`; use the iOS 26 scroll-edge effect
  (`scrollEdgeEffectStyle`) instead of relying on an opaque bar, and stop
  adding top padding to dodge the bar.
- The reader is already full-bleed and floats its chrome; keep that, but
  make the chrome glass (Step 1) so it reads as a layer above the page
  instead of a header over it. The hardcoded paper
  `Color(red: 244/255, ...)` in `ReaderScene.swift` is the content layer —
  keep it, and let it run under the status bar and home indicator.
- Remove any explicit opaque `systemBackground`/separator that boxes off a
  toolbar region. There are none today; do not add any.

### Step 3 — Native navigation and tab anatomy

One information architecture — `Library → Book → Reader`, plus global
notes search — that adapts across canvases (principle 13), instead of
hand-built per-device navigation:

- iPhone (compact): a floating `TabView` with a **Library** tab and a
  **Search** tab; book detail and the reader are stack pushes. Set
  `tabBarMinimizeBehavior` so the bar minimizes on scroll.
- iPad (regular): the same `TabView` with `.tabViewStyle(.sidebarAdaptable)`
  so it becomes a sidebar automatically; keep the
  `NavigationSplitView` column widths.
- Mac: the existing `NavigationSplitView` (sidebar → list → detail) is the
  wide-canvas form of the same anatomy; do not diverge further.
- Replace `LibraryScene`'s single `NavigationSplitView` +
  `.searchable(placement: .navigationBarDrawer(displayMode: .always))`
  with the size-class-driven structure above. Read size from
  `@Environment(\.horizontalSizeClass)`, never from orientation.
- Search's home (principle 6): **global notes search is the dedicated
  Search tab** on iPhone (scope = the whole library, shown as a full
  screen); on iPad/Mac it lives in the sidebar/toolbar. Contextual search
  belongs inline over the content it filters (a future in-reader search
  goes in the reader, not here). Keep the existing debounce in
  `runSearch()`; only the placement changes.

### Step 4 — Adaptive sizing, not device orientation

- Delete every orientation assumption. Audit with:
  `git grep -n "interfaceOrientation\|UIDevice.current.orientation\|UIScreen.main" apple/ios`.
  Today none exist; a regression test/CI grep keeps it that way.
- Layout keys off `horizontalSizeClass`/`verticalSizeClass`, `ViewThatFits`,
  `containerRelativeFrame`, and space actually available. The book detail's
  fixed 110×165 cover block should yield on constrained height (landscape
  phone, iPad Split View, iPhone Mirroring), letting the outline take the
  space.
- The reader's tap thirds (`ReaderScene.handleTap`) use the webview's own
  width — already space-based, leave it.
- Verify on iPhone Mirroring and an iPad resizable window, not just a
  portrait simulator.

### Step 5 — Toolbars as priority systems, and control continuity

- Rank each screen's actions: critical → frequent → contextual → overflow.
  Book detail keeps "Continue reading" as the primary content action and
  pushes delete/export into an overflow `Menu`, so space-constrained
  toolbars never crowd; use `ToolbarItem(placement:)` and visibility
  priority where the SDK supports it.
- The reader's resting screen has no bar, and its revealed chrome is three
  controls (back, new note, menu) with the rest inside the menu. Keep that
  shape; document the ranking in a comment so it does not grow.
- Motion explains structure (principle 12): the grid cover → reader should
  grow from the tapped cover via `matchedTransitionSource` on
  `BookGridCell`'s cover and `navigationTransition(.zoom(sourceID:in:))`
  on `ReaderScene`. The end-of-chapter prompt and flash should transition
  from the control that spawned them (scale/origin), not a bare fade.
  Gate non-essential motion behind `accessibilityReduceMotion`.

### Step 6 — Concentric geometry and restrained color

- Normalize corner radii. Grep:
  `git grep -n "cornerRadius\|Capsule()\|\.rect(" apple/ios`.
  Today covers are 8pt, overlays 12pt, sheets 17pt, badges capsules. Use
  container-concentric shapes (`containerShape`/`ConcentricRectangle` on
  iOS 26) so a control's radius follows its container, and standard
  capsule/rounded-rect shapes otherwise. Mac can keep its tighter scale.
- Color communicates meaning only: selected state, current position,
  has-notes, primary action, status. Audit `.tint`/`.foregroundStyle(.tint)`;
  clear decorative uses. Glass controls should read neutral until acted on.

### Step 7 — Prefer system controls; keep accessibility

- Use system `TabView`, `NavigationSplitView`, `List`, `Menu`, `Picker`,
  `ShareLink`, `ContentUnavailableView`, `.searchable`, and glass button
  styles. These absorb Liquid Glass behavior, adaptive geometry, and
  future styling for free (principle 14). Inventory custom controls and
  replace any that only exist because an older SDK lacked the API; keep the
  reader's custom chrome and hit targets, which are deliberate.
- Every custom control keeps `accessibilityLabel`/`Value`/`Hint`, a ≥44pt
  target, and a non-gesture path (the reader already exposes
  `accessibilityAction`s). Verify with VoiceOver and Switch Control and at
  the largest Dynamic Type sizes (principle 15).

### Step 8 — Documents and rules

- `docs/architecture.md`: expand "The iOS app" with the size-class
  navigation anatomy, the search placement rule, and the content/control
  layering.
- `AGENTS.md` conventions: "iOS work follows the iOS 26 content-under-glass
  layout: system controls first, glass only on the control plane, layout by
  size class — never `interfaceOrientation`."

### Verify

- iOS 26 simulator, light and dark: iPhone (portrait + landscape), iPad
  (portrait, landscape, Split View / Slide Over), iPhone Mirroring.
- Import the Karamazov fixture (`MARGINS_IMPORT_FIXTURE`): search tab
  scope, minimize-on-scroll tab bar, cover → reader zoom, glass chrome
  over a full-bleed page, no glass-on-glass.
- VoiceOver traversal of library, book detail, reader chrome, and sheets;
  largest Dynamic Type; Reduce Motion on.
- macOS `make run` unchanged in behavior and IA.
- `swift test --package-path apple` green; the outline tests are untouched.
- Screenshots in the PR for each canvas and appearance.

---

## Definition of done for the whole plan

- One CI job on `macos-26`, green: `swift test --package-path apple` and
  the iOS simulator build. No Rust, Node, or Linux steps.
- Repository contains no `crates/`, `Cargo.*`, `src/`, `src-tauri/`,
  `package.json`, generated bindings, or xcframework scripts.
- `Makefile` has only the targets listed in Phase 2 step 7.
- A library written by the Rust core opens unchanged in the Swift core;
  files the Swift core writes match `docs/storage.md`.
- Importing the Karamazov fixture on macOS and iOS shows Cover and the
  Gutenberg header under a collapsed front-matter group, Parts and Books
  as headings, every "Chapter I" present, chapters numbered from 1, and
  FOOTNOTES under back matter. Existing notes and reading positions for
  previously imported books still open (keys unchanged,
  `chapters_version` upgraded to 2 on scan).
- `docs/storage.md`, `docs/architecture.md`, `AGENTS.md`, and `README.md`
  describe the two-app, Swift-core system and the outline fields.
- The iOS app reads as iOS 26/27 software (Phase 6): edge-to-edge content
  under a glass control layer, semantic tab/sidebar navigation with
  dedicated search, size-class layout with no orientation checks, and
  system controls wherever possible.
