# Development plan: iOS app

Status: Phase 1–5 implemented · Phases 6–7 pending · Owner: TBD · Last updated: 2026-09-05

## Goal

An iOS/iPadOS app for Margins that mirrors the macOS app's information
architecture (library → book → reader, notes everywhere) with a
touch-first note-taking experience, over the same Rust core and the same
plain-file storage. Quick marks anchored to CFI ranges live inside the
existing per-chapter markdown note; nothing else about storage changes.

The macOS app and the Tauri app keep working and their tests stay green at
every commit.

## Non-goals

- No database, no network layer, no new heavyweight dependencies
- No shared `ContentView` / forced-common view hierarchies — iOS gets its own
  scenes; only genuinely shared pieces (model layer, reader glue, compiled-notes
  rendering helpers) move to shared targets
- No PDF/HTML export, no sync UI on iOS (sync export/import stays unexposed)
- No App Store submission work — simulator + ad-hoc device installs only
- No gamification; chrome stays zathura-minimal

## Answers locked in up front

### Environment prerequisite (stated plainly)

Full Xcode **is installed** — Xcode 26.6 (build 17F113) at
`/Applications/Xcode.app`, carrying `iPhoneOS26.5.sdk` and
`iPhoneSimulator26.5.sdk`. It is not yet *usable*, for two reasons that both
need an admin password (verified 2026-09-05):

1. `xcode-select -p` still returns `/Library/Developer/CommandLineTools`.
2. The Xcode license has not been accepted, so every `xcrun`/`xcodebuild`
   call — including `xcrun --sdk iphoneos --show-sdk-path`, which `cc-rs`
   needs — fails with "You have not agreed to the Xcode license agreements."
   This gate fires even with `DEVELOPER_DIR` set, so it is not a side effect
   of item 1.

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

**No iOS simulator runtime is installed** — `/Library/Developer/CoreSimulator/`
`Profiles/Runtimes/` does not exist and Xcode 26.6 bundles none. Phases 4–7
therefore need a third step, a multi-gigabyte download gated behind the two
commands above (no sudo itself):

```bash
xcodebuild -downloadPlatform iOS
```

Phases 1–3 (core, FFI, marks) need none of this: verified green on the
CLT-only toolchain at commit `9f30215` on 2026-09-05 — `make core`,
`make mac-test` (73 tests / 12 suites), and `npm run build` all pass. The
claim is pinned to that commit deliberately; it says the CLT path works, not
that any given working tree is green.

Rust iOS targets need adding once, up front. Note that **only two of the
three are installable**: Rust 1.96 stable does not ship `x86_64-apple-ios-sim`
(`rustup target add` errors out), which is why the simulator slice is
arm64-only — see implementation note 3 under Phase 1.

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

### iOS deployment target: `.iOS(.v17)`

Not a judgment call once the code is read: `MarginsModel` already uses the
`@Observable` macro (`LibraryModel.swift:12`, `ReaderModel.swift:20`,
`ReaderPreferences.swift:12`, `SearchController.swift:17`), which requires iOS
17. iOS 17 also brings `.onKeyPress` for the iPad hardware-keyboard path the
iOS prompt asks for, and pairs with the existing `.macOS(.v14)` floor (same
Xcode 15 SDK generation). No shared model code needs anything newer.

### Mark syntax (exact)

Chapter note files gain an optional marks section after the long-form body,
separated by a sentinel comment:

```markdown
---
book_id: a1b2c3
chapter_key: '003'
...existing frontmatter...
---

The long-form, contemplative chapter note. Unchanged semantics.

<!-- margins:marks -->

<!-- margins:mark id=b01j8q3k2 cfi="epubcfi(/6/14!/4/2/10,/1:0,/1:42)" at=2026-09-05T14:02:11Z percent=38.2 -->
> optional quoted selection from the book

The quick thought.

<!-- margins:mark id=b01j8qk9x cfi="epubcfi(/6/14!/4/2/24,/1:7,/1:19)" at=2026-09-05T14:07:31Z percent=51.0 -->
> another selection

(highlight with empty body — the blockquote alone is a valid mark)
```

