# Prompt: build the iOS version of Margins

> Paste this whole file as the opening prompt to the opencode agent working in
> the Margins repo. Delete this file once the work lands.

---

You are working in the **Margins** repo (`/Users/zariski/github/margins`, or
whichever worktree you were launched in). Read `AGENTS.md`,
`docs/architecture.md`, and `docs/storage.md` **first** — they are accurate and
they define the conventions you must keep.

Your job: **ship an iOS app for Margins** that mirrors the existing macOS app,
with a note-taking experience designed for touch. Deliver a plan document
first, then implement it in reviewable phases.

## Skills

Skills are installed under `.agents/skills/`. Use them — do not work from
memory on these topics:

| Situation | Skill |
|---|---|
| Any SwiftUI view / state / `@Observable` structure | `swiftui-patterns` |
| `NavigationStack`, `NavigationSplitView`, sheets, tabs, deep links | `swiftui-navigation` |
| Sendable / actor-isolation / strict-concurrency errors | `swift-concurrency` |
| Writing or migrating tests | `swift-testing` |
| Running on the simulator, screenshots, UI hierarchy, taps | `device-interaction` |
| Crashes, hangs, retain cycles, build failures you can't read | `debugging-instruments` |
| Lint config | `swiftlint` |
| New SDK-27 SwiftUI APIs and `@State`-macro breakage | `swiftui-whats-new-27` |

Skip `swiftdata` and `ios-networking` — Margins has no database and no network
layer, and adding either is out of scope (see Constraints).

The `xcodebuildmcp` MCP server is configured in `opencode.json`; use it for
builds, simulator boots, and running the app rather than hand-rolling
`xcodebuild` invocations where it fits.

## What already exists

One Rust core, two thin frontends:

```
crates/margins-core/     domain logic: library, epub_meta, notes, compile, sync, config
crates/margins-ffi/      UniFFI 0.29 bridge -> Swift (one object: MarginsCore)
src-tauri/ + src/        Tauri + TypeScript app (Linux/desktop)
macos/                   SwiftPM package: margins_ffiFFI, MarginsCore, MarginsModel,
                         Margins (SwiftUI), MarginsTests (Swift Testing runner exe)
```

- Storage is **plain files** under a library root — `index.json`,
  `books/{id}/meta.json`, `source.epub`, `cover.*`, `position.json`,
  `notes/_index.json`, `notes/chapters/NNN-slug.md`. No database. Ever.
- Rendering is **epub.js in a WKWebView**. `macos/Sources/Margins/Resources/reader/`
  holds `reader.html` / `reader.js` / vendored `epub.min.js` / `jszip.min.js`.
  Swift drives it through `window.reader*` functions via `evaluateJavaScript`,
  and JS reports relocations back through the `reader` script message handler.
  `ReaderSchemeHandler` serves exactly five resources over `margins-reader://`
  and rejects everything else — preserve that allowlist exactly.
- The macOS app is keyboard-first (zathura-like): `ReaderKeymap` is a
  UI-agnostic vim key state machine driven by one `NSEvent` monitor.

## The four decisions already made

These are settled. Do not re-litigate them; if you hit a hard blocker on one,
stop and say so rather than silently picking something else.

### 1. Layout: refactor into one shared multiplatform Apple package

Turn `macos/` into a shared Apple package serving both platforms:

- `MarginsCore` and `MarginsModel` become **platform-agnostic** (`.macOS(.v14)`
  **and** `.iOS(.v17)` or newer — pick the floor you can justify and state it).
  Audit them for AppKit leakage; `LibraryModel`, `ReaderModel`,
  `ReaderResource`, `SearchController`, `ReaderPreferences`, `KeyHelp`, and the
  compiled-notes types should all be reusable as-is or with small extractions.
- Add a shared UI layer for whatever genuinely is shared (formatting helpers,
  cover views, compiled-notes rendering). Keep the **view hierarchies
  separate** — iOS is not a resized Mac window. Do not force a shared
  `ContentView`.
- Keep the existing macOS app working and its tests green at every commit. If
  you rename the `macos/` directory, update `Makefile`, `scripts/build-core.sh`,
  `scripts/make-app.sh`, `AGENTS.md`, `README.md`, `docs/architecture.md`, and
  `.github/` in the same commit.
