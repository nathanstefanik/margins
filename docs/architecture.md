# Margins architecture

Margins is one Swift core with two thin frontends: a native macOS SwiftUI
app and a native iOS SwiftUI app. Both share one SwiftPM package. Both
render EPUBs with epub.js and write annotations as plain files — no
database anywhere.

```
macOS app (apple/Sources/Margins) ──┐
                                    ├─ MarginsModel ── MarginsCore (no UI)
iOS app (apple/ios/Margins) ────────┘   EPUB parsing · library · notes
                                        marks · compile · search · outline
                                              (plain-text storage)
```

## The core (`apple/Sources/MarginsCore`)

All domain logic lives here and has **no UI dependency** (Swift 6 language
mode throughout):

- `AppConfig.swift` — data dir / library root, from `MARGINS_DATA_DIR` /
  `MARGINS_LIBRARY_ROOT` or platform defaults, remembered in `config.json`.
- `Library.swift` — importing EPUBs into the library tree (content-hash ids,
  staging dir + commit-by-rename), the book catalog (`index.json`), reading
  positions, cover backfills, removing books.
- `EpubParser.swift` — OPF/spine/metadata parsing (`XMLParser` for OPF, NCX,
  and EPUB3 nav; tolerant scanners for everything chapter documents do to
  markup).
- `Notes.swift` + `Frontmatter.swift` — per-chapter markdown notes with YAML
  frontmatter and a `_index.json` per book.
- `Marks.swift` — quick marks inside the notes' sentinel region; untouched
  blocks re-emit byte-identically.
- `Compile.swift` — compiles a book's notes into one spine-ordered document
  (the per-book notes page) and renders it as markdown for the `.md`
  export / copy-all; exports are derived artifacts (see `docs/storage.md`).
- `ClubModels.swift` + `ClubStore.swift` — the private-book-club domain
  (one book per club, roster with roles, per-member note snapshots) and the
  local `{data_dir}/clubs/{club_id}/` storage for it.