Rules:

- The **first** `<!-- margins:marks -->` line after the frontmatter starts
  the marks section. Everything above it is the long-form body,
  byte-identical to what a marks-unaware frontend would write.
- Each mark is one HTML comment carrying attributes: `id`, `cfi` (range CFI),
  `at` (RFC3339), `percent` (0–100, one decimal). `cfi` may be the empty
  string for a page-anchored mark with no selection.
- The mark's content is the lines following its comment up to the next
  `<!-- margins:mark` comment or end of file: an optional `>`-blockquote
  (the quoted selection) followed by body paragraphs.
- `id` is 10 lowercase Crockford-base32 characters, time-ordered (ULID
  prefix): sortable in files, unique without coordination, safe in HTML
  comments and shell pipelines.
- Ordering on disk is append order; readers sort marks by `percent` (then
  `cfi`, then `id`) when a reading order is needed. Editing or deleting a
  mark rewrites only its block — other marks keep their bytes.
- Unparsable content inside the marks section (a user's stray comment, a
  hand-mangled attribute) is preserved verbatim on round-trip as a raw
  block rather than silently dropped. Losslessness beats tidiness.
- A second `<!-- margins:marks -->` line inside a mark body is just text.

Serialization lives in a new `crates/margins-core/src/marks.rs`;
`ChapterNote` gains `marks: Vec<Mark>` and `body` means **long-form only**.
`save_chapter_note` re-merges the marks already on disk after the new body,
so today's blob-editing frontends (macOS notes pane, Tauri editor) can edit
prose and save without ever seeing or destroying a mark. That merge is the
mechanism behind the round-trip guarantee, proven by a core test.

### The four settled decisions

No objections. One nuance stated once, inside decision 3's own terms: the
round-trip property is implemented by *core-side merge on save* (marks live
on disk, blob frontends edit prose through `save_chapter_note`, mark-aware
frontends go through `append/update/delete_mark`) rather than by asking
frontends to round-trip raw file text. That keeps every frontend's save path
unchanged and puts the guarantee where the format lives.

---

## Architecture

```
                   crates/margins-core
        library · epub_meta · notes · marks (NEW) · compile · sync
                          │                    │
        src-tauri (thin commands)   crates/margins-ffi (UniFFI, thin)
                │                            │
        Tauri frontend            MarginsFFI.xcframework (NEW)
        (renders marks)                      │
                        ┌────────────────────┴───────────────────┐
                  apple/ SwiftPM package (renamed from macos/)
                  MarginsCore · MarginsModel (+ LibraryLocation NEW)
                        │                                        │
              Margins (macOS, unchanged)              MarginsIOS (NEW)
                                                       Library · Book detail
                                                       Reader · note capture
```

- `apple/` (renamed from `macos/`) hosts one shared SwiftPM package. Targets
  `margins_ffiFFI`, `MarginsCore`, and `MarginsModel` become
  platform-agnostic (`.macOS(.v14)`, `.iOS(.v17)`); `MarginsModel` is already
  AppKit-free (verified by grep — the only hit is a doc comment). `Margins`
  stays the macOS app target; `MarginsIOS` is a new executable target.
- The `.unsafeFlags` static-lib hack dies. `scripts/build-xcframework.sh`
  builds `build/MarginsFFI.xcframework` from per-target staticlibs —
  `aarch64-apple-ios`; `aarch64-apple-ios-sim` + `x86_64-apple-ios-sim`
  lipo'd; `aarch64-apple-darwin` + `x86_64-apple-darwin` lipo'd — each slice
  carrying the UniFFI header + module map. `Package.swift` consumes it as a
  `binaryTarget` (local path, gitignored). `scripts/build-core.sh` keeps
  building the macOS slice by default so the CLT-only mac path is unchanged.
- The iOS app is driven by a small committed Xcode project
  (`apple/ios/Margins.xcodeproj`) that references the local SwiftPM package —
  the only artifact a SwiftPM executable cannot self-produce on iOS. No
  XcodeGen; the project is generated once and hand-maintained (it is small:
  package reference, entitlements, Info.plist, signing team left unset).