- **The `.unsafeFlags` static-lib hack has to go.** `MarginsCore` currently
  links `target/release/libmargins_ffi.a` by absolute path. For iOS you need
  per-platform slices, so build an **XCFramework** (device `aarch64-apple-ios`,
  simulator `aarch64-apple-ios-sim` + `x86_64-apple-ios-sim` lipo'd together,
  macOS `aarch64-apple-darwin` + `x86_64-apple-darwin` lipo'd together) with the
  UniFFI header and module map, and consume it as a `binaryTarget`. Extend
  `scripts/build-core.sh` (or add `scripts/build-xcframework.sh`) and add
  `make ios-*` targets alongside the `mac-*` ones.
- **Full Xcode is now required** for the iOS work (`xcodebuild`, simulators).
  Say so in the README; keep the CLT-only path documented for the macOS-only
  build if it still works, and note plainly if it no longer does. The
  `MarginsTests` runner-executable workaround exists because `swift test` is
  inert on a CLT-only toolchain — once `xcodebuild test` is available, evaluate
  moving to a real test target, but do not break `make mac-test` to do it.

### 2. Library location on iOS: iCloud Drive ubiquity container

The iOS library root lives in the app's **iCloud Documents ubiquity
container**, so it is visible in Files and can be pointed at from the Mac.

- Requires the iCloud Documents entitlement and a container identifier — add
  the entitlements file and document the Apple Developer setup needed. If no
  paid team is configured, fall back to local `Documents` **at runtime** (not
  at build time) and log/surface why.
- Set `NSUbiquitousContainerIsDocumentScopePublic` and
  `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` appropriately.
- The Rust core does plain `std::fs` I/O. That is fine inside the ubiquity
  container, but iCloud files can be **evicted placeholders**. Before handing a
  path to the core, Swift must ensure materialization
  (`startDownloadingUbiquitousItem`, poll `ubiquitousItemDownloadingStatus`) and
  coordinate writes with `NSFileCoordinator`. Put this behind one narrow Swift
  type — e.g. `LibraryLocation` in `MarginsModel` — so the core stays unaware.
- Point the core at the resolved path with `MarginsCore.new(dataDir:)` /
  `setLibraryRoot`. Handle first-launch (container not yet available) and
  offline gracefully: show a real state, never a blank screen.
- Conflict handling: last-writer-wins is acceptable for v1, but detect
  `NSFileVersion` conflicts on note save and surface them rather than silently
  discarding. Document the behavior.

### 3. Note storage: extend the chapter note with anchored "marks"

Quick notes need a home, and today the format is exactly one markdown file per
chapter. Extend that file rather than adding a database or a parallel store.

Target shape (refine the exact syntax, but keep every property below):

```markdown
---
book_id: a1b2c3
chapter_key: '003'
...existing frontmatter...
---

The long-form, contemplative chapter note. Unchanged semantics: this is
exactly what today's macOS notes pane and Tauri editor edit.

<!-- margins:marks -->

<!-- margins:mark id=01J8Q3 cfi="epubcfi(/6/14!/4/2/10,/1:0,/1:42)" at=2026-09-05T14:02:11Z percent=38.2 -->
> optional quoted selection from the book

The quick thought.
```

Required properties:

1. **Everything above the `<!-- margins:marks -->` sentinel is the long-form
   body** — byte-identical to what a frontend that knows nothing about marks
   would produce.
2. **Lossless round-trip.** A frontend that treats the whole file as one blob
   (today's macOS pane, today's Tauri editor) must be able to load, edit the
   prose, and save without destroying marks. Prove this with a test.
3. **Stable ordering and stable ids** so marks can be edited and deleted
   individually without rewriting unrelated ones.
4. Still greppable, still human-readable, still one file per chapter.

Core / FFI work this implies (all in `margins-core`, thin exposure through
both `src-tauri` and `margins-ffi`, per the existing pattern):

- Parse/serialize marks in `notes.rs` (or a new `marks.rs`), with `ChapterNote`
  gaining a `marks: Vec<Mark>` and `body` meaning long-form-only.
- `append_mark`, `update_mark`, `delete_mark`, and mark counts in
  `notes/_index.json`.
- `compile.rs` must include marks in the compiled notes page and the markdown
  export, in reading order within each chapter.
- Update `docs/storage.md` **and** keep `notes/_index.json` consistent — that
  is an explicit `AGENTS.md` requirement.
- Update the macOS app and the Tauri frontend enough that they render marks
  sensibly instead of showing raw HTML comments. This is not optional cleanup;
  a shared format that only one client understands is a bug.

### 4. Deliverable: plan first, then phased implementation

Write **`docs/ios-plan.md`** in the same style as the existing
`docs/notes-page-plan.md` and `docs/packaging-plan.md`: status line, goal,
non-goals, architecture with a diagram, then numbered phases that are each
independently committable and independently verifiable. Stop and let me review
that document before writing implementation code.

Then implement phase by phase, one commit per phase, `FEAT`/`CHORE`/`REFACTOR`
prefixes per `AGENTS.md`.

## The four scenes

Mirror the macOS app's information architecture, but use native iOS
navigation — read `swiftui-navigation` before choosing the container. A
`NavigationStack` on iPhone with a `NavigationSplitView` on iPad is the
expected shape; justify whatever you pick.

### 1. Library

All imported EPUBs. Grid of covers (with the existing `BookCoverPlaceholder`
fallback for coverless books), title/author, note count, reading-progress
indicator from `progress_percent`. Import via `UIDocumentPicker` (`.epub` +
`public.data` fallback — some EPUBs come through with sloppy UTIs), with the
progress feedback the desktop app has. Swipe-to-delete with confirmation.
Library-wide notes search over `search_notes`, presented with `.searchable`.
Handle "open EPUB in Margins" from Files/Mail via
`CFBundleDocumentTypes` + `onOpenURL`.

### 2. Book → Contents

Tapping a book lands on a book detail with the cover, metadata, progress, and
a **table of contents** from `BookMeta.chapters` — chapter title, a marker for
chapters that have notes (from `get_notes_index`), and the current reading
position highlighted. Tapping a chapter opens the reader at that chapter.
Primary action: **Continue reading** (resumes from `position.json`).

### 3. Book → Notes

The same book detail also reaches the **compiled notes view**, backed by
`get_compiled_notes` — every chapter note in spine order, now including marks.
Show the stats the macOS `NotesPageView` shows (chapters with notes, total
words, last updated), let empty chapters be toggled, and tapping a chapter
jumps into the reader there. Export via `render_notes_markdown` into a share
sheet (`ShareLink`), and clear-all behind a confirmation.

**Render note bodies as plain `Text`, never as markdown or HTML** — the macOS
app does this deliberately and it is a security property, not a style choice.

Scenes 2 and 3 are two faces of the same book: a segmented control or two tabs
inside the book detail is fine, as is a sidebar on iPad. Don't build two
unrelated screens.

### 4. Reader

Reuse the existing `Resources/reader/` bundle and `WKURLSchemeHandler` — the
scheme handler, the five-resource allowlist, the `HTTPURLResponse`-for-
`book.epub` rule, and the navigation policy all carry over to iOS unchanged and
are load-bearing (see `docs/architecture.md`). What changes is input and chrome:

- **Paging by touch:** tap zones (left third / right third) and horizontal
  swipe. No scroll-wheel monitor, no `NSEvent` monitor — `ReaderKeymap` is
  macOS-only input, but keep hardware-keyboard support on iPad via
  `.onKeyPress` / `UIKeyCommand` reusing `ReaderKeymap` where it's free.
- **Immersive chrome:** tap the center to toggle a minimal top/bottom bar
  (chapter title, progress, TOC button, notes button). Auto-hide while reading.
  Respect safe areas and the home indicator.
- **Typography controls** matching `TypographyPopover` (size, line height,
  width) in a sheet; persist through `ReaderPreferences`.
- **Position saving:** the debounced `save_reading_position` path already
  exists — also flush on `scenePhase` change to `.background`, because iOS will
  suspend you.
- Dark mode and Dynamic Type must both actually work.

## The hard part: note-taking while reading

Two distinct modes, and the design must not make either one pay for the other.

### Quick capture — frequent, seconds long

The bar to clear: **from reading to typing in one deliberate gesture, and back
to reading without thinking about saving.** If a user takes forty of these in a
session, the forty-first must still feel free.

- **With a selection:** selecting text in the webview should offer *Note* and
  *Highlight* in the edit menu. Wire epub.js's `rendition.on("selected", cfiRange, contents)`
  through a new script-message channel to Swift; that gives you the CFI range and
  the quoted text for the mark. Customize the callout via
  `WKWebView`'s edit-menu delegate / `UIEditMenuInteraction`.
- **Without a selection:** one gesture from anywhere on the page — a long-press,
  a bottom-edge swipe-up, or a small persistent affordance that fades while the
  chrome is hidden. Anchor the mark to the current page's CFI. Pick one primary
  gesture and make it discoverable; don't ship four half-wired ones.
- The capture UI is a **small sheet** — `.presentationDetents([.height(200), .medium])`,
  keyboard raised immediately, `@FocusState` set on appear, background dimmed
  but the page still visible behind it. One text field. Return (or a Done
  button) commits and dismisses; swipe-down also commits. **Never lose text**:
  autosave a draft so a mistaken dismissal or a backgrounded app doesn't
  discard it.
- Committing writes an anchored mark via the new core API. Show the barest
  possible confirmation — a brief inline flash, not a toast that blocks reading.
- Existing marks in the current chapter should be visible on demand (a count in
  the chrome, tap to see the chapter's marks in a sheet) and editable/deletable
  there.
- Highlight without a note is a legitimate zero-typing case: a mark with a quote
  and an empty body. Support it, and render it as a highlight in the page if you
  can do so without fighting epub.js (`rendition.annotations.highlight` exists —
  use it, and restore highlights on chapter load).

### Contemplative chapter note — infrequent, minutes long

- A **full-height editor sheet** (`.presentationDetents([.large])`) over the
  chapter's long-form note body: monospace-or-serif markdown editing, word
  count, autosave on a debounce plus on dismiss and on backgrounding.
- Reachable from the reader chrome, from the chapter row in the Contents scene,
  and from the compiled Notes scene.
- **Offer it at the natural moment:** when the reader reaches the end of a
  chapter, a quiet, dismissible prompt to write the chapter note. Quiet and
  dismissible — this must never feel like nagging, and it must be silenceable.
- Show that chapter's quick marks alongside the editor (a collapsed strip or a
  segmented view), because the whole point is writing the reflection *from* the
  marks you took.

### Design constraints for both

- Margins is deliberately minimal and restrained (zathura-inspired). No
  gamification, no streaks, no badges. Chrome earns its pixels.
- Test the interaction on a real screen via the `device-interaction` skill:
  boot a simulator, drive the actual gestures, screenshot each scene, and
  include what you saw in your report. Do not declare the note flow done on the
  strength of a passing unit test.
- Accessibility is part of done: VoiceOver labels on the tap zones and capture
  affordances, Dynamic Type in the reader and every scene, and no
  gesture-only-with-no-alternative actions.

## Constraints

- **Never break the other two frontends.** `cargo test --workspace` and
  `make mac-test` must pass at every commit, and the Tauri app must keep
  building. Any core or FFI change is a three-frontend change.
- No database. No new heavyweight dependencies without asking. Annotation
  storage stays plain text (`AGENTS.md`).
- Run `make core` after any FFI change so the Swift bindings regenerate.
- GPL-3.0-or-later — preserve license headers and the license on distribution.
- Sensitive paths go in `.env`, never committed. Do not commit signing
  identities, team IDs, or provisioning profiles.
- Commit messages: `FEAT` / `BUG` / `CHORE` / `DOCS` / `REFACTOR` + imperative
  summary.
- Update `README.md`, `AGENTS.md`, `docs/architecture.md`, and `docs/storage.md`
  as you go — the docs are treated as accurate here, so leaving them stale is a
  defect.

## Definition of done

1. `docs/ios-plan.md` exists, is phased, and matches what was built.
2. The iOS app builds and runs on the simulator, with all four scenes reachable.
3. Import an EPUB → read it → take five quick marks and one chapter note →
   see them in the Notes scene → export the markdown. Demonstrated, with
   screenshots.
4. Quick marks and chapter notes written on iOS open correctly in the macOS app
   and the Tauri app, and vice versa. Demonstrated.
5. `cargo test --workspace` green, `make mac-test` green, new Swift Testing
   coverage for the iOS model layer and for mark parse/serialize round-trips.
6. Docs updated; `make ios-*` targets documented in the README.

## Before you start

Read the repo, then come back with:

- your proposed phase breakdown,
- the iOS deployment target you chose and why,
- the exact mark syntax you settled on,
- and anything in the four settled decisions you think is wrong, stated once,
  with your reasoning — then proceed as specified unless told otherwise.