- `ClubCompile.swift` + `CFI.swift` — merges members' snapshots into one
  document: CFI-overlap clustering (one quote, every member's note under it),
  spoiler gating by the viewer's chapter, and the club markdown export.
- `ClubCode.swift` + `CoreID.swift` — four-character Crockford invite codes
  and the shared time-ordered id idiom marks and clubs use.
- `Search.swift` — lazily built, mtime-revalidated in-memory index over the
  notes.
- `FileStore.swift` — coordinated document I/O: every read/write of
  `meta.json`, `position.json`, `notes/**`, and `_index.json` goes through
  it; inside the ubiquity container the operations are wrapped in
  `NSFileCoordinator`, elsewhere it is a plain passthrough.
- `Models.swift` — shared record types (`Codable`, snake_case coding keys
  matching `docs/storage.md`; RFC3339 dates with fractional-second
  tolerance).
- `CoreStore.swift` — the `actor` facade the apps drive (import, list,
  notes, marks, positions, search); keeps the core's synchronous file I/O
  off the main actor. `readEpubBytesSync` stays `nonisolated` for the
  reader's WebKit threads.

Storage stays human-readable on disk; see `docs/storage.md` for the layout.
Both frontends write notes through the same `Notes` code path, so the
files are byte-identical regardless of which app wrote them.

## Chapter outline

The core classifies every spine item so a UI can present a book's real
structure instead of a flat list of files. `Models.swift` carries `Matter`
(`cover` / `front` / `body` / `back`), a `level`, and a
`sections: [ChapterSection]` array on `ChapterMeta` — every TOC entry that
starts inside the file, in reading order. A file holding "Book II" and its
first chapter therefore has two sections and one shared note key;
`EpubParser.swift` decides matter from landmarks, per-document
`epub:type`, cover shape, title heuristics, and finally position, in that
order. The classification rules and the `chapters_version` upgrade are the
contract in `docs/storage.md`.

`MarginsModel/ContentsOutline.swift` turns the classified chapters into the
rows the UIs draw: collapsed front/back matter, body headings, and body
chapters numbered from one across the whole book. macOS (`BookDetailView`),
the iOS book detail (`ContentsList`), and the reader's `TOCSheet` all render
that one outline, so both frontends agree on structure. `ReaderModel.
bookPercent` tracks the chapter's position in the filtered spine rather than
its raw index, so filtered/`linear="no"` items cannot push progress past
100%.

## The Apple package (`apple/`)

A single SwiftPM package serving macOS and iOS (platforms `.macOS(.v14)`,
`.iOS(.v26)`). No `.xcodeproj` for the macOS side. Targets:

- `MarginsCore` — the core (above) and everything it needs; the only
  non-test dependency is ZIPFoundation.
- `MarginsModel` — UI-agnostic model layer: `LibraryModel` (catalog,
  selection, import/remove), `ReaderModel` (open book/chapter, notes pane
  state), `ContentsOutline` (classified chapters → front/body/back rows
  shared by both apps), `ReaderResource` (scheme-handler routing),
  `ReaderKeymap` (vim-style key state machine), `LibraryLocation` (iOS
  library root: iCloud container resolution with runtime fallback,
  placeholder materialization for reader assets and covers, coordinated
  staging of picked files, conflict detection), and the club layer:
  `ClubModel` (club list, selection, merged document), `ClubSync` +
  `CloudKitClubSync` (share transport), and `LocalClubSyncEngine` (the
  no-iCloud fallback used by unsigned builds). Unit-tested via
  `MarginsModelTests`.
- `Margins` — macOS SwiftUI app: library browser, reader (WKWebView +
  epub.js), notes pane, search overlay, keyboard/trackpad routing.
- `MarginsModelTests` / `MarginsCoreTests` — Swift Testing test targets,
  run by `swift test` (full Xcode required). `MarginsCoreTests` carries
  `Fixtures/legacy-library/`, a library written by the pre-Swift core; the
  Swift core must open it as-is and produce the same notes, marks,
  positions, and search results.

## The iOS app (`apple/ios/`)

A small committed Xcode project (`Margins.xcodeproj`, file-system-
synchronized sources, no XcodeGen) referencing the local SwiftPM package
through the `MarginsCore`/`MarginsModel` products. The app's SwiftUI scenes
live in the Xcode target (`apple/ios/Margins/`) rather than the package:
iOS-only SwiftUI/UIKit code cannot live in a multiplatform SwiftPM package
without `#if canImport(UIKit)` guards everywhere. The entry point wires the
shared `LibraryModel`; the library root is resolved per launch by
`LibraryLocation` (ubiquity container paths change between installs),
falling back to local `Documents/Library` with the reason surfaced in the
UI. DEBUG launch env vars (`MARGINS_IMPORT_FIXTURE`, `MARGINS_SEARCH_FIXTURE`,
`MARGINS_DELETE_FIXTURE`, `MARGINS_OPEN_FIXTURE`, `MARGINS_CHROME_FIXTURE`)
drive deterministic simulator verification flows. EPUBs handed over by
Files/Mail arrive through `onOpenURL` as
security-scoped URLs and are staged (`NSFileCoordinator`) before the core
imports its own copy into the library. The signing team lives in
`apple/ios/Signing.local.xcconfig` (gitignored; see
`Signing.local.xcconfig.example`) — never committed.
Entitlements declare the iCloud Documents container
(`iCloud.io.github.nathanstefanik.margins`) and the CloudKit service the
book-club transport uses; the Info.plist exposes the
container as a document scope (the `NSUbiquitousContainer*` keys nested
under `NSUbiquitousContainers` → the container id, plus
`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`). Signing team
stays unset in the repo — set it locally for device builds.

### Navigation, layout, and the control layer

The iOS app follows the iOS 26 content-under-controls model: an immersive
content layer (the library grid, the paper) with a lightweight glass
control layer floating above it. Glass belongs to controls and navigation
only — never to cards, list rows, or content, and never nested in glass.

One information architecture adapts to the available space instead of a
per-device layout: `LibraryScene` is a `TabView` with a **Library** tab, a
**Clubs** tab (`ClubsScene` → `ClubDetailView`), and a dedicated **Search**
tab, styled `.sidebarAdaptable` so it is a floating tab bar on a compact
canvas and a sidebar on a regular one. The Library tab is a
`NavigationStack` (`LibraryRoute`) pushing book detail and then the reader;
the reader fires a matched-geometry zoom out of the tapped cover
(`.matchedTransitionSource` / `.navigationTransition(.zoom)`). Global notes
search owns the Search tab (scope: the whole library); the contextual search
for a book's contents would live inline over that content. Layout keys off
size classes (`verticalSizeClass` shrinks the book-detail cover on a
constrained height), never `interfaceOrientation`, so it survives Split
View, landscape, and iPhone Mirroring. Shared sizing and rounding live in
`DesignTokens.swift`.

### Reader rendering

The vendored `epub.min.js` + `jszip.min.js` (versions pinned in
`scripts/vendor-reader.sh`) plus the hand-written `reader.html`/`reader.js`
live in **`MarginsModel`'s resource bundle** so the macOS app, the iOS app, and the
scheme handler serve one identical copy. The page takes whole-book bytes
in and renders a paginated flow with `spread: "none"`. Swift drives it
through the `window.reader*` functions
via `evaluateJavaScript`; the page reports `relocated` back through the
`reader` script message handler.

Two href conventions meet here and must never be conflated: the core's
spine hrefs are **zip-root-relative** (`OEBPS/chapter1.xhtml`), while
epub.js ≥ 0.3.93 keys its `spineByHref` by the **manifest-relative** href
(`chapter1.xhtml`). `reader.js` resolves jump targets against the spine
(`readerResolveSpineTarget`: exact → progressively stripped path prefixes),
and `ReaderModel.relocated` matches reported hrefs back onto spine chapters
(exact → path suffix → basename). Without these bridges, href-based chapter
jumps reject with "No Section Found" — a bug that shipped silently on macOS
until the iOS reader surfaced it.

The page also reports text **selections** (`selected` events carry the CFI
range + quoted text) through the same script channel; the iOS bridge
extends the native edit menu with *Note* / *Highlight* and applies
highlight overlays through epub.js's annotations API. The macOS handler
ignores selection messages.

### `margins-reader://` scheme — security model

The reader webview loads `margins-reader://app/reader.html?book=<id>`; a
`WKURLSchemeHandler` serves **exactly five** resources: `reader.html`,
`reader.js`, `epub.min.js`, `jszip.min.js`, and `book.epub` (bytes from
`CoreStore.readEpubBytesSync`). Anything else — traversal, nested paths,
unknown names — is rejected by the pure `ReaderResource` resolution before
any I/O, so there is no arbitrary-path or filesystem exposure. EPUB content
itself is unzipped in JS from the whole-book bytes, never from disk paths.

Two response-type rules are load-bearing (both bit us once): `fetch()` needs
HTTP semantics, so `book.epub` is served as an `HTTPURLResponse` — a plain
`URLResponse` makes WebKit reject the fetch with status 0. Frame/subresource
loads need the plain `URLResponse` — serving HTTP for the main document
breaks the load.

Navigation policy sends any `http(s)` navigation (and `target=_blank`) to
the system browser; only `margins-reader://` loads in the webview.

Section iframes run with `allow-same-origin allow-scripts allow-popups`
(epub.js ≥ 0.3.89 requires `allow-scripts` for any in-book link to work).
This means EPUB-embedded scripts can run and reach the parent page — an
accepted risk: books are local, user-imported files, and the
`margins-reader://` handler exposes only reader assets and the open book's
bytes. Possible future hardening: strip `<script>` tags during import.

### Keyboard routing

One local `NSEvent` monitor (`ShellKeyboardController`) sees every keyDown
before dispatch — including keys headed into the webview — and feeds them
through `ReaderKeymap`. Reader actions execute via `evaluateJavaScript`
(page turns are `rendition.next()/prev()`; paginated content has no vertical
overflow). A scroll-wheel monitor turns pages from trackpad input while
reading. ⌘-combos and text-field typing pass through to menus and inputs.

### Notes and search

The notes pane edits the chapter note from `getChapterNote`; ⌘S / `i`-pane
Save go through `saveChapterNote`, writing the same markdown+frontmatter
files as the iOS app. `/` (or ⌘F) opens the search overlay over
`searchNotes`; opening a hit jumps straight to that book/chapter. The
overlay is non-modal (no sheet window) and `LibraryModel.searchOpen` is the
single source of truth: the shell key monitor closes it on Esc and clicks
outside the panel dismiss it.

The **compiled notes page** (`NotesPageView`, reached via the book detail's
"All Notes" button, `N`, or ⇧⌘N / View → Book Notes) shows every chapter
note in spine order through `compiledNotes`; `LibraryModel.detailMode`
switches the detail area between the book card and the page. "Export
Notes…" (button or File menu) renders with `renderNotesMarkdown` and
writes the file after an `NSSavePanel`; note bodies render as plain `Text`
(never as markdown/HTML).

**Book clubs** live in the sidebar under the book list (`SidebarView`
renders `ClubModel.clubs`; selecting one takes over the detail area).
`ClubDetailView` shows the roster, invite code (copy/rotate), spoiler
toggle, export/copy, and the merged document: clustered passages, long-form
notes, and spoiler placeholders. Create/join sheets are bound to
`ClubModel.createSheetPresented` / `joinSheetPresented`, so the Clubs menu
in `MarginsCommands` opens the same sheets. `ClubSync.automatic` picks
CloudKit when an iCloud account is available and the local-only engine
otherwise, so the unsigned `make app` build keeps working with
single-member clubs; the Settings → Clubs tab reports which mode is active.

## Building and running (macOS)

```bash
make build       # build the Swift package
make test        # run the Swift Testing suite
make app         # assemble build/Margins.app (ad-hoc signed)
make run         # app + open it
make ios-build   # build the iOS app for the simulator (no signing)
```

Requirements: full Xcode 26 (the iOS SDK is needed for the iOS build path).
CI runs one job on `macos-26` pinned to Xcode 26.6.