- Library root on iOS lives in the iCloud Documents ubiquity container
  (`iCloud.io.github.nathanstefanik.margins`), falling back **at runtime** to
  local `Documents` when no paid team / container is available, with the
  reason surfaced in the UI. One narrow type, `LibraryLocation` in
  `MarginsModel`, owns container resolution, materialization of evicted
  placeholders (`startDownloadingUbiquitousItem` +
  `ubiquityItemDownloadingStatus` polling), `NSFileCoordinator`-coordinated
  writes, and `NSFileVersion` conflict detection on note save
  (last-writer-wins, conflicts surfaced, never silently discarded). The Rust
  core stays unaware; it just gets a path via `MarginsCore.new(dataDir:)` /
  `setLibraryRoot`.
- The reader reuses `Resources/reader/` and `ReaderSchemeHandler` unchanged —
  the five-resource allowlist, the `HTTPURLResponse`-for-`book.epub` rule,
  and the navigation policy carry over (they are pure Foundation +
  WebKit, both available on iOS). `ReaderKeymap` is not wired to touch input;
  iPad hardware keys go through `.onKeyPress` reusing it where it is free.

## Phases

Each phase is one commit, independently verifiable, and leaves
`cargo test --workspace` and `make mac-test` green.

### Phase 1 — Shared Apple package + XCFramework — DONE (2026-09-05)

- Rename `macos/` → `apple/`; update `Makefile`, `scripts/build-core.sh`,
  `scripts/make-app.sh`, `AGENTS.md`, `README.md`, `docs/architecture.md`,
  and `.github/workflows/release.yml` in the same commit.
- `Package.swift`: add `.iOS(.v17)` platform; add the `MarginsIOS`
  executable target (placeholder `MarginsIOSApp` that compiles and does
  nothing yet) so the target graph is real from day one.
- `scripts/build-xcframework.sh` + `make ios-core`; consume the framework
  via `binaryTarget`; delete `.unsafeFlags` from `MarginsCore`.
- README: full Xcode now required for iOS (and for `xcodebuild test`);
  CLT-only path still builds the macOS app — verified, not assumed; note
  that `MarginsTests` stays a runner executable until that is revisited.
- Exit: `cargo test --workspace`, `make mac-build`, `make mac-test` green on
  CLT; `make ios-core` produces a valid multi-slice framework. — Met
  2026-09-05; the framework itself needed no Xcode (see notes below).

Implementation notes (deviations found while building it):

1. **The `margins_ffiFFI` header-only C target stays.** SwiftPM links a
   static-library xcframework slice into dependents but does not expose
   headers/module maps from binary targets, so `canImport(margins_ffiFFI)`
   fails when the module lives inside the xcframework. The C target remains
   the module source; the xcframework provides only the archive. The
   `.unsafeFlags` hack is still gone — the archive now comes from the
   binaryTarget, selected per destination.
2. **`make ios-core` requires full Xcode after all** (verified, not
   assumed): the zip stack's C dependencies (`zstd-sys`, `lzma-sys`,
   `bzip2-sys`) compile C against the iOS SDK via `cc-rs`, which resolves
   `xcrun --show-sdk-path --sdk iphoneos` — unavailable on Command Line
   Tools. The macOS-only path (`make core`, `make mac-build`,
   `make mac-test`) stays CLT-only; the xcframework *assembly* logic
   (slices + Info.plist, no `xcodebuild -create-xcframework`) is CLT-safe,
   but producing the iOS archives needs the SDK.
3. **Rust 1.96 does not ship `x86_64-apple-ios-sim`**; the simulator slice
   is arm64-only (`ios-arm64-simulator`) unless the target is available, in
   which case the script lipo's both (`ios-arm64_x86_64-simulator`). Fine on
   Apple Silicon; revisit if Intel-host simulator builds ever matter.

### Phase 2 — Marks in the core and FFI — DONE (2026-09-05)

- `marks.rs`: parse/serialize the syntax above; `ChapterNote.marks`;
  `body` = long-form only; `save_chapter_note` merges disk marks.
- `append_mark`, `update_mark`, `delete_mark` (stable ids; per-mark rewrite);
  `NotesIndexEntry` gains `mark_count`; `notes/_index.json` stays consistent.
- `compile.rs`: marks appear in the compiled page and the markdown export in
  reading order within each chapter (blockquote quote, then body, with the
  `at`/`percent` line rendered as a quiet italic line, matching the macOS
  prose style; export marks the section with `> — ` attribution lines, not
  HTML comments).
- FFI: `append_mark`, `update_mark`, `delete_mark`, mark counts through the
  existing record types; `make core` regenerates bindings.
- `docs/storage.md` updated (format, `_index.json`, losslessness rules).
- Exit: `cargo test --workspace` green — including the blob round-trip test
  (load a file with marks as a marks-unaware frontend would, edit prose,
  save through `save_chapter_note`, marks byte-identical), compile/export
  ordering, id stability, unparsable-block preservation. `make mac-test`
  green; Tauri app still builds and its notes pane shows prose only.

Met 2026-09-05: 82 core tests (+16 marks/compile round-trip), 73 Swift
tests, Tauri build + keymap regression green. Implementation notes:

- The merge rule is: the incoming body is authoritative for any marks
  section it carries; a body without a sentinel leaves disk marks
  untouched. Proven byte-for-byte by `blob_save_preserves_marks_byte_identically`.
- Per-block raw preservation (`MarkItem::Mark{raw}` / `MarkItem::Raw`) is
  what keeps untouched marks byte-identical through append/update/delete.
- `save_chapter_note` reads the existing file from its **final path**
  (after the retitled-chapter rename), not via the still-stale index
  entry — reading via the index would silently drop marks on a retitle.
- `search.rs` indexes long-form bodies only; mark text is not searchable.
  Deliberate for v1 — revisit if marks search is wanted.

### Phase 3 — Render marks in Tauri and macOS — DONE (2026-09-05)

- Compiled notes page (Tauri `notes-view`, macOS `NotesPageView`) and both
  notes panes render marks as styled quotes/notes — never raw HTML comments.
  Bodies stay plain `Text` / escaped text (security property, unchanged).
- Chapter-note editors gain a marks strip (count + list, delete/edit) — read
  affordances only; capture stays iOS-only this phase.
- Exit: `npm run tauri build`; `make mac-test`; manual pass against the
  Karamazov fixture on both platforms.

Met 2026-09-05: Tauri gained `append_mark`/`update_mark`/`delete_mark`
commands + api wrappers, a pane marks strip (edit/delete, edit via inline
textarea) and compiled-page mark sections; macOS gained the same strip in
`NotesPane` (edit sheet, delete), compiled-page marks in `NotesPageView`,
and a tested `MarkDisplay` helper in MarginsModel. Mark text renders via
`textContent` / plain `Text` only — the security property holds. Strip
mutations never reload the editor (prose and marks are disjoint), and mark
ops refresh an open compiled page. Verified: `cargo test --workspace`,
`make mac-test` (79, incl. a new end-to-end CoreStore marks round-trip),
`npm run tauri build` (compile + .app bundle green; the DMG sub-bundler
fails in this headless environment — pre-existing, the release flow builds
DMGs via `make mac-app-universal`). On-screen clicks remain for the next
human pass on each platform.

### Phase 4 — iOS app skeleton + Library scene — DONE (2026-09-05)

- `apple/ios/Margins.xcodeproj` (package reference, entitlements:
  iCloud Documents + container id; Info.plist:
  `NSUbiquitousContainerIsDocumentScopePublic`, `UIFileSharingEnabled`,
  `LSSupportsOpeningDocumentsInPlace`); team ID stays out of the repo.
- `LibraryLocation` (container resolution, runtime fallback with surfaced
  reason, materialization, coordinated writes, conflict detection) +
  `MarginsTests` coverage with a seam for the container lookup.
- Library scene: cover grid (`BookCoverPlaceholder` fallback), title/author,
  note count, progress from `progress_percent`; import via
  `UIDocumentPicker` (`.epub` + `public.data` fallback) with progress;
  swipe-to-delete with confirmation; `.searchable` notes search over
  `search_notes`. `NavigationStack` on iPhone, `NavigationSplitView` on iPad.
- Exit: builds and runs on the simulator via `xcodebuildmcp`; import an EPUB,
  see covers/progress, search, delete — screenshots in the phase report.

Met 2026-09-05. Implementation notes and deviations:

1. **iOS scenes live in the Xcode target** (`apple/ios/Margins/`), not the
   SwiftPM package — iOS-only SwiftUI/UIKit code cannot sit in a
   multiplatform package without `#if canImport(UIKit)` guards at every
   file. The package exports `MarginsCore`/`MarginsModel` products that the
   committed, hand-maintained project (file-system-synchronized groups,
   no XcodeGen) consumes; the Phase-1 `MarginsIOS` placeholder target is
   gone.
2. **The header-only `margins_ffiFFI` C target needed a placeholder .c** —
   Xcode's SwiftPM integration expects every C target to emit an object
   file (plain `swift build` did not care).
3. **Delete is context-menu + confirmationDialog, not swipe** — grids have
   no swipe actions; long-press → Delete… → confirm is the grid-native
   equivalent, accessible via the VoiceOver actions menu.
4. **Verification used DEBUG launch env vars** (`MARGINS_IMPORT_FIXTURE`,
   `MARGINS_SEARCH_FIXTURE`, `MARGINS_DELETE_FIXTURE`) — this environment
   has no UI-automation tooling, so gestures were driven by deterministic
   launch seams and screenshots (iPhone light + dark, iPad SplitView).
   Search ran against a hand-seeded note with marks via the real core.
5. `LibraryLocation` (container resolution, runtime fallback, bounded
   materialization, `NSFileCoordinator` staged copies, `NSFileVersion`
   conflict detection) ships with 6 tests; the conflict check wires into
   the note-save flow when the iOS note editor lands (Phase 5/6).

### Phase 5 — Book detail + Reader — DONE (2026-09-05)

- Book detail: cover, metadata, progress, **Continue reading**; segmented
  Contents / Notes. Contents rows show TOC titles, a notes marker
  (`get_notes_index`), and the current position; tap opens the reader there.
  Notes tab: compiled page stats (chapters, words, last updated),
  empty-chapter toggle, tap-to-jump, `ShareLink` export via
  `render_notes_markdown`, clear-all behind confirmation.
- Reader: `WKWebView` + `ReaderSchemeHandler` (allowlist untouched), tap
  zones (left/right thirds) + horizontal swipe paging, center-tap chrome
  (chapter title, progress, TOC + notes buttons, auto-hide), typography
  sheet persisting through `ReaderPreferences`, debounced
  `save_reading_position` flushed on `scenePhase == .background`, dark mode
  and Dynamic Type verified for real.
- Exit: read a book end-to-end on the simulator; position survives
  backgrounding; screenshots of both detail tabs and the reader (light +
  dark).

Met 2026-09-05. Implementation notes:

1. **The reader bundle + scheme handler moved into `MarginsModel`** — one
   vendored copy served to both apps; `Bundle.module` resolves per
   platform. The macOS app is unchanged behaviorally.
2. **A latent macOS reader bug surfaced and was fixed** (see
   `docs/architecture.md` → Reader rendering): epub.js ≥ 0.3.93 keys
   `spineByHref` by manifest-relative hrefs while the core's jump targets
   are zip-root-relative, so href-based chapter jumps rejected with "No
   Section Found". Fixed in shared `reader.js`
   (`readerResolveSpineTarget`) + `ReaderModel.relocated` matching; the
   macOS app was re-verified against the Karamazov fixture (previously it
   showed the reader error page on explicit chapter jumps; resume/CFI and
   `next()/prev()` had masked it).
3. **Hardware-key page turns** are intercepted in a `WKWebView` subclass
   (`KeyHandlingWebView.pressesBegan`) — the webview is first responder
   while reading and would otherwise swallow arrows/space.
4. Verified on the simulator: import → detail (Contents with note markers,
   Notes with compiled marks/stats/ShareLink/clear-all) → reader (cover +
   prose pages, chapter-follow across section boundaries via `relocated`,
   keyboard paging, debounced position save → kill → relaunch → CFI
   resume). Chrome auto-hides on page turns; tap zones share the same
   page-turn path as keys (tap synthesis unavailable here — flagged for
   the human pass). 87 Swift tests (+2 for href matching), Rust suites
   untouched and green.

### Phase 6 — Note capture

- epub.js `rendition.on("selected")` wired through a new script-message
  channel to Swift; edit-menu *Note* / *Highlight* via
  `UIEditMenuInteraction`; one no-selection gesture (long-press, primary and
  discoverable; VoiceOver-accessible equivalent button in the chrome).
- Capture sheet: `.presentationDetents([.height(200), .medium])`,
  keyboard up on appear, `@FocusState` on appear, dimmed-but-visible page;
  return/Done commits, swipe-down commits; **draft autosave** so nothing is
  ever lost; barest inline flash on commit.
- Highlight-without-note supported (quote, empty body);
  `rendition.annotations.highlight` used to render highlights, restored on
  chapter load.
- Chapter marks sheet (count in the chrome; edit/delete there);
  full-height chapter-note editor sheet (`.large`) with word count, debounced
  + dismiss + background autosave, marks strip alongside; quiet, dismissible,
  silenceable end-of-chapter prompt.
- Exit: the definition-of-done flow on the simulator — five quick marks and
  one chapter note while reading — plus round-trip: the same files open
  correctly in the macOS app and the Tauri app. Screenshots.

### Phase 7 — Integration, accessibility, docs

- "Open EPUB in Margins" from Files/Mail (`CFBundleDocumentTypes` +
  `onOpenURL`).
- VoiceOver labels on tap zones and capture affordances; Dynamic Type audit
  across all four scenes; no gesture-only actions.
- README (both frontends), `AGENTS.md`, `docs/architecture.md`,
  `docs/storage.md` final pass; `make ios-*` targets documented; iCloud
  setup documented (container, entitlement, fallback behavior, conflict
  behavior).
- Exit: definition-of-done checklist in the prompt walked end to end.

## Testing

- **Core**: mark parse/serialize round-trip; blob-frontend save preserves
  marks byte-for-byte; append/update/delete id stability and ordering;
  unparsable-block preservation; `_index.json` mark counts; compile/export
  reading order (mirrors existing `notes.rs`/`compile.rs` test fixtures).
- **macOS (`MarginsTests`)**: existing suites must stay green;
  `LibraryLocation` fallback + conflict handling via an injected-container
  seam; mark-strip presentation helpers.
- **iOS**: same `MarginsTests` suite compiles into the iOS test graph via
  `xcodebuild test` once Xcode lands; device-interaction passes drive the
  real gestures with screenshots — unit tests do not certify the capture
  flow.
- **Tauri**: builds at every phase; keymap script untouched unless bindings
  change.

## Risks / open questions

- **Xcode installed but not yet usable** — Xcode 26.6 and the iOS SDKs are on
  disk, but Phases 4–7 stay blocked until its license is accepted and a
  simulator runtime is downloaded (see Environment prerequisite). Both need an
  admin password, so neither is agent-automatable. Phases 1–3 are unblocked
  and verified green.
- **`binaryTarget` on CLT** — the macOS xcframework slice must link cleanly
  without full Xcode; if SwiftPM balks on CLT, `build-core.sh` keeps a
  fallback to today's absolute-path link for macOS only, flagged loudly.
  Verified in Phase 1, not assumed.
- **epub.js selection events inside WKWebView** — `selected` fires per
  rendition; iOS long-press menus can fight the webview's native selection
  UI. Mitigation: the edit-menu delegate path, tested on-device in Phase 6
  before the sheet is built.
- **Ubiquity container without a paid team** — simulator/local fallback is
  the tested path; container behavior on a real account is documented but
  only verifiable with signing credentials (user-provided, never committed).
- **iCloud eviction mid-read** — materialization polls with a timeout and a
  real error state (never a blank screen); worst case is a book that needs a
  tap to download, which the UI explains.
